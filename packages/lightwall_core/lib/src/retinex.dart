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

/// 多尺度 Retinex 分解（**逐通道**）。
///
/// [wallLin] 为线性光 RGB（w*h*3）。
///
/// 修正（报告 RE 系列）：
///   · **逐通道**估计光照 S_c。光照是**有色**的（天光偏蓝、日落偏暖），只除以
///     一个标量亮度会把底图的平光色偏当材质色、重打光后色偏被"平方"（RE-10）。
///   · 去掉了"把反射率均值重标定回原图均值"（RE-4）：那会抹掉 albedo 的绝对
///     量纲，使 ρ 与照度不可分离。R_c = I_c/S_c 直接作为反射率。
///   · ρ 按能量守恒钳到 [0,1]（RE-5 的平顶问题在逐通道+不重标定后大幅缓解）。
RetinexResult decomposeAlbedo(Float32List wallLin, int w, int h,
    {int maxWork = kRetinexWorkSize}) {
  final n = w * h;
  final shortSide = math.min(w, h);
  final scale = shortSide > maxWork ? maxWork / shortSide : 1.0;
  final ww = math.max(64, (w * scale).round());
  final wh = math.max(64, (h * scale).round());
  final downscaled = ww != w || wh != h;

  // 多尺度：更小的尺度（更细）权重更高 —— 低频是光照本体、细节归反射率。
  const scales = <double>[0.08, 0.20, 0.40, 0.65];
  const wts = <double>[0.12, 0.20, 0.28, 0.40];

  final albedo = Float32List(n * 3);
  final sLum = Float32List(n);
  for (var c = 0; c < 3; c++) {
    final chan = Float32List(n);
    for (var i = 0; i < n; i++) {
      chan[i] = wallLin[i * 3 + c];
    }
    final work = downscaled ? resizeGray(chan, w, h, ww, wh) : chan;
    final logC = Float32List(ww * wh);
    for (var i = 0; i < ww * wh; i++) {
      logC[i] = math.log(math.max(work[i], 1e-6));
    }
    final logS = Float32List(ww * wh);
    for (var s = 0; s < scales.length; s++) {
      final radius = math.max(2.0, math.min(ww, wh) * scales[s]);
      final blurred = blurGray(logC, ww, wh, radius);
      for (var i = 0; i < ww * wh; i++) {
        logS[i] += wts[s] * blurred[i];
      }
    }
    final sWork = Float32List(ww * wh);
    for (var i = 0; i < ww * wh; i++) {
      sWork[i] = math.exp(logS[i]);
    }
    final sCh = downscaled ? resizeGray(sWork, ww, wh, w, h) : sWork;
    final wc = switch (c) {
      0 => 0.2126,
      1 => 0.7152,
      _ => 0.0722,
    };
    for (var i = 0; i < n; i++) {
      final s = math.max(sCh[i], 1e-6);
      albedo[i * 3 + c] = (wallLin[i * 3 + c] / s).clamp(0.0, 1.0);
      sLum[i] += wc * sCh[i];
    }
  }

  // 异常检测（底图自带光斑/阴影时，把它们从反射率里抹平）—— 作用在**光照
  // 亮度**上，阈值两侧对称（旧实现 dev>0.15 / dev<−0.20 不对称是手挑的）。
  final baseline =
      blurGray(sLum, w, h, math.max(11.0, math.min(w, h) * 0.05));
  var brightCount = 0;
  var darkCount = 0;
  final brightMask = Uint8List(n);
  final darkMask = Uint8List(n);
  const devThresh = 0.18; // 同一阈值两侧对称
  for (var i = 0; i < n; i++) {
    final dev = sLum[i] - baseline[i];
    if (dev > devThresh) {
      brightMask[i] = 1;
      brightCount++;
    } else if (dev < -devThresh) {
      darkMask[i] = 1;
      darkCount++;
    }
  }
  final brightRatio = brightCount / math.max(1, n);
  final darkRatio = darkCount / math.max(1, n);

  if (brightRatio > 0 && brightRatio < 0.30) {
    _inpaint(albedo, n, w, h, brightMask, math.max(11.0, math.min(w, h) * 0.05));
  }
  if (darkRatio > 0 && darkRatio < 0.30) {
    _inpaint(albedo, n, w, h, darkMask, math.max(11.0, math.min(w, h) * 0.05));
  }

  return RetinexResult(
    albedo: albedo,
    shading: sLum,
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
