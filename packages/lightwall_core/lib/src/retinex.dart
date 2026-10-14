// Retinex 光照/反射率分解
//
// 目的：把"平光底图"里可能残留的光照（用户自定义图片常常自带光照）
// 剥离出来，只保留反射率（albedo），这样重新打光才是物理正确的。
//
// 多尺度 Retinex：I = R × S，S 为低频光照，R 为反射率。
// 关键点（来自参考实现的实践）：
//   · 光照 S 是低频 → 在缩小的"工作尺寸"上算（默认短边 ≤ 1024）
//   · R = I / S 在**原始分辨率**上做 → 保留纹理细节
//   · 均值匹配 → 不改变原图整体亮度
import 'dart:math' as math;
import 'dart:typed_data';

import 'mathx.dart';

/// 分解结果。
class RetinexResult {
  RetinexResult({
    required this.albedo,
    required this.shading,
    required this.brightRatio,
    required this.darkRatio,
  });

  /// 反射率 RGB（w*h*3）
  final Float32List albedo;

  /// 光照分量（w*h）
  final Float32List shading;

  final double brightRatio;
  final double darkRatio;
}

/// 工作尺寸上限（短边）。
const int kRetinexWorkSize = 1024;

/// 多尺度 Retinex 分解。
///
/// [wallLin] 为线性光 RGB（w*h*3）。
RetinexResult decomposeAlbedo(Float32List wallLin, int w, int h,
    {int maxWork = kRetinexWorkSize}) {
  final n = w * h;
  final shortSide = math.min(w, h);
  final scale = shortSide > maxWork ? maxWork / shortSide : 1.0;
  final ww = math.max(64, (w * scale).round());
  final wh = math.max(64, (h * scale).round());
  final downscaled = ww != w || wh != h;

  // 亮度（工作尺寸）
  final graySrc = Float32List(n);
  for (var i = 0; i < n; i++) {
    graySrc[i] = 0.2126 * wallLin[i * 3] +
        0.7152 * wallLin[i * 3 + 1] +
        0.0722 * wallLin[i * 3 + 2];
  }
  final grayWork = downscaled ? resizeGray(graySrc, w, h, ww, wh) : graySrc;

  // log(I)
  final logGray = Float32List(ww * wh);
  for (var i = 0; i < ww * wh; i++) {
    logGray[i] = math.log(math.max(grayWork[i], 1e-6));
  }

  // 多尺度光照估计
  const scales = <double>[0.15, 0.35, 0.60];
  const weights = <double>[0.20, 0.30, 0.50];
  final logS = Float32List(ww * wh);
  for (var s = 0; s < scales.length; s++) {
    final radius = math.max(2.0, math.min(ww, wh) * scales[s]);
    final blurred = blurGray(logGray, ww, wh, radius);
    for (var i = 0; i < ww * wh; i++) {
      logS[i] += weights[s] * blurred[i];
    }
  }

  // S 上采样回原尺寸
  final sWork = Float32List(ww * wh);
  for (var i = 0; i < ww * wh; i++) {
    sWork[i] = math.exp(logS[i]);
  }
  final sGray = downscaled ? resizeGray(sWork, ww, wh, w, h) : sWork;

  // R = I / S（原始分辨率）
  final r = Float32List(n * 3);
  var targetMean = 0.0;
  for (var i = 0; i < n; i++) {
    targetMean +=
        (wallLin[i * 3] + wallLin[i * 3 + 1] + wallLin[i * 3 + 2]) / 3.0;
  }
  targetMean /= math.max(1, n);
  var curMean = 0.0;
  for (var i = 0; i < n; i++) {
    final s = math.max(sGray[i], 1e-6);
    for (var c = 0; c < 3; c++) {
      r[i * 3 + c] = wallLin[i * 3 + c] / s;
    }
    curMean += (r[i * 3] + r[i * 3 + 1] + r[i * 3 + 2]) / 3.0;
  }
  curMean /= math.max(1, n);
  if (curMean > 1e-6) {
    final k = targetMean / curMean;
    for (var i = 0; i < n * 3; i++) {
      r[i] = (r[i] * k).clamp(0.001, 1.0);
    }
  } else {
    for (var i = 0; i < n * 3; i++) {
      r[i] = r[i].clamp(0.001, 1.0);
    }
  }

  // 异常检测（底图自带光斑/阴影时，把它们从反射率里抹掉）
  final baseline = blurGray(sGray, w, h, math.max(11.0, math.min(w, h) * 0.05));
  var brightCount = 0;
  var darkCount = 0;
  final brightMask = Uint8List(n);
  final darkMask = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final dev = sGray[i] - baseline[i];
    if (dev > 0.15) {
      brightMask[i] = 1;
      brightCount++;
    } else if (dev < -0.20) {
      darkMask[i] = 1;
      darkCount++;
    }
  }
  final brightRatio = brightCount / math.max(1, n);
  final darkRatio = darkCount / math.max(1, n);

  // 用低频背景填充异常区（参考实现用中值滤波，这里用大半径模糊：
  // 目的只是"抹平"，模糊的结果在视觉上等价且快得多）
  if (brightRatio > 0 && brightRatio < 0.30) {
    _inpaint(r, n, w, h, brightMask, math.max(11.0, math.min(w, h) * 0.05));
  }
  if (darkRatio > 0 && darkRatio < 0.30) {
    _inpaint(r, n, w, h, darkMask, math.max(11.0, math.min(w, h) * 0.05));
  }

  return RetinexResult(
    albedo: r,
    shading: sGray,
    brightRatio: brightRatio,
    darkRatio: darkRatio,
  );
}

void _inpaint(
    Float32List rgb, int n, int w, int h, Uint8List mask, double radius) {
  // 逐通道：用低频版本替换被标记的像素
  for (var c = 0; c < 3; c++) {
    final ch = Float32List(n);
    for (var i = 0; i < n; i++) {
      ch[i] = rgb[i * 3 + c];
    }
    final low = blurGray(ch, w, h, radius);
    for (var i = 0; i < n; i++) {
      if (mask[i] != 0) {
        rgb[i * 3 + c] = low[i].clamp(0.001, 1.0);
      }
    }
  }
}
