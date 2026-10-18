// 渲染管线编排：底图 → Retinex → 材质 → 光照 → 着色 → 合成 → 叠字 → 编码
import 'dart:math' as math;
import 'dart:typed_data';

import 'astro.dart';
import 'compose.dart';
import 'lightgen.dart';
import 'retinex.dart';
import 'spectral.dart';
import 'scene3d.dart';
import 'textlayer.dart';
import 'tuning.dart';

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
      // 月光七波段：月面反射谱 × 大气 × 珀金杰位移（银白感，白名单）
      beamSpectrum: moonSpectrumBands(moon.altitude),
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

  // ═══════════════════════════════════════════════════════════════
  // 算法光照（取代光线追踪/光谱积分）：只关心入射角、面积、光晕，
  // 直接生成画面。全部可调量集中在 lightgen.LightLook。
  // ═══════════════════════════════════════════════════════════════
  final cfg = spec.sceneCfg.build();
  final isMoon = light.source == LightSource.moon;
  final isNight = light.source == LightSource.night;
  final alt = isMoon ? light.moonAlt : light.sunAlt;
  final winAz = spec.windowAz < 0 ? light.sunAz : spec.windowAz;
  final sunAzRel = _angleDiff(light.sunAz, winAz + 180.0);

  // 三段调色（按太阳高度连续过渡）：白天明亮暖灰墙、黄昏深蓝墙配暖斑、
  // 夜间低钥匙冷银。数值对照真实照片统计（P50/亮部RGB/暗部RGB）。
  final altN = (alt.clamp(0.0, 90.0)) / 90.0; // 0=地平线 1=天顶
  final day = (altN * 1.8).clamp(0.0, 1.0); // 15° 以上基本算白天
  final dusk = (1.0 - day).clamp(0.0, 1.0);

  // 墙基底亮度：白天 0.62（亮灰）、黄昏 0.30、夜里 0.12
  final ambBase = isNight
      ? 0.10
      : (isMoon ? 0.16 : (0.30 + 0.34 * day));
  // 阴影色：白天偏中性暖灰，黄昏/夜间偏蓝
  final coolR = isNight ? 0.14 : (0.52 * day + 0.13 * dusk);
  final coolG = isNight ? 0.19 : (0.51 * day + 0.17 * dusk);
  final coolB = isNight ? 0.30 : (0.47 * day + 0.24 * dusk);
  // 光斑色：白天奶白（低饱和）、黄昏暖橙（高饱和）
  final warmR = 1.00;
  final warmG = isNight ? 0.62 : (0.95 * day + 0.72 * dusk);
  final warmB = isNight ? 0.86 : (0.88 * day + 0.52 * dusk);

  final lookGen = LightLook(
    shadowCool: 1.0,
    glowRadius: isMoon ? 0.035 : 0.05,
    glowStrength: isMoon ? 0.14 : (isNight ? 0.0 : 0.16),
    patchBrightness: isMoon ? 0.20 : (isNight ? 0.03 : (0.42 + 0.18 * day)),
    ambientLevel: ambBase,
    patchSoftness: 0.055,
    grain: (isNight || isMoon) ? 0.013 : 0.006,
  );

  final warm = <double>[warmR, warmG, warmB];
  final cool = <double>[coolR, coolG, coolB];

  final linearGen = generateWallLight(
    width: width,
    height: height,
    albedo: retinex.albedo,
    sunAzRel: sunAzRel,
    sunAlt: alt <= 0 ? 6.0 : alt,
    windowW: cfg.windowW,
    windowH: cfg.windowH,
    cols: spec.gridCols,
    rows: spec.gridRows,
    look: lookGen,
    warmColor: warm,
    coolColor: cool,
  );

  var outBytes = encodeSrgbBytes(linearGen);
  outBytes = _applyTextLayer(outBytes, textAlpha, spec, width, height, n);

  return RenderResult(
    rgb: outBytes,
    width: width,
    height: height,
    light: light,
    albedoStats: <String, double>{
      'mean_lum': lookGen.ambientLevel,
      'exposure_ev': 1.0,
      'incidence_cos': math.max(
          0.0,
          math.cos(sunAzRel * math.pi / 180) *
              math.sin((alt <= 0 ? 0 : alt) * math.pi / 180)),
      'visible_ratio': isNight ? 0.0 : (isMoon ? 0.05 : 0.12),
    },
  );
}


// 说明：旧的 `_penumbraFor`（把半影写成"半径 / 窗宽"的无量纲比例）已删除：
// 半影半径是绝对长度 r(P)=t(P)·tanθ☉，由 scene3d 逐点算。pipeline 现在直接
// 传入光源角半径（见 traceScene 调用处）。


/// 两个方位角之差（−180..180）。
double _angleDiff(double a, double b) {
  var d = (a - b) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d < -180.0) d += 360.0;
  return d;
}

/// 叠字：sRGB 字节域按 alpha 混合。
Uint8List _applyTextLayer(Uint8List rgb, Float32List? textAlpha, RenderSpec spec,
    int width, int height, int n) {
  if (textAlpha == null) return rgb;
  final alpha = spec.applyAging
      ? generateAgedAlpha(textAlpha, width, height,
          seed: spec.seed, params: spec.aged)
      : textAlpha;
  final out = Uint8List.fromList(rgb);
  final c = spec.cinnabar;
  for (var i = 0; i < n; i++) {
    final a = alpha[i];
    if (a <= 0.002) continue;
    final j = i * 3;
    out[j] = (out[j] * (1 - a) + c[0] * 255 * a).round().clamp(0, 255);
    out[j + 1] = (out[j + 1] * (1 - a) + c[1] * 255 * a).round().clamp(0, 255);
    out[j + 2] = (out[j + 2] * (1 - a) + c[2] * 255 * a).round().clamp(0, 255);
  }
  return out;
}
