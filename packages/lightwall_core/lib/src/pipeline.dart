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
  final double exposureEv;
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
    this.penumbra = 0.006,
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
  final double penumbra;
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
    final exposure = eyeExposureEv(beam + diffuse, sunAlt: sunAlt);
    return LightInfo(
      source: LightSource.sun,
      sunAlt: sunAlt,
      sunAz: toSunAz,
      moonAlt: moon.altitude,
      moonPhase: phase,
      beamIrradiance: beam,
      diffuseIrradiance: diffuse,
      color: color,
      exposureEv: exposure,
      label: '日光 ${sunAlt.toStringAsFixed(1)}°',
    );
  }

  if (sunAlt > -6) {
    final color = twilightColor(sunAlt);
    final scatter = ((0 - sunAlt) / 6.0).clamp(0.0, 1.0);
    return LightInfo(
      source: LightSource.twilight,
      sunAlt: sunAlt,
      sunAz: toSunAz,
      moonAlt: moon.altitude,
      moonPhase: phase,
      beamIrradiance: 0.0,
      diffuseIrradiance: 0.06 * scatter,
      color: color,
      exposureEv: 1.0,
      label: '暮光 ${sunAlt.toStringAsFixed(1)}°',
    );
  }

  if (moon.altitude > 5) {
    return LightInfo(
      source: LightSource.moon,
      sunAlt: sunAlt,
      sunAz: toSunAz,
      moonAlt: moon.altitude,
      moonPhase: phase,
      beamIrradiance: moonIrradiance(moon.altitude, phase),
      diffuseIrradiance: 0.012,
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
    color: const <double>[0.30, 0.36, 0.58],
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
  final material = extractMaterial(retinex.albedo, width, height);
  final matVar = materialVariation(retinex.albedo, width, height);

  // 4. 光源
  final light = computeLightInfo(
    time: spec.time,
    lat: spec.lat,
    lon: spec.lon,
    windowAz: spec.windowAz,
  );

  // 5. 场景
  final sceneCfg = spec.sceneCfg.build();
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
    diffuseIrradiance: 0.0,
    ambientColor: light.color,
    penumbra: spec.penumbra,
    exposureEv: light.exposureEv,
  ));

  // 7. 环境光（天光漫射 × 窗口孔径照度场）
  final aperture = illuminationField(trace.pts, trace.valid, scene,
      width: width, height: height);
  final ambientRgb = Float32List(n * 3);
  final ambColor = light.source == LightSource.sun
      ? skyColor(light.sunAlt)
      : light.color;
  final ambScale = light.diffuseIrradiance * light.exposureEv;
  var ambMean = ambColor[0] + ambColor[1] + ambColor[2];
  if (ambMean < 1e-6) ambMean = 1.0;
  final ar = ambColor[0] / ambMean * 3.0;
  final ag = ambColor[1] / ambMean * 3.0;
  final ab = ambColor[2] / ambMean * 3.0;
  for (var i = 0; i < n; i++) {
    final f = aperture[i] * ambScale;
    ambientRgb[i * 3] = material.albedo[i * 3] * ar * f;
    ambientRgb[i * 3 + 1] = material.albedo[i * 3 + 1] * ag * f;
    ambientRgb[i * 3 + 2] = material.albedo[i * 3 + 2] * ab * f;
  }

  // 8. 合成（直射先过 ACES）
  final direct = Float32List(n * 3);
  for (var i = 0; i < n * 3; i++) {
    direct[i] = trace.rgb[i];
  }
  final patchMask = Float32List(n);
  for (var i = 0; i < n; i++) {
    patchMask[i] = math.min(1.0, trace.rgb[i * 3] + trace.rgb[i * 3 + 1] + trace.rgb[i * 3 + 2]);
  }
  final linear = synthesize(
    direct: direct,
    ambient: ambientRgb,
    width: width,
    height: height,
    look: spec.look,
    materialVariation: matVar,
    patchMask: null,
  );

  // 9. 编码
  var rgbBytes = encodeSrgbBytes(linear);

  // 10. 叠字
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
    final shadowDx = -math.sin(light.sunAz * kDeg) * 0.002;
    final shadowDy = 0.003;
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
      'exposure_ev': light.exposureEv,
    },
  );
}

double _mean(Float32List arr) {
  var s = 0.0;
  for (var i = 0; i < arr.length; i++) {
    s += arr[i];
  }
  return arr.isEmpty ? 0 : s / arr.length;
}
