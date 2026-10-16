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

import 'astro.dart';
import 'atmosphere.dart';
import 'material.dart';
import 'scene3d.dart';

/// 介质界面的**法向**反射率 F0（Schlick 基）：F0 = ((n−1)/(n+1))²。
///
/// 玻璃 n = [kGlassIor] = 1.52（钠钙玻璃）→ F0 ≈ 0.043。参考实现写死的
/// 0.04 对应 n = 1.5，是同一个物理量的另一个取值；这里直接由 ior 导出，
/// 避免"同一个物理量在项目里有两个数字"。
/// （待决策项：① F0 全场统一 0.04/0.043 —— 金属/涂料的 F0 差一个量级，
///   应由材质给出，需产品与材质管线定；② `specTex = 1 + spec·0.5` 这个
///   ±50% 的手调乘子不是物理量。）
final double _kF0 = () {
  final r = (kGlassIor - 1.0) / (kGlassIor + 1.0);
  return r * r;
}();

/// Schlick Fresnel：F(θ) = F0 + (1−F0)(1−cosθ)⁵。
double _fresnelSchlick(double cosTheta, double f0) {
  final c = 1.0 - cosTheta;
  final c5 = c * c * c * c * c;
  return f0 + (1.0 - f0) * c5;
}

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
    this.penumbra = 0.0,
    this.sunAngularRadiusDeg,
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

  /// 【旧口径，只为向后兼容】半影采样半径 / 窗宽（无量纲）。
  ///
  /// 半影半径本身是**绝对长度** `r(P) = t(P)·tan θ☉`（t = 墙点到窗平面的
  /// 沿光距离，θ☉ = 光源角半径），与窗宽没有因果关系；把它写成"占窗宽的
  /// 比例"会让柔化程度随窗宽漂移，且截断点（pipeline 的 clamp(0,0.25)）
  /// 也随窗宽移动。
  ///
  /// 本字段在新代码里**不应再使用**：请改用 [sunAngularRadiusDeg]。
  /// 保留时的处理：按 pipeline `_penumbraFor` 的公式逆向换算出等效光源
  /// 角半径 θ = atan(penumbra·窗宽 / D_代表)，随后仍按逐点真实 t 计算半影
  /// ——即只继承旧口径的"量级"，不继承它"全画面单一距离"的错误。
  final double penumbra;

  /// **光源角半径（度）**：几何日面 ⊗ 环日散射的等效角半径，由外部天文/
  /// 大气模块给出（几何日面恒为 0.2665°；环日散射是低辐亮度幂律尾部，
  /// 会带来极小的额外加宽）。为空时由 astro 的 [sunAngularDiameterDeg] 推出。
  final double? sunAngularRadiusDeg;

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
  //
  // 半影半径 = **该墙点**沿光线到窗平面的距离 × tan(光源角半径)。
  // 角半径来自外部（[TraceInput.sunAngularRadiusDeg]，通常由 astro/大气模块
  // 给出）；若只有旧口径的 penumbra 比例，则按 pipeline `_penumbraFor` 的
  // 定义逆向换算，工作量级不变、距离依赖改为逐点正确。
  final visible = scene.windowVisibilityBatch(pts, sunDir,
      sunAngularRadiusDeg: input.sunAngularRadiusDeg ??
          _sunAngularRadiusFromLegacyPenumbra(input));

  final cam = scene.camPos;
  final albedo = mat.albedo;
  final normal = mat.normal;
  final roughness = mat.roughness;
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
    var r = 0.0, g = 0.0, b = 0.0;

    if (ndlV > 0) {
      // 视线方向：P → 相机
      var vx = cam[0] - px;
      final vy = cam[1] - py;
      var vz = cam[2];
      final vInv = 1.0 / math.max(math.sqrt(vx * vx + vy * vy + vz * vz), 1e-6);
      vx *= vInv;
      final vy2 = vy * vInv;
      final vz2 = vz * vInv;
      final ndv = math.max(nx * vx + ny * vy2 + nz * vz2, 0.0);

      // 漫反射：必须乘 (1 − F(ndv))。
      // 镜面反射走掉的那部分能量不再进入漫射通道，旧实现把整份入射能量
      // 同时给了漫射和镜面（两年前后都取 F0=0.04 却只在镜面里用），
      // 破坏了能量守恒；掠射（F→1）时最明显。
      final fres = _fresnelSchlick(ndv, _kF0);
      final kd = ndlV * beamScaleAll * (1.0 - fres);
      r = aR * sunR * kd;
      g = aG * sunG * kd;
      b = aB * sunB * kd;

      // 镜面（Cook-Torrance GGX + Smith + Schlick）
      var hx = vx + toSun[0];
      var hy = vy2 + toSun[1];
      var hz = vz2 + toSun[2];
      final hInv = 1.0 / math.max(math.sqrt(hx * hx + hy * hy + hz * hz), 1e-6);
      hx *= hInv;
      hy *= hInv;
      hz *= hInv;
      final ndh = math.max(nx * hx + ny * hy + nz * hz, 0.0);
      final specBrdf = _cookTorrance(ndl, ndv, ndh, roughness[i]);
      // 镜面强度不再乘一个 ±50% 的手调旋钮（1 + spec·0.5）：界面反射的
      // 强度由 Fresnel（F0 由折射率给出）决定，材质镜面贴图若将来引入，
      // 应直接调制 F0/粗糙度，而不是在 BRDF 之外乘一个亮度系数。
      const double specTex = 1.0;
      // 渲染方程里 BRDF 必须再乘 cos θ_i（= ndl）。旧实现漏了这一项，
      // 而 Cook-Torrance 的分母含 ndl，故掠射时高光会被放大成 1/ndl。
      final specK = specBrdf * specTex * vis * beamScaleAll * ndl;
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

/// 旧口径（半影半径 / 窗宽）→ 等效光源角半径（度）。
///
/// pipeline 旧公式为 `penumbra = D_代表·tan θ / 窗宽`，此处精确反解
/// `θ = atan(penumbra·窗宽 / D_代表)`；D_代表 = [Scene3D.typicalWindowToWallDistance]。
/// 这样旧调用方仍然按原意图决定**柔化量级**（含 penumbraScale 等微调），
/// 而"距离依赖"改由 scene3d 逐点计算。
///
/// 若 penumbra ≤ 0（旧"硬边"口径，物理上不存在：3 m 处日面半影宽 2.8 cm），
/// 返回 null → 由 scene3d 用几何日面角半径兜底。
double? _sunAngularRadiusFromLegacyPenumbra(TraceInput input) {
  if (input.penumbra <= 1e-6) return null;
  final dTyp = input.scene.typicalWindowToWallDistance();
  final wWin = math.max(input.scene.cfg.windowW, 1e-6);
  final tanTheta = input.penumbra * wWin / math.max(dTyp, 1e-6);
  return math.atan(tanTheta) / kDeg;
}

/// Cook-Torrance BRDF（D: GGX，G: Smith，F: Schlick）。
double _cookTorrance(double ndl, double ndv, double ndh, double roughness) {
  final a = math.pow(math.max(roughness, 0.03), 2).toDouble();
  final a2 = a * a;
  final denomH = ndh * ndh * (a2 - 1.0) + 1.0;
  final d = a2 / (math.pi * denomH * denomH + 1e-6);
  final k = a / 2.0;
  final g1l = ndl / (ndl * (1 - k) + k + 1e-6);
  final g1v = ndv / (ndv * (1 - k) + k + 1e-6);
  final g = g1l * g1v;
  final f = _fresnelSchlick(ndv, _kF0);
  final brdf = (d * g * f) / (4.0 * ndl * ndv + 1e-6);
  return brdf.clamp(0.0, 20.0);
}
