// 逐像素着色（光线追踪光照）
//
// 参考实现的核心：相机射线 → 观察墙求交 → 材质采样 → 窗户可见性 →
// 漫反射 + Cook-Torrance 镜面 + 天光环境 + 窗口孔径照度场 → 线性 RGB。
//
// 本项目相对参考实现的修正：
//   · 窗户入射余弦只乘一次（参考实现在 patch_geometry 与 raytrace 里各乘一次，
//     等于把掠射衰减算了两遍，导致低角度光斑被过度削弱）
//   · 窗户朝向走通用墙面模型（见 scene3d.dart）
//   · 去掉全部天气分支（本产品只有晴天）
import 'dart:math' as math;
import 'dart:typed_data';

import 'atmosphere.dart';
import 'material.dart';
import 'scene3d.dart';

/// 着色输入。
class TraceInput {
  TraceInput({
    required this.scene,
    required this.material,
    required this.sunAzGeo,
    required this.sunAlt,
    required this.sunColor,
    required this.beamIrradiance,
    required this.diffuseIrradiance,
    required this.ambientColor,
    required this.penumbra,
    this.exposureEv = 1.0,
  });

  final Scene3D scene;
  final MaterialMaps material;
  final double sunAzGeo;
  final double sunAlt;
  final List<double> sunColor;
  final double beamIrradiance;
  final double diffuseIrradiance;
  final List<double> ambientColor;

  /// 半影比例（相对窗宽），0 = 硬边。
  final double penumbra;

  /// 视觉适应曝光（ACES 之前乘到线性辐照度上）。
  final double exposureEv;
}

/// 着色输出。
class TraceOutput {
  TraceOutput({
    required this.rgb,
    required this.width,
    required this.height,
    required this.valid,
    required this.pts,
    required this.visibleRatio,
    required this.incidenceCos,
  });

  /// 线性 RGB（w*h*3）
  final Float32List rgb;
  final int width;
  final int height;

  /// 墙命中掩码
  final Float64List valid;

  /// 墙交点坐标（w*h*3）
  final Float64List pts;

  /// 直射可见像素占比
  final double visibleRatio;

  /// 窗户入射余弦
  final double incidenceCos;
}

/// 执行着色。
TraceOutput traceScene(TraceInput input) {
  final scene = input.scene;
  final mat = input.material;
  final w = mat.width;
  final h = mat.height;
  final n = w * h;

  final (origins, dirs) = scene.screenToRayBatch(w, h);
  final (valid, pts) = scene.rayWallIntersectBatch(origins, dirs);

  final sunDir = scene.sunToRoomDir(input.sunAzGeo, input.sunAlt);
  final toSun = <double>[-sunDir[0], -sunDir[1], -sunDir[2]];

  // 窗户入射余弦（只乘一次）
  final winNormal = scene.windowOutwardNormal();
  final cosInc = windowIncidenceCos(toSun, winNormal);

  // 玻璃 Fresnel 透射：掠射时玻璃把大部分光**反射回室外**，透射率骤降
  // （cos 0.05 → T 0.12）。早期实现用 `max(0.05, cos)` 这种人为下限兜住
  // 掠射，那只是掩盖问题：真正让掠射趋近于零的是物理（投影面积 ×
  // 双面玻璃透射），不需要任何下限。
  final glassT = glassTransmittance(cosInc);

  // 直射可见性（穿窗 + 窗格）
  final visible =
      scene.windowVisibilityBatch(pts, sunDir, penumbra: input.penumbra);

  final cam = scene.camPos;
  final albedo = mat.albedo;
  final normal = mat.normal;
  final roughness = mat.roughness;
  final specularTex = mat.specular;
  final isWater = mat.isWater;

  final out = Float32List(n * 3);
  final sunR = input.sunColor[0],
      sunG = input.sunColor[1],
      sunB = input.sunColor[2];
  final ambR = input.ambientColor[0],
      ambG = input.ambientColor[1],
      ambB = input.ambientColor[2];
  // 直射总因子 = 入射余弦（窗的投影面积）× 玻璃透射（Fresnel）
  final beamScaleAll =
      input.beamIrradiance * cosInc * glassT * input.exposureEv;

  var visibleCount = 0.0;

  for (var i = 0; i < n; i++) {
    final o = i * 3;
    final i3 = i * 3;
    final aR = albedo[i3], aG = albedo[i3 + 1], aB = albedo[i3 + 2];

    if (valid[i] <= 0) {
      // 未命中墙（理论上不会发生）：给微弱环境光兜底。
      // 【真 bug 清理】此前这里乘 ambientScale（由 pipeline 恒传 0 的
      // diffuseIrradiance 推出），是真死代码；漫射归 pipeline 第 7 步管。
      out[i3] = aR * ambR * 0.01 * input.exposureEv;
      out[i3 + 1] = aG * ambG * 0.01 * input.exposureEv;
      out[i3 + 2] = aB * ambB * 0.01 * input.exposureEv;
      continue;
    }

    final px = pts[o], py = pts[o + 1]; // pz 恒为 0
    final nx = normal[i3], ny = normal[i3 + 1], nz = normal[i3 + 2];

    // N·L（观察墙法线 +Z，但用材质法线做凹凸调制）
    var ndl = nx * toSun[0] + ny * toSun[1] + nz * toSun[2];
    if (ndl < 0) ndl = 0;
    final vis = visible[i];
    visibleCount += vis;
    final ndlV = ndl * vis;

    // 漫反射
    final kd = ndlV * beamScaleAll;
    var r = aR * sunR * kd;
    var g = aG * sunG * kd;
    var b = aB * sunB * kd;

    // 镜面（Cook-Torrance GGX + Smith + Schlick）
    if (ndlV > 0) {
      // 视线方向：P → 相机
      var vx = cam[0] - px;
      final vy = cam[1] - py;
      var vz = cam[2];
      final vInv = 1.0 / math.max(math.sqrt(vx * vx + vy * vy + vz * vz), 1e-6);
      vx *= vInv;
      final vy2 = vy * vInv;
      final vz2 = vz * vInv;

      var hx = vx + toSun[0];
      var hy = vy2 + toSun[1];
      var hz = vz2 + toSun[2];
      final hInv = 1.0 / math.max(math.sqrt(hx * hx + hy * hy + hz * hz), 1e-6);
      hx *= hInv;
      hy *= hInv;
      hz *= hInv;

      final ndv = math.max(nx * vx + ny * vy2 + nz * vz2, 0.0);
      final ndh = math.max(nx * hx + ny * hy + nz * hz, 0.0);
      final specBrdf = _cookTorrance(ndl, ndv, ndh, roughness[i]);
      final specTex = 1.0 + specularTex[i] * 0.5;
      final specK = specBrdf * specTex * vis * beamScaleAll;
      r += sunR * specK;
      g += sunG * specK;
      b += sunB * specK;
    }

    // 水面：Fresnel 环境反射 + 锐高光
    if (isWater[i] != 0) {
      var vx = cam[0] - px;
      final vy = cam[1] - py;
      var vz = cam[2];
      final vInv = 1.0 / math.max(math.sqrt(vx * vx + vy * vy + vz * vz), 1e-6);
      vx *= vInv;
      final vy2 = vy * vInv;
      final vz2 = vz * vInv;
      final ndv = math.max(nx * vx + ny * vy2 + nz * vz2, 0.0);
      final f = 0.02 + 0.98 * math.pow(1.0 - ndv, 5).toDouble();

      // 反射方向
      var rx = 2.0 * ndv * nx - vx;
      var ry = 2.0 * ndv * ny - vy2;
      var rz = 2.0 * ndv * nz - vz2;
      final rInv = 1.0 / math.max(math.sqrt(rx * rx + ry * ry + rz * rz), 1e-6);
      rx *= rInv;
      ry *= rInv;
      rz *= rInv;
      final up = ry.clamp(0.0, 1.0);
      final envR =
          (0.55 * up + 1.00 * (1 - up)) * f * 0.15 * input.beamIrradiance;
      final envG =
          (0.68 * up + 0.85 * (1 - up)) * f * 0.15 * input.beamIrradiance;
      final envB =
          (1.00 * up + 0.65 * (1 - up)) * f * 0.15 * input.beamIrradiance;

      var hx = vx + toSun[0];
      var hy = vy2 + toSun[1];
      var hz = vz2 + toSun[2];
      final hInv = 1.0 / math.max(math.sqrt(hx * hx + hy * hy + hz * hz), 1e-6);
      hx *= hInv;
      hy *= hInv;
      hz *= hInv;
      final ndh = math.max(nx * hx + ny * hy + nz * hz, 0.0);
      final spec = math.pow(ndh, 200.0).toDouble() * input.beamIrradiance;
      r = r + envR + sunR * spec;
      g = g + envG + sunG * spec;
      b = b + envB + sunB * spec;
    }

    out[i3] = r;
    out[i3 + 1] = g;
    out[i3 + 2] = b;
  }

  return TraceOutput(
    rgb: out,
    width: w,
    height: h,
    valid: valid,
    pts: pts,
    visibleRatio: visibleCount / math.max(1, n),
    incidenceCos: cosInc,
  );
}

/// Cook-Torrance BRDF（D: GGX，G: Smith，F: Schlick，F0 = 0.04）。
double _cookTorrance(double ndl, double ndv, double ndh, double roughness) {
  final a = math.pow(math.max(roughness, 0.03), 2).toDouble();
  final a2 = a * a;
  final denomH = ndh * ndh * (a2 - 1.0) + 1.0;
  final d = a2 / (math.pi * denomH * denomH + 1e-6);
  final k = a / 2.0;
  final g1l = ndl / (ndl * (1 - k) + k + 1e-6);
  final g1v = ndv / (ndv * (1 - k) + k + 1e-6);
  final g = g1l * g1v;
  final f = 0.04 + 0.96 * math.pow(1.0 - ndv, 5).toDouble();
  final brdf = (d * g * f) / (4.0 * ndl * ndv + 1e-6);
  return brdf.clamp(0.0, 20.0);
}
