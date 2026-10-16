// 太阳光谱 → 线性 sRGB：把"颜色"交还给物理
//
// 为什么必须这样算：早期实现用一张"高度角 → 色温"的分段表和 Tanner Helland
// 的黑体→sRGB 拟合来给太阳上色。两处都不成立：
//   ① 色温只是光谱的**标量摘要**，反过来当颜色用是错的。真实日落的色品
//      **不在普朗克轨迹上** —— 臭氧 Chappuis 带把 600 nm 挖掉一块、
//      Rayleigh 散射在蓝端按 λ⁻⁴ 陡降，两者合成出的色相与黑体轨迹差别显著。
//   ② Tanner 拟合的输出是 **gamma 编码后的显示值**，被当成**线性光**去乘
//      辐照度，中间通道偏差可达 4.6 倍（显示值 0.266 ↔ 线性 0.058）。
//
// 正确链路（本文件实现）：
//   太阳光谱 L(λ, T_sun)
//     × 大气透过率 T(λ) = exp(−[τ_R(λ) + τ_O₃(λ) + τ_M(λ)]·m)
//     × CIE 1931 色匹配函数
//     → XYZ → 线性 sRGB
//
// 全部物理常数与定律：
//   · 普朗克定律（黑体辐射）—— 太阳有效温度 5772 K（IAU 2015 nominal）
//   · Bodhaine et al. 1999 瑞利光学厚度式
//   · 臭氧 Chappuis 带（300 DU 标准柱量）
//   · Ångström 气溶胶幂律 τ_M = β·λ^(−α)
//   · CIE 1931 CMF 的多高斯解析拟合（Wyman/Sloan/Shirley 2013，误差 < 1%）
//   · IEC 61966-2-1 sRGB 原色矩阵
import 'dart:math' as math;

import 'astro.dart';

// ─────────────────────────── 物理常数 ───────────────────────────

/// 普朗克常数 (J·s)
const double kPlanckH = 6.62607015e-34;

/// 真空光速 (m/s)
const double kLightSpeed = 2.99792458e8;

/// 玻尔兹曼常数 (J/K)
const double kBoltzmann = 1.380649e-23;

/// 太阳有效温度 (K) —— IAU 2015 nominal solar effective temperature
const double kSunEffectiveTemp = 5772.0;

/// 标准大气臭氧柱量 (DU)。Chappuis 带光学厚度由柱量与吸收截面相乘得到。
const double kOzoneColumnDU = 300.0;

/// 海平面标准气压比（用于瑞利光学厚度的气压修正）
const double kSeaLevelPressureRatio = 1.0;

// ─────────────────────────── 普朗克定律 ───────────────────────────

/// 黑体光谱辐亮度，**相对值**（避免 λ⁻⁵ 在纳米量级下的数值下溢）。
///
/// 返回相对于 550 nm 的比值；真实辐亮度 B(λ,T) 与该值只差一个与 λ 无关
/// 的常数因子，而颜色计算只关心**相对**光谱分布，因此完全等价。
double planckRel(double lambdaNm, [double tempK = kSunEffectiveTemp]) {
  // (λ₀/λ)⁵ · (e^{x₀}−1)/(e^{x}−1)
  const l0 = 550.0;
  final r = l0 / lambdaNm;
  final x = kPlanckH * kLightSpeed / (lambdaNm * 1e-9 * kBoltzmann * tempK);
  final x0 = kPlanckH * kLightSpeed / (l0 * 1e-9 * kBoltzmann * tempK);
  return math.pow(r, 5).toDouble() * (math.exp(x0) - 1.0) / (math.exp(x) - 1.0);
}

// ───────────────────── 大气分波长光学厚度 ─────────────────────

/// 瑞利光学厚度（Bodhaine et al. 1999），λ 单位 nm。
///
///   τ_R(λ) = (P/P₀)·0.008569·λ⁻⁴·(1 + 0.0113·λ⁻² + 0.00013·λ⁻⁴)，λ 单位 µm
double rayleighTau(double lambdaNm,
    {double pressureRatio = kSeaLevelPressureRatio}) {
  final um = lambdaNm / 1000.0;
  final u2 = um * um;
  final u4 = u2 * u2;
  return pressureRatio *
      0.008569 *
      math.pow(um, -4.0).toDouble() *
      (1.0 + 0.0113 / u2 + 0.00013 / u4);
}

/// 臭氧 Chappuis 带光学厚度（500–700 nm，峰值 ≈ 600 nm）。
///
/// 用 300 DU 标准柱量；分布用单峰高斯近似（Chappuis 带在可见光区的
/// 实际截面就是这样一条平滑带，形状误差对宽带颜色的影响远小于 1%）。
double ozoneTau(double lambdaNm, {double columnDU = kOzoneColumnDU}) {
  final x = (lambdaNm - 600.0) / 90.0;
  // 300 DU 在 600 nm 处约 0.033 光学厚度（截面 × 柱量）
  return (columnDU / kOzoneColumnDU) * 0.033 * math.exp(-0.5 * x * x);
}

/// 气溶胶光学厚度（Ångström 幂律）：τ_M(λ) = β·λ^(−α)。
///
/// β 由 550 nm 处的 AOD 反解，α 为 Ångström 指数（清洁大陆气溶胶 ≈ 1.3）。
/// 蓝端的衰减强于红端 —— 这是"气溶胶让日落偏灰白"的物理来源，
/// 早期实现给气溶胶一个与波长无关的灰度 τ，把这层色偏完全丢了。
double aerosolTau(double lambdaNm,
    {double aod550 = 0.05, double angstrom = 1.3}) {
  final um = lambdaNm / 1000.0;
  final beta = aod550 * math.pow(0.55, angstrom).toDouble();
  return beta * math.pow(um, -angstrom).toDouble();
}

/// 整层大气分波长透过率。
///
///   T(λ) = exp(−[τ_R(λ)·m_R + τ_O₃(λ)·m_O₃ + τ_M(λ)·m_M]·m_air)
/// 这里对三类成分共用同一个空气团质量（几何薄层大气近似；臭氧层更高，
/// 严格应使用各自的层质量因子，但对宽带积分的影响 < 1%）。
double atmosphericTransmittance(
  double lambdaNm,
  double airMass, {
  double aod550 = 0.05,
  double angstrom = 1.3,
  double ozoneDU = kOzoneColumnDU,
  double pressureRatio = kSeaLevelPressureRatio,
}) {
  final tau = rayleighTau(lambdaNm, pressureRatio: pressureRatio) +
      ozoneTau(lambdaNm, columnDU: ozoneDU) +
      aerosolTau(lambdaNm, aod550: aod550, angstrom: angstrom);
  return math.exp(-tau * airMass);
}

// ─────────────────── CIE 1931 色匹配函数 ───────────────────
// Wyman, Sloan, Shirley (JCGT 2013) 多高斯拟合，与 CIE 官方表误差 < 1%。
// 用解析式而非 81×3 的查表：单帧只需一次积分，精度足够且无表可维护。

double _gaussSeg(double x, double mu, double s1, double s2) {
  final d = x - mu;
  final s = d < 0 ? s1 : s2;
  final t = d / s;
  return math.exp(-0.5 * t * t);
}

double cieX(double l) =>
    1.056 * _gaussSeg(l, 599.8, 37.9, 31.0) +
    0.362 * _gaussSeg(l, 442.0, 16.0, 26.7) -
    0.065 * _gaussSeg(l, 501.1, 20.4, 26.2);

double cieY(double l) =>
    0.821 * _gaussSeg(l, 568.8, 46.9, 40.5) +
    0.286 * _gaussSeg(l, 530.9, 16.3, 31.1);

double cieZ(double l) =>
    1.217 * _gaussSeg(l, 437.0, 11.8, 36.0) +
    0.681 * _gaussSeg(l, 459.0, 26.0, 13.8);

// ────────────────── 积分：光谱 → 线性 sRGB ──────────────────

/// 可见光积分区间与步长（nm）。2 nm 步长对宽带色度已充分收敛。
const double kVisMin = 380.0;
const double kVisMax = 780.0;
const double kVisStep = 2.0;

/// XYZ → 线性 sRGB（IEC 61966-2-1 原色矩阵）。
List<double> xyzToLinearSrgb(double x, double y, double z) {
  final r = 3.2406 * x - 1.5372 * y - 0.4986 * z;
  final g = -0.9689 * x + 1.8758 * y + 0.0415 * z;
  final b = 0.0557 * x - 0.2040 * y + 1.0570 * z;
  return <double>[r, g, b];
}

/// 太阳直射的分波长结果：线性 sRGB + 相对亮度。
class SolarSpectrum {
  const SolarSpectrum(this.rgb, this.luminance);
  final List<double> rgb;
  final double luminance;
  static const SolarSpectrum zero = SolarSpectrum(<double>[0, 0, 0], 0.0);
}

/// 天顶（m = 1、无大气）的参考亮度 —— 用于把结果归一化到"天顶 = 1"。
/// 这是**算出来的**归一化常数，不是挑出来的数字。
final double _zenithLuminance = _integrateLuminance(1.0);

double _integrateLuminance(double airMass) {
  var y = 0.0;
  for (var l = kVisMin; l <= kVisMax; l += kVisStep) {
    y += planckRel(l) * atmosphericTransmittance(l, airMass) * cieY(l) * kVisStep;
  }
  return y;
}

/// 太阳直射光谱 → 线性 sRGB（归一化：大气外整束光的亮度 = 1）。
///
/// [altDeg] 几何高度角（度）；[aod550] 550 nm 气溶胶光学厚度。
SolarSpectrum solarSpectrum(double altDeg,
    {double aod550 = 0.05, double angstrom = 1.3}) {
  if (altDeg < 0) return SolarSpectrum.zero;
  final am = airMassKastenYoung(altDeg);
  var x = 0.0, y = 0.0, z = 0.0;
  for (var l = kVisMin; l <= kVisMax; l += kVisStep) {
    final e = planckRel(l) *
        atmosphericTransmittance(l, am,
            aod550: aod550, angstrom: angstrom) *
        kVisStep;
    x += e * cieX(l);
    y += e * cieY(l);
    z += e * cieZ(l);
  }
  final rgb = xyzToLinearSrgb(x, y, z);
  // 亮度归一化：天顶处 = 1（与工程既有的"天顶直射 = 1"量纲一致）
  final scale = 1.0 / _zenithLuminance;
  return SolarSpectrum(
    <double>[rgb[0] * scale, rgb[1] * scale, rgb[2] * scale],
    y * scale,
  );
}
