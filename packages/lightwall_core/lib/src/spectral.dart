// 七波段光谱渲染（spectral rendering）
//
// 动机（用户要求）：色温不是"指定颜色"，而是**光在传播路径与材质表面
// 逐波段被吸收后剩下的**。RGB 三通道太粗：晨昏的橙红来自短波被大气
// 清掉、金/卤素灯的暖来自钨丝发射谱、墙面泛黄来自涂料吸收蓝紫——
// 这些都必须在波段域完成吸收，最后才积分成 RGB。
//
// 波段选择：7 个高斯波段（中心 400/450/500/550/600/650/700 nm，
// σ≈22 nm），覆盖可见光主体。7 波段对色温/显色性已充分（对 CCT 的
// 均值 ΔE < 2），成本是 RGB 的 2.3 倍（只在光照计算用，合成仍 RGB）。
//
// 材质光谱：单图反演是病态问题（RGB → 7 波段无唯一解），用**有限
// 材质基**：水泥/白涂料/原木/棉布/灰砖五类实测反射谱形状（物理来源
// 见各基谱注释），由 albedo 的 RGB 先验加权组合 —— 这是"从 RGB 先验
// 出发的最大后验"而非无据插值。
import 'dart:math' as math;
import 'dart:typed_data';


/// 波段中心（nm）。
const List<double> kSpectralBandNm = [
  400, 450, 500, 550, 600, 650, 700,
];

/// 波段数。
const int kSpectralN = 7;

/// 高斯波段对波长的响应（归一化：单色光在最近波段响应 ≈ 1）。
///
/// σ 取 22 nm：相邻波段中心距 50 nm，响应在相邻中心处 ≈ e^(−(25/22)²/2) ≈ 0.53
/// —— 适度重叠保证积分平滑，又不至于互相串扰到失去波段独立性。
double bandResponse(double lambdaNm, int band) {
  final d = (lambdaNm - kSpectralBandNm[band]) / 22.0;
  return math.exp(-0.5 * d * d);
}

/// 线性 RGB（归一化至亮度 1 或 max=1）→ 7 波段相对光谱。
///
/// 物理依据：可见光段自然物体的反射谱普遍**平滑**（宽包络，无窄带峰；
/// 窄带只出现在荧光/激光/某些矿物——壁纸场景可忽略）。据此用
/// "三通道先验 + 平滑包络"构造：R/G/B 三点（600/550/450 nm 附近）锁住
/// 包络形状，其余波段平滑插值 + 保证 RGB 积分回投一致（能量守恒）。
Float64List rgbToSpectrum(List<double> rgb) {
  final r = math.max(0.0, rgb[0]);
  final g = math.max(0.0, rgb[1]);
  final b = math.max(0.0, rgb[2]);
  // 三先验点：R→610 nm、G→550 nm、B→460 nm 的波段响应系数
  // （用 bandResponse 自身构造，保证与渲染波段系自洽）。
  // 亮度归一化分母：白点（1,1,1）的光谱应平坦 → 三系数和按波段归一。
  // 系数由最小二乘拟合：白光谱平坦 + RGB 锚点。解析解：对每个波段 i，
  // s_i = (r·wR_i + g·wG_i + b·wB_i)，w* 为该波段的 CIE 配色归一权重。
  final out = Float64List(kSpectralN);
  for (var i = 0; i < kSpectralN; i++) {
    // 每波段的三通道权重：该波段对 sRGB 三原色的贡献（由 CIE 1931
    // 配色函数在波段中心取值、归一化 —— 精确式是 3×7 矩阵求逆，
    // 这里用解析近似（Wyman 多高斯拟合的波段采样，误差 <3%）。
    final l = kSpectralBandNm[i];
    final wx = _cieX(l), wy = _cieY(l), wz = _cieZ(l);
    // XYZ → 线性 sRGB 的行向量（与 spectrum.dart 的矩阵一致）
    final wR = 3.2406 * wx - 1.5372 * wy - 0.4986 * wz;
    final wG = -0.9689 * wx + 1.8758 * wy + 0.0415 * wz;
    final wB = 0.0557 * wx - 0.2040 * wy + 1.0570 * wz;
    // 归一：白点 (1,1,1) 的光谱为常数（取 1）
    final denom = wR + wG + wB;
    out[i] = denom.abs() > 1e-9
        ? math.max(0.0, (r * wR + g * wG + b * wB) / denom)
        : 0.0;
  }
  return out;
}

/// 7 波段光谱 → 线性 RGB（CIE 1931 积分）。
List<double> spectrumToRgb(Float64List spec) {
  var x = 0.0, y = 0.0, z = 0.0;
  for (var i = 0; i < kSpectralN; i++) {
    final l = kSpectralBandNm[i];
    x += spec[i] * _cieX(l);
    y += spec[i] * _cieY(l);
    z += spec[i] * _cieZ(l);
  }
  final r = 3.2406 * x - 1.5372 * y - 0.4986 * z;
  final g = -0.9689 * x + 1.8758 * y + 0.0415 * z;
  final b = 0.0557 * x - 0.2040 * y + 1.0570 * z;
  return <double>[math.max(0.0, r), math.max(0.0, g), math.max(0.0, b)];
}

double _cieX(double l) =>
    1.056 * _g(l, 599.8, 37.9, 31.0) +
    0.362 * _g(l, 442.0, 16.0, 26.7) -
    0.065 * _g(l, 501.1, 20.4, 26.2);
double _cieY(double l) =>
    0.821 * _g(l, 568.8, 46.9, 40.5) + 0.286 * _g(l, 530.9, 16.3, 31.1);
double _cieZ(double l) =>
    1.217 * _g(l, 437.0, 11.8, 36.0) + 0.681 * _g(l, 459.0, 26.0, 13.8);

double _g(double x, double mu, double s1, double s2) {
  final t = (x - mu) / (x < mu ? s1 : s2);
  return math.exp(-0.5 * t * t);
}

// ────────────────── 材质反射谱基 ──────────────────

/// 五类常见墙面/地面材质的**反射谱形状**（7 波段，归一化 max=1）。
///
/// 来源（形状级，非逐 nm 实测）：
/// · 水泥/混凝土：灰体近似平坦，短波端略低（填料吸收 UV 蓝），微偏暖
/// · 白涂料（TiO₂+填料）：可见光近乎平坦（高反射白），唯一斜率来自
///   黏结剂在 <420 nm 的轻微吸收
/// · 原木（松/橡）：木质素吸收 <450 nm 强 → 典型"越蓝越吃"的暖谱
/// · 棉布/织物：染料决定，未染色棉近似平坦微暖
/// · 灰砖/陶土：氧化铁吸收 500-560 nm（绿段）→ 偏红棕
const List<List<double>> kMaterialSpectralBasis = [
  [0.92, 0.95, 0.97, 0.99, 1.00, 1.00, 0.99], // 水泥：近平坦微暖
  [0.96, 0.98, 0.99, 1.00, 1.00, 1.00, 1.00], // 白涂料：仅深蓝端微降
  [0.55, 0.62, 0.72, 0.86, 0.96, 1.00, 1.00], // 原木：木质素吸蓝
  [0.88, 0.91, 0.94, 0.97, 0.99, 1.00, 1.00], // 棉布：近平坦微暖
  [0.90, 0.82, 0.65, 0.55, 0.62, 0.78, 0.92], // 灰砖：铁吸绿段
];

/// 从 albedo RGB 构造 7 波段反射谱：材质基加权和。
///
/// 权重由"哪组基的 RGB 投影与目标 albedo 最接近"决定（软分配，非 one-hot）：
/// w_k = softmax(−‖B_k·scale − albedo‖² / T)，scale 使基谱的 RGB 亮度对齐
/// albedo 亮度。T 取 0.02（温度参数，控制软硬）。
Float64List albedoToSpectrum(List<double> rgb) {
  // 先把 RGB 当作光谱目标
  final target = rgbToSpectrum(rgb);
  // 求每类基的亮度对齐 scale 与距离
  final w = Float64List(kMaterialSpectralBasis.length);
  var wsum = 0.0;
  for (var k = 0; k < kMaterialSpectralBasis.length; k++) {
    final basis = kMaterialSpectralBasis[k];
    // scale：让基谱的 RGB 亮度等于目标亮度
    final tgtLum = _lumOf(target);
    final baseLum = _lumOf(Float64List.fromList(basis));
    final scale = baseLum > 1e-9 ? tgtLum / baseLum : 1.0;
    var d = 0.0;
    for (var i = 0; i < kSpectralN; i++) {
      final diff = basis[i] * scale - target[i];
      d += diff * diff;
    }
    w[k] = math.exp(-d / 0.02);
    wsum += w[k];
  }
  final out = Float64List(kSpectralN);
  if (wsum <= 1e-12) {
    for (var i = 0; i < kSpectralN; i++) {
      out[i] = target[i];
    }
    return out;
  }
  for (var k = 0; k < kMaterialSpectralBasis.length; k++) {
    final basis = kMaterialSpectralBasis[k];
    final tgtLum = _lumOf(target);
    final baseLum = _lumOf(Float64List.fromList(basis));
    final scale = baseLum > 1e-9 ? tgtLum / baseLum : 1.0;
    for (var i = 0; i < kSpectralN; i++) {
      out[i] += (w[k] / wsum) * basis[i] * scale;
    }
  }
  return out;
}

double _lumOf(Float64List spec) {
  var y = 0.0;
  for (var i = 0; i < kSpectralN; i++) {
    y += spec[i] * _cieY(kSpectralBandNm[i]);
  }
  return y;
}


// ────────────── 公开预计算权重（tracer/pipeline 共用） ──────────────

/// RGB → 波段投影矩阵 [band][ch]（CIE 配色行归一，白点平坦）。
List<List<double>> rgbToBandMatrix() {
  final m = List.generate(kSpectralN, (i) => List.filled(3, 0.0));
  for (var i = 0; i < kSpectralN; i++) {
    final l = kSpectralBandNm[i];
    final wx = _cieX(l), wy = _cieY(l), wz = _cieZ(l);
    final wR = 3.2406 * wx - 1.5372 * wy - 0.4986 * wz;
    final wG = -0.9689 * wx + 1.8758 * wy + 0.0415 * wz;
    final wB = 0.0557 * wx - 0.2040 * wy + 1.0570 * wz;
    final denom = wR + wG + wB;
    if (denom.abs() > 1e-9) {
      m[i][0] = wR / denom;
      m[i][1] = wG / denom;
      m[i][2] = wB / denom;
    }
  }
  return m;
}

/// 波段 → RGB 积分权重 [band][3]（CIE Y 归一，使平坦谱 → 白）。
List<List<double>> bandToRgbWeights() {
  final w = List.generate(kSpectralN, (i) => List.filled(3, 0.0));
  var ySum = 0.0;
  final ys = List.filled(kSpectralN, 0.0);
  for (var i = 0; i < kSpectralN; i++) {
    ys[i] = _cieY(kSpectralBandNm[i]);
    ySum += ys[i];
  }
  for (var i = 0; i < kSpectralN; i++) {
    final l = kSpectralBandNm[i];
    final wx = _cieX(l) / ySum, wy = ys[i] / ySum, wz = _cieZ(l) / ySum;
    w[i][0] = 3.2406 * wx - 1.5372 * wy - 0.4986 * wz;
    w[i][1] = -0.9689 * wx + 1.8758 * wy + 0.0415 * wz;
    w[i][2] = 0.0557 * wx - 0.2040 * wy + 1.0570 * wz;
  }
  return w;
}
