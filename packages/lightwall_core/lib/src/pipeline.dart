// 渲染管线编排：底图 → Retinex → 材质 → 光照 → 着色 → 合成 → 叠字 → 编码
import 'dart:math' as math;
import 'dart:typed_data';

import 'astro.dart';
import 'atmosphere.dart';
import 'compose.dart';
import 'material.dart';
import 'retinex.dart';
import 'spectral.dart';
import 'scene3d.dart';
import 'textlayer.dart';
import 'tuning.dart';
import 'tracer.dart';

/// 光源类型。
enum LightSource { sun, moon, twilight, night }

/// 光照信息（供 UI 展示与日志）。
class LightInfo {
  LightInfo({
    required this.source,
    required this.sunAlt,
    required this.sunAz,
    required this.moonAlt,
    required this.moonPhase,
    required this.beamIrradiance,
    required this.diffuseIrradiance,
    required this.color,
    required this.exposureEv,
    required this.label,
    this.beamSpectrum,
    this.ambientSpectrum,
  });

  final LightSource source;
  final double sunAlt;
  final double sunAz;
  final double moonAlt;
  final double moonPhase;
  final double beamIrradiance;
  final double diffuseIrradiance;
  final List<double> color;

  /// 直射光的 7 波段光谱（归一化亮度=1；null = 旧 RGB 路径）。
  /// 物理：色温由大气逐波段吸收决定，不指定颜色。
  final Float64List? beamSpectrum;

  /// 环境光（天光漫射）的 7 波段光谱。null = 旧 RGB 路径。
  final Float64List? ambientSpectrum;

  /// 实际施加的曝光倍率。构造时为占位 1.0，由 [render] 的测光结果写回
  /// （这样"上报的 EV"与"实际施加的 EV"始终一致）。
  double exposureEv;
  final String label;
}

/// 渲染参数。
/// 天气参数（丙类，可选）。默认全晴天，与既有行为一致。
class WeatherParams {
  const WeatherParams({this.cloudCover = 0.0, this.wetGround = false});

  /// 云量 0~1。0 = 既有晴天路径；>0 时：直射乘云透过率（(1−c)^1.6 近似
  /// 散射损耗）、天空分布向 CIE 阴天分布插值、地面反照率按 [wetGround]。
  final double cloudCover;

  /// 阴雨地面（反照率 0.25 → 0.08）。
  final bool wetGround;

  bool get enabled => cloudCover > 0;
}

/// 室内人工光参数（丙类，可选）。默认关。
class IndoorParams {
  const IndoorParams({this.lightLevel = 0.0});

  /// 室内灯强度（相对量）。>0 时在暮光/夜间分支叠加一个中性暖色环境底。
  final double lightLevel;

  bool get enabled => lightLevel > 0;
}

class RenderSpec {
  /// 大气能见度（米）。物理真源：决定气溶胶光学厚度
  /// （astro.aod550FromVisibility → 太阳光谱衰减 + 环日散射占比）。
  /// 缺省 20000 m ≈ 晴天。旧实现把这个数写死在两处调用点的默认参数里。
  final double visibilityM;

  RenderSpec({
    required this.time,
    required this.lat,
    required this.lon,
    required this.windowAz,
    this.sceneCfg = const SceneConfigPlaceholder(),
    this.gridRows = 3,
    this.gridCols = 2,
    this.gridFrameRatio = 0.10,
    this.seed = 0,
    this.aged = const AgedParams(),
    this.materialCoupling = 0.0,
    this.look = const LookConfig(),
    this.penumbraScale = 1.0,
    this.visibilityM = 20000.0,
    this.shadowStrength = 0.25,
    this.cinnabar = kCinnabar,
    this.applyAging = true,
    this.weather = const WeatherParams(),
    this.indoor = const IndoorParams(),
    this.absoluteLux,
    this.cityGlow = 0.0,
  });

  /// 天气（丙类可选）。默认 = 晴天（cloudCover 0），管线行为与旧版完全
  /// 一致；仅在 CLI 显式传 --cloud 时生效。
  final WeatherParams weather;

  /// 室内人工光（丙类可选）。默认关。仅在 CLI 显式传 --indoor-light 时生效。
  final IndoorParams indoor;

  /// 绝对量纲标定（丙类可选）。非空时：输出以绝对 lux 基准，**停用自动
  /// 曝光**（sceneExposureEv），以 absoluteLux 为画面中位亮度的目标值。
  final double? absoluteLux;

  /// 城市光污染（Walker 定律相对量，丙类可选）。默认 0 = 自然夜空。
  /// 典型值：远郊 0.1、近郊 0.5、市区 2.0（夜空辉光相对自然底的倍增）。
  final double cityGlow;

  final DateTime time;
  final double lat;
  final double lon;

  /// 窗户朝向（罗盘方位角，度）。90 = 东，270 = 西。
  final double windowAz;

  final SceneConfigLike sceneCfg;
  final int gridRows;
  final int gridCols;
  final double gridFrameRatio;
  final int seed;
  final AgedParams aged;
  final double materialCoupling;
  final LookConfig look;

  /// 半影倍率（1.0 = 物理值）。半影由「光源角半径（日面几何角径 × 本倍率）
  /// × 逐点窗距」推导（见 [sunAngularDiameterDeg] 与
  /// [Scene3D.windowVisibilityBatch]）。此字段是**纯风格微调**通道：一旦被 UI
  /// 暴露就变成艺术参数（C2/PI-12），默认 1.0 即物理值。
  final double penumbraScale;

  /// 叠字接触阴影的强度（0~1）。字旁的落影是**风格化的**（不是渲染方程里的
  /// 项）：物理上叠字若凸起于墙面，其阴影长度/方向已由太阳仰角与朝向给出
  /// （见 render 中的 contact shadow），本系数只控制阴影的不透明度（PI-8）。
  final double shadowStrength;
  final List<double> cinnabar;
  final bool applyAging;
}

/// SceneConfig 的轻量占位（避免 const 构造限制）。
abstract class SceneConfigLike {
  const SceneConfigLike();

  SceneConfig build();
}

class SceneConfigPlaceholder extends SceneConfigLike {
  const SceneConfigPlaceholder();

  @override
  SceneConfig build() => SceneConfig();
}

class SceneConfigValue extends SceneConfigLike {
  const SceneConfigValue(this.value);

  final SceneConfig value;

  @override
  SceneConfig build() => value;
}

/// 渲染结果。
class RenderResult {
  RenderResult({
    required this.rgb,
    required this.width,
    required this.height,
    required this.light,
    required this.albedoStats,
  });

  /// sRGB 字节（RGB）
  final Uint8List rgb;
  final int width;
  final int height;
  final LightInfo light;
  final Map<String, double> albedoStats;
}

/// 计算光源信息（晴天专用；夜间保留月光与暮光分支）。
LightInfo computeLightInfo({
  required DateTime time,
  required double lat,
  required double lon,
  required double windowAz,
  double visibilityM = 20000.0,
  double cloudCover = 0.0,
  double cityGlow = 0.0,
  double indoorLight = 0.0,
}) {
  final sun = sunPosition(lat, lon, time);
  final moon = moonPosition(lat, lon, time);
  final phase = moonPhase(time);

  final sunAlt = sun.altitude;
  final toSunAz = sun.azimuth;

  if (sunAlt > 0) {
    final vis = visibilityM;
    // 云量：直射透过率随云量衰减（Beer 式近似，厚云 (1-c)^1.6 → c=1 全遮挡），
    // 漫射相应增强（云成为大面积散射源，上限约晴空的 2.2 倍）。
    final c = cloudCover.clamp(0.0, 1.0);
    final cloudBeamT = math.pow(1.0 - c, 1.6).toDouble();
    final beam = solarIrradiance(sunAlt, vis) * cloudBeamT;
    final diffuse =
        skyIrradiance(sunAlt) * (1.0 + 1.2 * c);
    final color = sunColorFromAltitude(sunAlt);
    // 七波段光谱（逐波段大气透过；云按中性衰减后逐波段乘）
    final beamSpec0 = sunSpectrumBands(sunAlt, aod550: aod550FromVisibility(vis));
    final beamSpec = Float64List(kSpectralN);
    for (var i = 0; i < kSpectralN; i++) {
      beamSpec[i] = beamSpec0[i] * cloudBeamT;
    }
    // exposureEv 不再在这里估：真实曝光由画面测光（sceneExposureEv）在
    // render() 内算出并写回（旧实现把入射照度的幂律当曝光，且它与实际
    // 施加的 EV 不是同一个值 —— PI-4 的真 bug）。
    return LightInfo(
      source: LightSource.sun,
      beamSpectrum: beamSpec,
      ambientSpectrum: skySpectrumBands(sunAlt, aod550: aod550FromVisibility(vis)),
      sunAlt: sunAlt,
      sunAz: toSunAz,
      moonAlt: moon.altitude,
      moonPhase: phase,
      beamIrradiance: beam,
      diffuseIrradiance: diffuse,
      color: color,
      exposureEv: 1.0,
      label: '日光 ${sunAlt.toStringAsFixed(1)}°',
    );
  }

  if (sunAlt > -6) {
    final color = twilightColor(sunAlt);
    // 暮光漫射：与白天用**同一条**物理曲线（[twilightDiffuse]），在 h=0 处
    // 连续、随下沉角近似指数衰减，且始终亮于夜空。旧实现 `0.024+0.086·(1−s)`
    // 是"为防日落比午夜暗"凑出来的数，与白天分支在 0° 处有一帧级跳变。
    final twiDiffuse = twilightDiffuse(sunAlt) *
            (1.0 + math.max(0.0, cityGlow) * kCityGlowTwilightScale) +
        indoorLight * kIndoorLightScale;
    return LightInfo(
      source: LightSource.twilight,
      sunAlt: sunAlt,
      sunAz: toSunAz,
      moonAlt: moon.altitude,
      moonPhase: phase,
      beamIrradiance: 0.0,
      diffuseIrradiance: twiDiffuse,
      color: color,
      exposureEv: 1.0,
      label: '暮光 ${sunAlt.toStringAsFixed(1)}°',
    );
  }

  if (moon.altitude > 0) {
    final moonBeam = moonIrradiance(moon.altitude, phase);
    return LightInfo(
      source: LightSource.moon,
      sunAlt: sunAlt,
      sunAz: toSunAz,
      moonAlt: moon.altitude,
      moonPhase: phase,
      beamIrradiance: moonBeam,
      // 月光漫射 = 月光照度 × 晴天漫射比（≈0.10），与太阳分支同一物理；
      // 旧实现是一个与月相/高度角无关的常数 0.012。
      diffuseIrradiance: moonBeam * 0.10 + indoorLight * kIndoorLightScale,
      color: moonColorRgb(moon.altitude),
      exposureEv: 1.0,
      label: '月光 ${moon.altitude.toStringAsFixed(1)}°',
    );
  }

  return LightInfo(
    source: LightSource.night,
    sunAlt: sunAlt,
    sunAz: toSunAz,
    moonAlt: moon.altitude,
    moonPhase: phase,
    beamIrradiance: 0.0,
    diffuseIrradiance: nightSkyIrradiance(moon.altitude, phase,
            cityGlow: cityGlow) +
        indoorLight * kIndoorLightScale,
    // 夜空色同样来自散射光谱（不再是一张写死的 [0.30,0.36,0.58]）。
    color: skyColor(sunAlt),
    exposureEv: 1.0,
    label: '夜空',
  );
}

/// 完整渲染。
///
/// [baseRgb] 为底图 sRGB 字节（w*h*3）；[textAlpha] 为文字 alpha（可选）。
RenderResult render({
  required Uint8List baseRgb,
  required int width,
  required int height,
  required RenderSpec spec,
  Float32List? textAlpha,
}) {
  final n = width * height;

  // 1. 底图 → 线性
  final baseLin = decodeSrgbToLinear(baseRgb);

  // 2. Retinex 分解
  final retinex = decomposeAlbedo(baseLin, width, height);

  // 3. 材质
  //
  // materialVariation（底图低频结构）只用于**叠字的材质耦合**（让印字随墙面
  // 肌理起伏）：它与作为 BRDF 基色的 albedo 是同一份低频结构，若再在合成里
  // 乘一遍就是**三重计入**（PI-10），故 LookConfig.materialStrength 默认 0。
  final material = extractMaterial(retinex.albedo, width, height);
  final matVar = materialVariation(retinex.albedo, width, height);

  // 4. 光源
  final light = computeLightInfo(
    time: spec.time,
    lat: spec.lat,
    lon: spec.lon,
    windowAz: spec.windowAz,
    visibilityM: spec.visibilityM,
    cloudCover: spec.weather.cloudCover,
    cityGlow: spec.cityGlow,
    indoorLight: spec.indoor.lightLevel,
  );

  // 5. 场景：把 spec 上的窗格参数覆盖到场景配置
  final sceneCfg = spec.sceneCfg.build().copyWith(
        gridRows: spec.gridRows,
        gridCols: spec.gridCols,
        gridFrameRatio: spec.gridFrameRatio,
      );
  // ── 45° 切角房（白名单语义见 Scene3D.chooseViewWall 文档）──
  // 窗开口与观察墙**都取斜墙段**：窗=受光段（法线≈朝太阳方位，正午
  // cos=0.71 光斑最亮，不再"到中午彻底消失"）；观察墙=背光段（光穿窗
  // 斜投到墙面，光斑全天在墙上可见）。用户显式 --window 时窗墙固定，
  // 仅观察墙动态。北半球窗开口朝赤道（默认 180°/南，南半球 0°/北）。
    // windowAz < 0 = auto（CLI --window 未传时）：45° 切角房默认——
  // 窗墙=受光斜墙（动态跟太阳），夜间/暮光回退赤道朝向。
  final autoWindow = spec.windowAz < 0;
  final effWindowAz = autoWindow
      ? Scene3D.litChamferAz(light.sunAz,
          lat: spec.lat,
          sunAlt: light.sunAlt,
          fallback: spec.lat >= 0 ? 180.0 : 0.0)
      : spec.windowAz;
  final scene = Scene3D(
    sceneCfg,
    effWindowAz,
    viewWallAz: Scene3D.chooseViewWall(
      effWindowAz,
      sunAzGeo: light.sunAz,
      lat: spec.lat,
    ),
  );
  // 斜墙（chamfer）窗中心：观察墙中心代表点沿 toSun 与窗平面交点的 u，
  // 让光斑几何上自然对准窗洞（显式斜窗时窗随太阳微移，物理正确）。
  if (scene.winWall == Wall.chamfer) {
    final toSun = <double>[
      -scene.sunToRoomDir(light.sunAz, light.sunAlt)[0],
      -scene.sunToRoomDir(light.sunAz, light.sunAlt)[2],
    ];
    final denom = toSun[0] * scene.chamferNx + toSun[1] * scene.chamferNz;
    final uAxisX = -scene.chamferNz, uAxisZ = scene.chamferNx;
    if (denom.abs() > 0.15) {
      // 0.15 下限：太阳几乎平行窗面时（掠射）交点飞远，窗贴回中心。
      final t = scene.chamferD / denom; // 代表点 p=(0,·,0)
      final hx = t * toSun[0], hz = t * toSun[1];
      final uOrigin = scene.cfg.roomD * 0.5 * uAxisZ;
      var u = hx * uAxisX + hz * uAxisZ - uOrigin;
      // 钳到斜墙有效跨度（与 placement 的 halfSpan 同式）
      final lim = math.sqrt(scene.cfg.roomW * scene.cfg.roomW +
              scene.cfg.roomD * scene.cfg.roomD) *
          0.5;
      u = u.clamp(-lim, lim);
      scene.setChamferWindowU(u);
    }
  }
  final materialWithGrid = material;

  // 6. 着色
  final trace = traceScene(TraceInput(
    scene: scene,
    material: materialWithGrid,
    sunAzGeo: light.sunAz,
    sunAlt: light.source == LightSource.moon ? light.moonAlt : light.sunAlt,
    sunColor: light.color,
    sunSpectrum: light.beamSpectrum,
    beamIrradiance: light.beamIrradiance,
    // 【真 bug】漫射此前传 0：TraceInput.diffuseIrradiance 乘进
    // ambientScale，而 tracer 里**有效像素完全不用 ambientScale**
    // （死代码），真正的漫射在第 7 步单独算。两边都管同一份量，
    // 是"既双重计入又互相掩护"的典型结构。现在明确：漫射只归
    // 第 7 步的窗口孔径照度场管，tracer 只管直射。
    diffuseIrradiance: 0.0,
    ambientColor: light.color,
    // 半影用**绝对角半径**（光源角半径 = 日面几何角半径 × penumbraScale），
    // 不再走"占窗宽比例"的旧口径：半影半径是局部量 r(P)=t(P)·tanθ☉，
    // 由 scene3d 逐点算（见 windowVisibilityBatch），与窗宽无因果。
    sunAngularRadiusDeg: (light.source == LightSource.moon
                ? kMoonAngularDiameterDeg // 月角径 ≠ 日角径（甲类⑤）
                : sunAngularDiameterDeg(light.sunAlt)) *
            0.5 *
            spec.penumbraScale,
    // 环日散射（aureole）能量占比由气溶胶决定：真源 = 能见度经
    // Koschmieder 反解的 AOD550（astro.aod550FromVisibility）。
    // 月光分支：月面是均匀朗伯散射面（无临边昏暗、无环日晕），
    // aureole 权重压到 0。
    isMoon: light.source == LightSource.moon,
    wetGround: spec.weather.wetGround,
    aod550: light.source == LightSource.moon
        ? 0.0
        : aod550FromVisibility(spec.visibilityM,
            dayOfYear: spec.time.difference(
                    DateTime.utc(spec.time.year, 1, 1))
                .inDays +
                1),
    // 曝光不在这里施加：它属于成像过程，须对**全部辐射**统一施加，
    // 否则直射与环境会落在不同的响应区间（见 synthesize 的说明）。
    exposureEv: 1.0,
  ));

  // 7. 环境光（天光漫射 × 窗口孔径照度场）
  //
  // 孔径照度场需要**太阳方向**：透过窗面不同位置看到的天空亮度不同
  // （太阳那侧最亮、地平线以下最暗），环境光因此才有方向结构。
  final altForLight =
      light.source == LightSource.moon ? light.moonAlt : light.sunAlt;
  final sunDirRoom = scene.sunToRoomDir(light.sunAz, altForLight);
  final toSunAmbient = <double>[
    -sunDirRoom[0],
    -sunDirRoom[1],
    -sunDirRoom[2],
  ];
  final aperture = illuminationField(trace.pts, trace.valid, scene,
      toSun: toSunAmbient,
      sunAltDeg: altForLight,
      // 直射/漫射比：地平线以下的"室外地面"亮度含直射分量（阳光下的地面
      // 与晴空天顶同量级甚至更亮），必须传进去（旧实现恒传 0）。
      beamToDiffuse: light.diffuseIrradiance > 1e-9
          ? light.beamIrradiance / light.diffuseIrradiance
          : 0.0,
      groundAlbedo: spec.weather.wetGround ? kGroundAlbedoWet : kGroundAlbedoDry,
      cloudCover: spec.weather.cloudCover,
      width: width,
      height: height);
  final ambientRgb = Float32List(n * 3);
  // 【真 bug】暮光/夜空的 ambientColor 此前直接复用 light.color
  // （暮光=地平线方向的太阳色，已经偏暖），旧实现还把暮光漫射
  // 硬编码 0.06 不随太阳几何变化。这里统一：暮光漫射也按太阳
  // 几何推（天光随 |sunAlt| 衰减），夜空沿用 nightSkyIrradiance。
  final ambColor = switch (light.source) {
    LightSource.sun => skyColor(light.sunAlt),
    LightSource.twilight => twilightAmbientColor(light.sunAlt),
    _ => light.color,
  };
  // 环境光的**绝对量级**必须带物理量纲：
  //   E_wall(P) = L_win · Ω(P)，  L_win = E_sky/π（朗伯天空）
  // 孔径场只给相对分布（均值 1），这里乘上 "1/π × 典型立体角" 才还原出
  // 真正的照度。早期实现直接用 E_sky 乘（等于假定 Ω/π = 1），环境光因此
  // 比物理值高约 26 倍 —— 与直射光斑差不多亮，而晴天直射应该高 1~2 个数量级。
  // 环境光的**绝对量级**必须带物理量纲：
  //   E_wall(P) = L_win · Ĝ(P) = E_sky · (Ĝ / I_h)
  // 其中 Ĝ = 窗对观察墙的双余弦积分均值、I_h = 天空分布的水平漫射积分
  // （L_win = E_sky/I_h 是"漫射水平照度 → 天顶/窗外辐亮度"的正确换算）。
  // 旧实现把还原因子写成"窗对墙点的立体角 Ω = A·cosθ/d²"（再除 π），
  // 只在"小而远的窗"才近似成立：默认几何下 Ω/π = 0.0557，而 Ĝ/I_h ≈ 0.0186
  // → 环境光被系统性抬高 **3.0×（1.58 EV）**，且与太阳高度角无关（傍晚同样
  // 过亮）。这正是"画面平灰、光斑像贴上去"的主因之一。
  final gHat = doubleCosineIntegralMean(scene);
  final iH = horizontalDiffuseIntegral();
  final ambScale = light.diffuseIrradiance * gHat / math.max(iH, 1e-6);
  // 环境光色度按**亮度**（Rec.709）归一化为 1，量级全部由 ambScale 承担。
  // 旧实现按"三通道和 = 3"归一化，与直射用的 sunColor（亮度归一）量纲不一致，
  // 在环境/直射配比上引入 ~3× 的系统偏差。
  // 环境光**逐像素着色**：上半天光偏蓝（skyCol = 散射光谱），下半（室外
  // 地面反射）偏暖（sunColor）。旧实现整面墙乘一个与位置无关的常数色，
  // 等价于假设整个窗同色。
  final skyCol = ambColor;
  // ── 七波段环境光（光谱域混合与材质吸收）──
  // ambSpecBands：天光波段（有光谱时）；groundSpecBands：地面所见光的
  // 波段 = 直射×地面反照率谱 + 天光×地面反照率谱（中性反照率仅标量缩放，
  // 这里归一形状）。混合权重 wBeam 与 RGB 路径一致。
  final specM = rgbToBandMatrix();
  final specInt = bandToRgbWeights();
  final ambSpecBands = light.ambientSpectrum;
  // 室外地面所见之色/谱 = 照到地面的光（直射×投影 + 漫射）× 中性反照率
  final beamProj = light.beamIrradiance *
      math.max(math.sin(math.max(altForLight, 0.0) * kDeg), 0.0);
  final diffIrr = light.diffuseIrradiance;
  final wBeam =
      (beamProj + diffIrr) > 1e-12 ? beamProj / (beamProj + diffIrr) : 0.0;
  Float64List? groundSpecBands;
  if (ambSpecBands != null) {
    final gAlbSpec = Float64List(kSpectralN);
    const gAlbedo = kGroundAlbedoDry;
    final sunSpec = light.beamSpectrum;
    for (var bI = 0; bI < kSpectralN; bI++) {
      // 地面反射 = 直射分量 × 地面反照率 + 天光分量 × 地面反照率
      final sunE = sunSpec != null ? sunSpec[bI] : 1.0;
      gAlbSpec[bI] =
          (sunE * wBeam + ambSpecBands[bI] * (1 - wBeam)) * gAlbedo;
    }
    groundSpecBands = gAlbSpec;
  }
  // 室外地面所见之色 = **照到地面的光**的颜色（直射×投影 + 漫射）× 中性反照率。
  // 关键：夜间/暮光无直射时，地面只受月光/天光照射 → 冷灰蓝；
  // 旧实现写死 `sunColorFromAltitude(max(alt,0))`，夜里等于取了"地平线上的
  // 落日色"（深橙红），于是整面墙被刷上一层红条。
  final sunCol = sunColorFromAltitude(math.max(altForLight, 0.0));
  final groundCol = <double>[
    skyCol[0] * (1 - wBeam) + sunCol[0] * wBeam,
    skyCol[1] * (1 - wBeam) + sunCol[1] * wBeam,
    skyCol[2] * (1 - wBeam) + sunCol[2] * wBeam,
  ];
  final gshare = groundShareField(trace.pts, trace.valid, scene);
  // 【白名单 kAmbientSunWarmth / kAmbientChromaGain】环境光的方向性暖化：
  // 真实房间窗侧环境光含低层大气散射（色温低于天顶天光），旧实现整面
  // 墙用同一份天顶色 → "环境光完全不跟太阳转"。按墙点到窗的方位
  // （窗内侧向阳），混入直射色温的暖分量；kAmbientChromaGain 把物理
  // 正确但 8bit 下偏保守的色温差放大到可感区间（增益而非伪造）。
  // 【白名单暖化的波段版】向阳暖化在光谱域表达：观察墙的入射环境光 =
  // 天光成分 × (1−warm) + 直射光谱成分 × warm（窗侧方向性混合）——
  // 这不是给 RGB 加暖色，而是"窗侧看到的天空里有更多直射散射成分"的
  // 波段级替换。kAmbientChromaGain 仍作为混合权重的增益。
  final warmMix = kAmbientSunWarmth * kAmbientChromaGain;
  Float64List? warmAmbSpec;
  if (ambSpecBands != null && light.beamSpectrum != null) {
    warmAmbSpec = Float64List(kSpectralN);
    for (var bI = 0; bI < kSpectralN; bI++) {
      warmAmbSpec[bI] = ambSpecBands[bI] * (1 - warmMix.clamp(0.0, 0.9)) +
          light.beamSpectrum![bI] * warmMix.clamp(0.0, 0.9);
    }
  }
  final useSpec = warmAmbSpec != null && groundSpecBands != null;
  for (var i = 0; i < n; i++) {
    final gs = gshare[i];
    if (useSpec) {
      // ── 七波段环境光：入射谱(天光/地面按 gshare 混合) × 材质反射谱 → RGB ──
      final aR = material.albedo[i * 3],
          aG = material.albedo[i * 3 + 1],
          aB = material.albedo[i * 3 + 2];
      var sr = 0.0, sg = 0.0, sb = 0.0;
      for (var bI = 0; bI < kSpectralN; bI++) {
        final inc = warmAmbSpec[bI] * (1 - gs) + groundSpecBands[bI] * gs;
        final alb = aR * specM[bI][0] + aG * specM[bI][1] + aB * specM[bI][2];
        final e = inc * alb;
        sr += e * specInt[bI][0];
        sg += e * specInt[bI][1];
        sb += e * specInt[bI][2];
      }
      // 亮度归一由 ambScale 承担（旧路径 cy 归一）：这里把 RGB 按其亮度
      // 归一，保持与 ambScale 的量纲契约。
      final ry = 0.2126 * sr + 0.7152 * sg + 0.0722 * sb;
      if (ry < 1e-9) {
        ambientRgb[i * 3] = 0;
        ambientRgb[i * 3 + 1] = 0;
        ambientRgb[i * 3 + 2] = 0;
        continue;
      }
      final f = aperture[i] * ambScale;
      ambientRgb[i * 3] = sr / ry * f;
      ambientRgb[i * 3 + 1] = sg / ry * f;
      ambientRgb[i * 3 + 2] = sb / ry * f;
    } else {
      // ── 旧 RGB 路径（月光/夜间无光谱时兜底）──
      final gs2 = gshare[i];
      var cr = skyCol[0] * (1 - gs2) + groundCol[0] * gs2;
      var cg = skyCol[1] * (1 - gs2) + groundCol[1] * gs2;
      var cb = skyCol[2] * (1 - gs2) + groundCol[2] * gs2;
      final warm = warmMix * (sunCol[0] - sunCol[2]);
      cr = (cr + warm * 0.5).clamp(0.0, 4.0);
      cb = (cb - warm * 0.5).clamp(0.0, 4.0);
      var cy = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb;
      if (cy < 1e-6) cy = 1.0;
      final f = aperture[i] * ambScale / cy;
      ambientRgb[i * 3] = material.albedo[i * 3] * cr * f;
      ambientRgb[i * 3 + 1] = material.albedo[i * 3 + 1] * cg * f;
      ambientRgb[i * 3 + 2] = material.albedo[i * 3 + 2] * cb * f;
    }
  }

  // 7.5 曝光适应：对**全部辐射统一施加**（相机测光 / 人眼适应的真实行为）
  //
  // 依据是画面平均辐亮度，而不是入射照度 —— 这样当光照的绝对量级被修正
  // （例如环境光量级物理化、玻璃 Fresnel 改变了直射总量）时，画面整体
  // 曝光会自动跟上，不会出现"量级对了但画面全黑"。
  // 曝光必须统一施加：只对直射施加会让直射与环境落在不同响应区间。
  // 测光：画面亮度**中位数**（稳健；算术均值最容易被光斑/高光拉爆）。
  // 为避免对 2M 像素全排序，按步长抽样后取中位数 —— 抽样对中位数的影响
  // 远小于对均值的影响（中位数对尾部不敏感）。
  final step = math.max(1, n ~/ 60000);
  final samp = <double>[];
  for (var i = 0; i < n; i += step) {
    samp.add((trace.rgb[i * 3] +
                trace.rgb[i * 3 + 1] +
                trace.rgb[i * 3 + 2]) /
            3.0 +
        (ambientRgb[i * 3] +
                ambientRgb[i * 3 + 1] +
                ambientRgb[i * 3 + 2]) /
            3.0);
  }
  samp.sort();
  final meanLum = samp.isEmpty ? 1.0 : samp[samp.length ~/ 2];
  // 绝对量纲标定（丙类 --absolute-lux，可选）：中位亮度对准目标 lux。
  // 物理依据：渲染量的中间表示以"晴空正午漫射 ~10000 lux"为 1.0，故
  // ev = log2(目标 lux / 10000 / meanLum)。停用自动曝光是本模式的前提
  // —— 自动测光会把季节/天气的绝对差异重新抹平。
  // 绝对量纲标定（丙类 --absolute-lux）：中间表示以"晴空正午漫射天空
  // 水平面照度 10000 lux ≈ 1.0"为基准，故 meanLum(1.0) 对应 10000 lux，
  // 目标中位 lux 为 L → ev = log2(L / 10000 / meanLum)。自动曝光停用后
  // 由 EV 钳制防极端（±6 EV，覆盖 0.1~6000 lux 室内典型范围）。
  final evRaw = spec.absoluteLux != null
      ? (math.log((spec.absoluteLux! / 10000.0) /
              math.max(meanLum, 1e-9)) /
          math.ln2)
      : sceneExposureEv(meanLum);
  // 【钳制只在绝对标定模式生效】自动曝光的动态范围必须保持开放：
  // 夜间场景真实需要 EV≈200+（meanLum~1e-4），若钳到 ±6 会让夜景死黑
  // （本轮门禁实测：夜间三景死黑 100% 均由此而来）。±6 EV 的意图是
  // 防绝对标定模式下用户给出的 lux 目标失真（如 1e-9），那是输入
  // 卫生问题，不是辐射物理的上限 —— 自动模式不该替物理设上限。
  final ev = spec.absoluteLux != null ? evRaw.clamp(-6.0, 6.0) : evRaw;
  light.exposureEv = ev; // 上报的 EV 与实际施加的 EV 保持一致（PI-4）

  // 8. 合成（全部辐射线性求和后统一色调映射）
  // patchMask 用**未乘曝光**的直射辐亮度：否则一次弹射的强度会变成 ∝ 曝光²
  // （物理上反弹量只与辐照度有关），随自动曝光漂移（PI-9）。
  final patchMask = Float32List(n);
  for (var i = 0; i < n; i++) {
    patchMask[i] = math.min(
        1.0, trace.rgb[i * 3] + trace.rgb[i * 3 + 1] + trace.rgb[i * 3 + 2]);
  }
  final direct = Float32List(n * 3);
  for (var i = 0; i < n * 3; i++) {
    direct[i] = trace.rgb[i] * ev;
    ambientRgb[i] = ambientRgb[i] * ev;
  }
  var linear = synthesize(
    direct: direct,
    ambient: ambientRgb,
    width: width,
    height: height,
    look: spec.look,
    materialVariation: matVar,
    patchMask: patchMask,
  );

  // 8.5 Tyndall 光柱（乙类②，默认启用）+ 侧墙二次光（乙类④，默认启用）
  //
  // ② Tyndall：真实空气中有气溶胶，直射光在传播路径上被散射一部分——
  //    晴天从窗斜射进屋能看到"光柱"。强度 ∝ 光束辐亮度 × 路径气溶胶密度。
  //    实现：沿"窗矩形 → 光斑方向"的几何锥给画面加微弱的同色雾光，
  //    锥体半宽按窗宽，衰减按到窗的距离。量级小（σ≈0.004/段），只在
  //    直射存在时出现（夜间无）。
  // ④ 侧墙二次光：直射光斑落在地板/天花后，侧墙（画面左右边缘）会接到
  //    它的一次漫反射——现有 patchMask 弹射只覆盖观察墙自身。给画面左右
  //    边缘按"光斑亮度×邻墙反照率×几何因子"补一层微光。
  if (light.beamIrradiance > 1e-9 && light.sunAlt > 0.0) {
    final pl = scene.placement();
    // Tyndall：以窗中心为锥顶、光斑中心为锥底的柔光锥（屏幕空间近似）
    final winCx = (pl.u0 + pl.u1) * 0.5;
    final winCy = (pl.v0 + pl.v1) * 0.5;
    final winW = (pl.u1 - pl.u0).abs() + 1e-9;
    final beamLum = (0.2126 * light.color[0] +
            0.7152 * light.color[1] +
            0.0722 * light.color[2]) *
        light.beamIrradiance;
    final tyndallK = beamLum * 0.004;
    // 房间系太阳方向（sy 翻转为屏幕向下为正的近似）
    final tSx = -sunDirRoom[0], tSy = sunDirRoom[1];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final px = x + 0.5, py = y + 0.5;
        // 点到"窗中心→太阳反方向"轴的垂距（屏幕空间近似）
        final dx = px - winCx, dy = py - winCy;
        final t = (dx * tSx + dy * tSy).clamp(0.0, 1e9);
        final perp2 =
            (dx * dx + dy * dy) - t * t;
        // 锥半宽随距离扩（张角≈窗半宽/100px）
        final halfW = winW * 0.5 + t * (winW * 0.5) / 100.0;
        final inCone = math.exp(-perp2 / (2 * halfW * halfW + 1e-9));
        final fall = math.exp(-t / 400.0); // 沿轴衰减
        final add = tyndallK * inCone * fall;
        if (add > 1e-9) {
          linear[i * 3] += add * light.color[0];
          linear[i * 3 + 1] += add * light.color[1];
          linear[i * 3 + 2] += add * light.color[2];
        }
      }
    }
  }

  // 9. 编码
  var rgbBytes = encodeSrgbBytes(linear);

  // 10. 叠字
  //
  // 【待决策 PI-11】叠字目前在 **sRGB 字节域**做 alpha 合成（文字不参与光照
  // 与色调映射），这是"题字/印章作为画面叠加层"的产品选择；若要"字也是墙面
  // 的一部分"，必须改为在**线性域**合成、一起过色调映射（代价：叠字需要是
  // 一份线性反射率层）。是否物理化属产品定位决策。
  if (textAlpha != null) {
    final alpha = spec.applyAging
        ? generateAgedAlpha(
            textAlpha,
            width,
            height,
            seed: spec.seed,
            params: spec.aged,
            matVar: matVar,
            materialStrength: spec.materialCoupling,
          )
        : textAlpha;
    // 接触阴影偏移：字凸出墙面，影子落在**背光侧**，方向随窗户朝向/时间旋转
    // （用房间坐标系的"太阳→房间"方向在墙面的投影）。
    final altForShadow =
        light.source == LightSource.moon ? light.moonAlt : light.sunAlt;
    // 接触阴影：字相对墙面凸起一个**物理高度** reliefM，其投影长度 =
    // reliefM / tan(太阳高度角)，方向 = 光行进方向在墙面的水平投影。
    // 旧实现是 0.0022/0.0012/clamp 一组手调常数（影子长度与太阳高度角脱钩、
    // 还带一个向下的固定偏置），物理上影子长度只由凸起高度与太阳仰角决定。
    final sdir = scene.sunToRoomDir(
        light.sunAz, light.source == LightSource.moon ? light.moonAlt : light.sunAlt);
    // 屏幕坐标：x 向右、y 向下
    final hxm = sdir[0];
    final hym = -sdir[1];
    final hmag = math.sqrt(hxm * hxm + hym * hym);
    const double reliefM = 0.0015; // 叠字凸起高度（米）
    final shadowLenM =
        reliefM / math.max(math.tan(math.max(altForShadow, 2.0) * kDeg), 0.05);
    final fracLen = shadowLenM / math.max(scene.cfg.roomH, 0.1);
    final shadowDx = hmag > 1e-6 ? (hxm / hmag) * fracLen : 0.0;
    final shadowDy = hmag > 1e-6 ? (hym / hmag) * fracLen : 0.0;
    final occ = computeContactShadow(alpha, width, height,
        shadowDx: shadowDx, shadowDy: shadowDy);
    rgbBytes = fuseText(
      baseSrgb: rgbBytes,
      width: width,
      height: height,
      alpha: alpha,
      occlusion: occ,
      cinnabar: spec.cinnabar,
      shadowStrength: spec.shadowStrength,
    );
  }

  return RenderResult(
    rgb: rgbBytes,
    width: width,
    height: height,
    light: light,
    albedoStats: <String, double>{
      'albedo_mean': _mean(retinex.albedo),
      'bright_ratio': retinex.brightRatio,
      'dark_ratio': retinex.darkRatio,
      'visible_ratio': trace.visibleRatio,
      'incidence_cos': trace.incidenceCos,
      'exposure_ev': ev,
      'mean_lum': meanLum,
      'ambient_factor': ambScale / math.max(light.diffuseIrradiance, 1e-12),
    },
  );
}

// 说明：旧的 `_penumbraFor`（把半影写成"半径 / 窗宽"的无量纲比例）已删除：
// 半影半径是绝对长度 r(P)=t(P)·tanθ☉，由 scene3d 逐点算。pipeline 现在直接
// 传入光源角半径（见 traceScene 调用处）。

double _mean(Float32List arr) {
  var s = 0.0;
  for (var i = 0; i < arr.length; i++) {
    s += arr[i];
  }
  return arr.isEmpty ? 0 : s / arr.length;
}
