// 数值与图像基础工具（纯 Dart，无外部依赖）
//
// 提供：标量工具、确定性噪声、可分离模糊、双线性缩放、中值滤波、
// 数组位移等 —— 渲染管线全部建立在 Float32List 之上。
import 'dart:math' as math;
import 'dart:typed_data';

/// 将 [v] 限制在 [lo, hi] 区间。
double clampd(double v, [double lo = 0.0, double hi = 1.0]) =>
    v < lo ? lo : (v > hi ? hi : v);

/// 线性插值。
double lerp(double a, double b, double t) => a + (b - a) * t;

/// 平滑阶跃。
double smoothstepd(double e0, double e1, double x) {
  final t = clampd((x - e0) / (e1 - e0 == 0 ? 1e-9 : e1 - e0));
  return t * t * (3 - 2 * t);
}

// ───────────────────────────── 噪声 ─────────────────────────────

/// 确定性哈希（整数 → [0,1)）。
double hashNoise(int x, int y, int seed) {
  var h = x * 374761393 + y * 668265263 + seed * 1442695040888963407;
  h = (h ^ (h >> 13)) * 1274126177;
  h = h ^ (h >> 16);
  return (h & 0x7fffffff) / 0x7fffffff;
}

/// 二维值噪声（双线性插值 + 平滑）。
double valueNoise(double x, double y, int seed) {
  final xi = x.floor();
  final yi = y.floor();
  final xf = x - xi;
  final yf = y - yi;
  final u = xf * xf * (3 - 2 * xf);
  final v = yf * yf * (3 - 2 * yf);
  final a = hashNoise(xi, yi, seed);
  final b = hashNoise(xi + 1, yi, seed);
  final c = hashNoise(xi, yi + 1, seed);
  final d = hashNoise(xi + 1, yi + 1, seed);
  return lerp(lerp(a, b, u), lerp(c, d, u), v);
}

/// 分形叠加噪声（多倍频）。
double fbm(double x, double y, int seed, {int octaves = 4, double lac = 2.0, double gain = 0.5}) {
  var amp = 1.0;
  var freq = 1.0;
  var sum = 0.0;
  var norm = 0.0;
  for (var i = 0; i < octaves; i++) {
    sum += amp * valueNoise(x * freq, y * freq, seed + i * 977);
    norm += amp;
    amp *= gain;
    freq *= lac;
  }
  return norm > 0 ? sum / norm : 0.0;
}

/// 伪随机数发生器（xorshift，确定性）。
class Rng {
  Rng(int seed) : _s = (seed == 0 ? 0x9e3779b9 : seed) & 0xffffffff;

  int _s;

  int nextInt() {
    var x = _s;
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    _s = x & 0xffffffff;
    return _s;
  }

  /// [0,1) 均匀分布。
  double nextDouble() => nextInt() / 4294967296.0;

  /// [min,max) 均匀分布。
  double range(double min, double max) => min + nextDouble() * (max - min);
}

// ───────────────────────────── 模糊 ─────────────────────────────

/// 一维水平盒式模糊（就地写入 [dst]）。
void _boxBlurH(Float32List src, Float32List dst, int w, int h, int r) {
  final norm = 1.0 / (2 * r + 1);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var acc = 0.0;
    for (var i = -r; i <= r; i++) {
      acc += src[row + i.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      dst[row + x] = acc * norm;
      final outIdx = (x - r).clamp(0, w - 1);
      final inIdx = (x + r + 1).clamp(0, w - 1);
      acc += src[row + inIdx] - src[row + outIdx];
    }
  }
}

/// 一维垂直盒式模糊。
void _boxBlurV(Float32List src, Float32List dst, int w, int h, int r) {
  final norm = 1.0 / (2 * r + 1);
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    for (var i = -r; i <= r; i++) {
      acc += src[i.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      dst[y * w + x] = acc * norm;
      final outIdx = (y - r).clamp(0, h - 1);
      final inIdx = (y + r + 1).clamp(0, h - 1);
      acc += src[inIdx * w + x] - src[outIdx * w + x];
    }
  }
}

/// 单通道高斯近似模糊（3 次盒式模糊）。返回新数组。
Float32List blurGray(Float32List src, int w, int h, double radius) {
  if (radius < 0.5) return Float32List.fromList(src);
  // 由高斯半径推出盒式半径（标准近似）
  final r = math.max(1, (radius * 0.9).round());
  var a = Float32List.fromList(src);
  var b = Float32List(w * h);
  for (var pass = 0; pass < 2; pass++) {
    _boxBlurH(a, b, w, h, r);
    _boxBlurV(b, a, w, h, r);
  }
  return a;
}

/// 中值滤波（[k] 为奇数窗口尺寸，支持 3/5/7）。
Float32List medianGray(Float32List src, int w, int h, int k) {
  final out = Float32List(w * h);
  final half = k ~/ 2;
  final buf = Float64List(k * k);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var n = 0;
      for (var dy = -half; dy <= half; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -half; dx <= half; dx++) {
          final xx = (x + dx).clamp(0, w - 1);
          buf[n++] = src[yy * w + xx];
        }
      }
      // 选择中位数（局部排序，n 很小）
      final arr = buf.sublist(0, n)..sort();
      out[y * w + x] = arr[n ~/ 2];
    }
  }
  return out;
}

/// 最小值滤波（形态学腐蚀）。
Float32List minFilterGray(Float32List src, int w, int h, int k) {
  final out = Float32List(w * h);
  final half = k ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = double.infinity;
      for (var dy = -half; dy <= half; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -half; dx <= half; dx++) {
          final xx = (x + dx).clamp(0, w - 1);
          final v = src[yy * w + xx];
          if (v < m) m = v;
        }
      }
      out[y * w + x] = m;
    }
  }
  return out;
}

/// 最大值滤波（形态学膨胀）。
Float32List maxFilterGray(Float32List src, int w, int h, int k) {
  final out = Float32List(w * h);
  final half = k ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = -double.infinity;
      for (var dy = -half; dy <= half; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -half; dx <= half; dx++) {
          final xx = (x + dx).clamp(0, w - 1);
          final v = src[yy * w + xx];
          if (v > m) m = v;
        }
      }
      out[y * w + x] = m;
    }
  }
  return out;
}

/// 数组平移（屏幕空间偏移），越界以 0 填充。
Float32List shiftGray(Float32List src, int w, int h, int dx, int dy) {
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final sy = y - dy;
    if (sy < 0 || sy >= h) continue;
    for (var x = 0; x < w; x++) {
      final sx = x - dx;
      if (sx < 0 || sx >= w) continue;
      out[y * w + x] = src[sy * w + sx];
    }
  }
  return out;
}

/// Sobel 梯度（返回 gx、gy，已按 1/4 归一）。
void sobelGray(Float32List src, int w, int h, Float32List gx, Float32List gy) {
  for (var y = 0; y < h; y++) {
    final y0 = (y - 1).clamp(0, h - 1) * w;
    final y1 = y * w;
    final y2 = (y + 1).clamp(0, h - 1) * w;
    for (var x = 0; x < w; x++) {
      final x0 = (x - 1).clamp(0, w - 1);
      final x2 = (x + 1).clamp(0, w - 1);
      final a = src[y0 + x0], b = src[y0 + x], c = src[y0 + x2];
      final d = src[y1 + x0], f = src[y1 + x2];
      final g = src[y2 + x0], hh = src[y2 + x], i = src[y2 + x2];
      gx[y1 + x] = ((c + 2 * f + i) - (a + 2 * d + g)) / 4.0;
      gy[y1 + x] = ((g + 2 * hh + i) - (a + 2 * b + c)) / 4.0;
    }
  }
}

// ───────────────────────────── 缩放 ─────────────────────────────

/// 单通道双线性缩放。
Float32List resizeGray(Float32List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh);
  if (sw == dw && sh == dh) return Float32List.fromList(src);
  final sx = sw / dw;
  final sy = sh / dh;
  for (var y = 0; y < dh; y++) {
    final fy = (y + 0.5) * sy - 0.5;
    var y0 = fy.floor();
    final wy = fy - y0;
    final y1 = (y0 + 1).clamp(0, sh - 1);
    if (y0 < 0) y0 = 0;
    for (var x = 0; x < dw; x++) {
      final fx = (x + 0.5) * sx - 0.5;
      var x0 = fx.floor();
      final wx = fx - x0;
      final x1 = (x0 + 1).clamp(0, sw - 1);
      if (x0 < 0) x0 = 0;
      final a = src[y0 * sw + x0];
      final b = src[y0 * sw + x1];
      final c = src[y1 * sw + x0];
      final d = src[y1 * sw + x1];
      out[y * dw + x] = lerp(lerp(a, b, wx), lerp(c, d, wx), wy);
    }
  }
  return out;
}

/// 三通道（交错）双线性缩放。
Float32List resizeRgb(Float32List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh * 3);
  if (sw == dw && sh == dh) return Float32List.fromList(src);
  final sx = sw / dw;
  final sy = sh / dh;
  for (var y = 0; y < dh; y++) {
    final fy = (y + 0.5) * sy - 0.5;
    var y0 = fy.floor();
    final wy = fy - y0;
    final y1 = (y0 + 1).clamp(0, sh - 1);
    if (y0 < 0) y0 = 0;
    for (var x = 0; x < dw; x++) {
      final fx = (x + 0.5) * sx - 0.5;
      var x0 = fx.floor();
      final wx = fx - x0;
      final x1 = (x0 + 1).clamp(0, sw - 1);
      if (x0 < 0) x0 = 0;
      for (var c = 0; c < 3; c++) {
        final a = src[(y0 * sw + x0) * 3 + c];
        final b = src[(y0 * sw + x1) * 3 + c];
        final cc = src[(y1 * sw + x0) * 3 + c];
        final d = src[(y1 * sw + x1) * 3 + c];
        out[(y * dw + x) * 3 + c] = lerp(lerp(a, b, wx), lerp(cc, d, wx), wy);
      }
    }
  }
  return out;
}

// ─────────────────────────── 色彩空间 ───────────────────────────

/// 线性光 → sRGB 传输函数。
double linearToSrgb(double c) {
  final v = c < 0 ? 0.0 : c;
  return v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4).toDouble() - 0.055;
}

/// sRGB → 线性光。
double srgbToLinear(double c) {
  final v = c < 0 ? 0.0 : (c > 1 ? 1.0 : c);
  return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

/// 构建 sRGB→线性 查找表（256 项）。
Float32List buildSrgbToLinearLut() {
  final lut = Float32List(256);
  for (var i = 0; i < 256; i++) {
    lut[i] = srgbToLinear(i / 255.0);
  }
  return lut;
}

/// ACES 近似色调映射（Narkowicz 拟合）。
double acesToneMap(double x) {
  const a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  final v = x < 0 ? 0.0 : x;
  return clampd((v * (a * v + b)) / (v * (c * v + d) + e));
}
