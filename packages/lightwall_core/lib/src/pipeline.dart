// 渲染管线编排：底图 → Retinex → 材质 → 光照 → 着色 → 合成 → 叠字 → 编码
import 'dart:math' as math;
import 'dart:typed_data';

import 'astro.dart';
import 'atmosphere.dart';
import 'compose.dart';
import 'material.dart';
import 'retinex.dart';
import 'scene3d.dart';
import 'textlayer.dart';
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
  });

  final LightSource source;
  final double sunAlt;
  final double sunAz;
  final double moonAlt;
  final double moonPhase;
  final double beamIrradiance;
  final double diffuseIrradiance;
  final List<double> color;

  /// 实际施加的曝光倍率。构造时为占位 1.0，由 [render] 的测光结果写回
  /// （这样"上报的 EV"与"实际施加的 EV"始终一致）。
  double exposureEv;
  final String label;
}

/// 渲染参数。
class RenderSpec {
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
    this.shadowStrength = 0.25,
    this.cinnabar = kCinnabar,
    this.applyAging = true,
  });

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
}) {
  final sun = sunPosition(lat, lon, time);
  final moon = moonPosition(lat, lon, time);
  final phase = moonPhase(time);

  final sunAlt = sun.altitude;
  final toSunAz = sun.azimuth;

  if (sunAlt > 0) {
    final beam = solarIrradiance(sunAlt);
    final diffuse = skyIrradiance(sunAlt);
    final color = sunColorFromAltitude(sunAlt);
    // exposureEv 不再在这里估：真实曝光由画面测光（sceneExposureEv）在
    // render() 内算出并写回（旧实现把入射照度的幂律当曝光，且它与实际
    // 施加的 EV 不是同一个值 —— PI-4 的真 bug）。
    return LightInfo(
      source: LightSource.sun,
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
    final twiDiffuse = twilightDiffuse(sunAlt);
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
      diffuseIrradiance: moonBeam * 0.10,
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
    diffuseIrradiance: nightSkyIrradiance(moon.altitude, phase),
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
  );

  // 5. 场景：把 spec 上的窗格参数覆盖到场景配置
  final sceneCfg = spec.sceneCfg.build().copyWith(
        gridRows: spec.gridRows,
        gridCols: spec.gridCols,
        gridFrameRatio: spec.gridFrameRatio,
      );
  final scene = Scene3D(
    sceneCfg,
    spec.windowAz,
  );
  final materialWithGrid = material;

  // 6. 着色
  final trace = traceScene(TraceInput(
    scene: scene,
    material: materialWithGrid,
    sunAzGeo: light.sunAz,
    sunAlt: light.source == LightSource.moon ? light.moonAlt : light.sunAlt,
    sunColor: light.color,
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
    sunAngularRadiusDeg: sunAngularDiameterDeg(
            light.source == LightSource.moon ? light.moonAlt : light.sunAlt) *
        0.5 *
        spec.penumbraScale,
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
  // 室外地面所见之色 = **照到地面的光**的颜色（直射×投影 + 漫射）× 中性反照率。
  // 关键：夜间/暮光无直射时，地面只受月光/天光照射 → 冷灰蓝；
  // 旧实现写死 `sunColorFromAltitude(max(alt,0))`，夜里等于取了"地平线上的
  // 落日色"（深橙红），于是整面墙被刷上一层红条。
  final beamProj = light.beamIrradiance *
      math.max(math.sin(math.max(altForLight, 0.0) * kDeg), 0.0);
  final diffIrr = light.diffuseIrradiance;
  final wBeam =
      (beamProj + diffIrr) > 1e-12 ? beamProj / (beamProj + diffIrr) : 0.0;
  final sunCol = sunColorFromAltitude(math.max(altForLight, 0.0));
  final groundCol = <double>[
    skyCol[0] * (1 - wBeam) + sunCol[0] * wBeam,
    skyCol[1] * (1 - wBeam) + sunCol[1] * wBeam,
    skyCol[2] * (1 - wBeam) + sunCol[2] * wBeam,
  ];
  final gshare = groundShareField(trace.pts, trace.valid, scene);
  for (var i = 0; i < n; i++) {
    final gs = gshare[i];
    final cr = skyCol[0] * (1 - gs) + groundCol[0] * gs;
    final cg = skyCol[1] * (1 - gs) + groundCol[1] * gs;
    final cb = skyCol[2] * (1 - gs) + groundCol[2] * gs;
    var cy = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb;
    if (cy < 1e-6) cy = 1.0;
    final f = aperture[i] * ambScale / cy;
    ambientRgb[i * 3] = material.albedo[i * 3] * cr * f;
    ambientRgb[i * 3 + 1] = material.albedo[i * 3 + 1] * cg * f;
    ambientRgb[i * 3 + 2] = material.albedo[i * 3 + 2] * cb * f;
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
  final ev = sceneExposureEv(meanLum);
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
  final linear = synthesize(
    direct: direct,
    ambient: ambientRgb,
    width: width,
    height: height,
    look: spec.look,
    materialVariation: matVar,
    // 【真 bug】patchMask 上面已经算好（patchMask 变量），这里却传 null，
    // 导致 synthesize 里"光斑反弹光"（光斑周围暖晕）整段从不执行。
    patchMask: patchMask,
  );

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
