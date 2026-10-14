// 文字叠字：年代感 · 接触阴影 · 乘性反射合成
//
// 合成模型是**乘性反射**，不是简单覆盖（这一点决定了"字是颜料不是贴纸"）：
//     L_out = L_wall · (1 − occ·s) · [(1−α) + α·ρ]
// 其中 α = 文字不透明度，ρ = 朱砂反射率，occ = 接触阴影。
//
// 因此字在暗处会跟着变暗，且在光斑扫过时"活"起来 —— 这是与普通贴图
// 叠字最本质的区别。
import 'dart:math' as math;
import 'dart:typed_data';

import 'compose.dart';
import 'mathx.dart';

/// 朱砂（朱红）颜料反射率（线性 RGB）。
const List<double> kCinnabar = <double>[0.52, 0.055, 0.048];

/// 年代感参数。
class AgedParams {
  const AgedParams({
    this.noiseLow = 0.12,
    this.noiseMid = 0.10,
    this.noiseHigh = 0.06,
    this.diffusion = 0.20,
    this.oxidation = 0.30,
    this.edgeErode = true,
  });

  /// 低频噪声振幅（大块斑驳）
  final double noiseLow;

  /// 中频噪声振幅
  final double noiseMid;

  /// 高频噪声振幅（边缘毛糙）
  final double noiseHigh;

  /// 颜料扩散强度
  final double diffusion;

  /// 氧化颗粒强度
  final double oxidation;

  /// 是否做边缘侵蚀
  final bool edgeErode;

  static const AgedParams clean = AgedParams(
    noiseLow: 0.05,
    noiseMid: 0.04,
    noiseHigh: 0.02,
    diffusion: 0.10,
    oxidation: 0.0,
  );

  static const AgedParams aged = AgedParams(
    noiseLow: 0.30,
    noiseMid: 0.20,
    noiseHigh: 0.12,
    diffusion: 0.40,
    oxidation: 0.5,
  );
}

// 噪声空间尺度（占画幅比例）
const double _lowScale = 0.060;
const double _midScale = 0.015;
const double _highScale = 0.004;

/// 生成带年代感的 alpha（0~1）。
///
/// [alpha] 为原始字形 alpha（w*h），[matVar] 为材质起伏图（可选）。
Float32List generateAgedAlpha(
  Float32List alpha,
  int w,
  int h, {
  int seed = 12345,
  AgedParams params = const AgedParams(),
  Float32List? matVar,
  double materialStrength = 0.0,
}) {
  final n = w * h;
  final a = Float32List(n);

  // 三层噪声（低频 → 高频）
  final nl = Float32List(n);
  final nm = Float32List(n);
  final nh = Float32List(n);
  final lowPx = math.max(2.0, 1.0 / _lowScale);
  final midPx = math.max(2.0, 1.0 / _midScale);
  final highPx = math.max(2.0, 1.0 / _highScale);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      nl[i] = fbm(x / lowPx, y / lowPx, seed, octaves: 3);
      nm[i] = fbm(x / midPx, y / midPx, seed + 101, octaves: 3);
      nh[i] = fbm(x / highPx, y / highPx, seed + 202, octaves: 2);
    }
  }

  // 噪声调制
  for (var i = 0; i < n; i++) {
    var v = alpha[i] * (1.0 - params.noiseLow * (1.0 - nl[i]));
    v = v * (1.0 - params.noiseMid * (1.0 - nm[i]));
    a[i] = v;
  }

  // 材质耦合：字随墙面起伏或实或虚
  if (matVar != null && materialStrength > 0) {
    for (var i = 0; i < n; i++) {
      final f = 1.0 + (matVar[i] - 1.0) * materialStrength;
      a[i] = (a[i] * f).clamp(0.0, 1.0);
    }
  }

  // 边缘毛糙：a − erode(a) 得到边缘，再用高频噪声扰动
  if (params.edgeErode) {
    final er = math.max(1, (h * 0.0015).round());
    var eroded = Float32List.fromList(a);
    for (var k = 0; k < er; k++) {
      eroded = minFilterGray(eroded, w, h, 3);
    }
    for (var i = 0; i < n; i++) {
      final edge = (a[i] - eroded[i]).clamp(0.0, 1.0);
      final perturb = (nh[i] - 0.5) * 2.0 * params.noiseHigh;
      a[i] = (a[i] + edge * perturb).clamp(0.0, 1.0);
    }
  }

  // 颜料扩散：blur(a) 超出 a 的部分按强度补回去（颜料洇开）
  if (params.diffusion > 0) {
    final r = math.max(1.0, h * 0.0018);
    final blurred = blurGray(a, w, h, r);
    for (var i = 0; i < n; i++) {
      final diff = (blurred[i] - a[i]).clamp(0.0, 1.0) * params.diffusion;
      a[i] = (a[i] + diff).clamp(0.0, 1.0);
    }
  }

  // 氧化颗粒：随机小点变淡
  if (params.oxidation > 0) {
    final rng = Rng(seed);
    final total = (n * 0.00010).round();
    for (var k = 0; k < total; k++) {
      final x = rng.nextInt() % w;
      final y = rng.nextInt() % h;
      final i = y * w + x;
      if (a[i] > 0.1) {
        final y0 = math.max(0, y - 1), y1 = math.min(h, y + 2);
        final x0 = math.max(0, x - 1), x1 = math.min(w, x + 2);
        final f = 1.0 - params.oxidation * 0.5;
        for (var yy = y0; yy < y1; yy++) {
          for (var xx = x0; xx < x1; xx++) {
            a[yy * w + xx] *= f;
          }
        }
      }
    }
  }

  return a;
}

/// 接触阴影（基于光照方向偏移）。
Float32List computeContactShadow(
  Float32List alpha,
  int w,
  int h, {
  double shadowDx = 0.0,
  double shadowDy = 0.003,
}) {
  final blurPx = math.max(1, (h * 0.0010).round());
  final maxOff = (h * 0.0030).round();
  final offX = (h * shadowDx).round().clamp(-maxOff, maxOff);
  final offY = (h * shadowDy).round().clamp(-maxOff, maxOff);

  var dil = Float32List.fromList(alpha);
  for (var i = 0; i < math.max(1, blurPx); i++) {
    dil = maxFilterGray(dil, w, h, 3);
  }
  final n = w * h;
  final edge = Float32List(n);
  for (var i = 0; i < n; i++) {
    edge[i] = (dil[i] - alpha[i]).clamp(0.0, 1.0);
  }
  final shifted = shiftGray(edge, w, h, offX, offY);
  return blurGray(shifted, w, h, blurPx.toDouble());
}

/// 叠字合成（乘性反射）。返回 sRGB 字节（RGB）。
///
/// [baseSrgb] 为光照底图（w*h*3 字节）。
Uint8List fuseText({
  required Uint8List baseSrgb,
  required int width,
  required int height,
  required Float32List alpha,
  required Float32List occlusion,
  List<double> cinnabar = kCinnabar,
  double shadowStrength = 0.25,
  double extraExposure = 1.0,
}) {
  final n = width * height;
  final out = Uint8List(n * 3);
  final s2l = buildSrgbToLinearLut();
  for (var i = 0; i < n; i++) {
    final a = alpha[i].clamp(0.0, 1.0);
    final occ = occlusion[i] * shadowStrength;
    for (var c = 0; c < 3; c++) {
      final lin = s2l[baseSrgb[i * 3 + c]];
      final lit = lin * (1.0 - occ);
      final rho = (1.0 - a) + a * cinnabar[c];
      var v = lit * rho * extraExposure;
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      out[i * 3 + c] = (linearToSrgb(v) * 255.0 + 0.5).toInt().clamp(0, 255);
    }
  }
  return out;
}

/// 仅编码（不做叠字）：线性 RGB → sRGB 字节。
Uint8List encodeLinear(Float32List linear) => encodeSrgbBytes(linear);
