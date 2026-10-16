// 天空亮度分布：CIE 标准晴空（ISO 15469 / CIE S 011）
//
// 为什么必须做方向性：环境光若只是一个"随太阳高度变化的标量色"，
// 那么站在房间里任何一个位置看到的天空都一样亮 —— 结果就是环境场
// 完全平坦，光斑之外只剩一层没有方向的灰，直射与环境像两个图层硬叠。
//
// 真实晴空的亮度分布极不均匀（Perez 1993 全天空模型）：
//   · 太阳附近（γ→0）最亮 —— 前向散射 + 多次散射
//   · 天顶次亮
//   · 太阳对面地平线最暗
// 本产品只做晴天，因此只需 CIE 标准晴空那一张系数表，无需全部分档。
//
// 分布形式（Perez 三参数形式，晴空 b≡0）：
//   L(θ,γ) = L_z · (1 + a·e^{b/cosθ}) · (1 + c·e^{dγ} + e·cos²γ)
//            ─────────────────────────────────────────────────────
//            (1 + a·e^{b}) · (1 + c·e^{dπ/2} + e·cos²(π/2))
// 其中 θ = 天顶角，γ = 与太阳的夹角（弧度）。
import 'dart:math' as math;

/// CIE 标准晴空系数（按太阳天顶角分档）。
/// 每档 5 个系数：a, b, c, d, e（b 对晴空恒为 0，保留以显式对应标准表）。
const List<({double zMin, double a, double b, double c, double d, double e})>
    kClearSkyCoeffs =
    <({double zMin, double a, double b, double c, double d, double e})>[
  (zMin: 0, a: -0.070, b: 0.000, c: 0.071, d: -0.017, e: 0.230),
  (zMin: 15, a: -0.100, b: 0.000, c: 0.086, d: -0.019, e: 0.240),
  (zMin: 30, a: -0.177, b: 0.000, c: 0.114, d: -0.028, e: 0.250),
  (zMin: 45, a: -0.288, b: 0.000, c: 0.153, d: -0.040, e: 0.280),
  (zMin: 60, a: -0.488, b: 0.000, c: 0.216, d: -0.062, e: 0.320),
  (zMin: 75, a: -0.843, b: 0.000, c: 0.361, d: -0.110, e: 0.400),
];

({double a, double b, double c, double d, double e}) clearSkyCoeffs(
    double sunZenithDeg) {
  final z = sunZenithDeg.clamp(0.0, 90.0);
  var sel = kClearSkyCoeffs.first;
  for (final row in kClearSkyCoeffs) {
    if (z >= row.zMin) sel = row;
  }
  return (a: sel.a, b: sel.b, c: sel.c, d: sel.d, e: sel.e);
}

/// 相对天顶亮度的**天空分布因子**（无量纲，天顶方向 = 1）。
///
/// [zenithRad]：该方向的天顶角（0 = 天顶，π/2 = 地平线）
/// [gammaRad] ：该方向与太阳的夹角
/// [sunZenithDeg]：太阳天顶角（决定系数档位）
/// [sunAltDeg]：太阳高度角（用于太阳落入地平线时的退化处理）
double skyLuminanceFactor(
    double zenithRad, double gammaRad, double sunZenithDeg, double sunAltDeg) {
  if (sunAltDeg <= 0.0) {
    // 无太阳：退化为均匀阴天分布（地平线略亮，符合真实无阳天空）
    return 0.75 + 0.25 * math.sin(zenithRad);
  }
  final co = clearSkyCoeffs(sunZenithDeg);
  // 分母：θ=0（天顶）、γ=π/2 时的归一化值
  final denom = (1.0 + co.a * math.exp(co.b)) *
      (1.0 + co.c * math.exp(co.d * math.pi / 2) + co.e * 0.0);
  final cosZ = math.cos(zenithRad);
  // 天顶角趋近 90° 时 1/cosθ 发散，按标准做法限幅（地平线附近饱和度）
  final secZ = 1.0 / math.max(cosZ, 0.01745); // 下限 ≈ cos(89°)
  final num = (1.0 + co.a * math.exp(co.b * secZ)) *
      (1.0 +
          co.c * math.exp(co.d * gammaRad) +
          co.e * math.cos(gammaRad) * math.cos(gammaRad));
  return num / denom;
}
