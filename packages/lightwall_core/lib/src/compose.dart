// 合成与相机效果（线性光 → sRGB 成品）
//
// 参考实现的合成链：直射先过 ACES → 与环境光相加 → 光斑反弹光 →
// 材质影响 → 阴影色偏 → 曝光/饱和度 → 渐晕 → CMOS 响应曲线 → sRGB 编码。
import 'dart:math' as math;
import 'dart:typed_data';

import 'mathx.dart';

/// 相机效果与画面参数。
class LookConfig {
  const LookConfig({
    this.acesGain = 1.25,
    this.vignetteStrength = 0.15,
    this.shadowBlueTint = 0.06,
    this.sensorCurveStrength = 0.05,
    this.materialStrength = 0.55,
    this.patchBounceStrength = 0.12,
    this.exposure = 1.0,
    this.saturation = 1.0,
    this.contrast = 1.0,
  });

  final double acesGain;
  final double vignetteStrength;
  final double shadowBlueTint;
  final double sensorCurveStrength;
  final double materialStrength;
  final double patchBounceStrength;
  final double exposure;
  final double saturation;
  final double contrast;

  LookConfig copyWith({
    double? exposure,
    double? saturation,
    double? materialStrength,
    double? contrast,
    double? vignetteStrength,
  }) =>
      LookConfig(
        acesGain: acesGain,
        vignetteStrength: vignetteStrength ?? this.vignetteStrength,
        shadowBlueTint: shadowBlueTint,
        sensorCurveStrength: sensorCurveStrength,
        materialStrength: materialStrength ?? this.materialStrength,
        patchBounceStrength: patchBounceStrength,
        exposure: exposure ?? this.exposure,
        saturation: saturation ?? this.saturation,
        contrast: contrast ?? this.contrast,
      );
}

/// ACES 色调映射（带增益）。
void acesInPlace(Float32List rgb, double gain) {
  for (var i = 0; i < rgb.length; i++) {
    rgb[i] = acesToneMap(rgb[i] * gain);
  }
}

/// 合成：直射（ACES） + 环境光，并施加相机效果。
///
/// [direct] 与 [ambient] 均为线性 RGB（w*h*3）。
Float32List synthesize({
  required Float32List direct,
  required Float32List ambient,
  required int width,
  required int height,
  required LookConfig look,
  Float32List? materialVariation,
  Float32List? patchMask,
}) {
  final n = width * height;
  final out = Float32List(n * 3);

  // 1. 直射过 ACES
  final d = Float32List.fromList(direct);
  acesInPlace(d, look.acesGain);

  // 2. 相加
  for (var i = 0; i < n * 3; i++) {
    out[i] = d[i] + ambient[i];
  }

  // 3. 光斑反弹光（光斑周围暖晕）
  if (look.patchBounceStrength > 0 && patchMask != null) {
    final src = Float32List(n);
    for (var i = 0; i < n; i++) {
      src[i] =
          patchMask[i] * (d[i * 3] + d[i * 3 + 1] + d[i * 3 + 2]) / 3.0 * 0.5;
    }
    final small = blurGray(
        src, width, height, math.max(3.0, math.min(width, height) * 0.03));
    final large = blurGray(
        src, width, height, math.max(8.0, math.min(width, height) * 0.08));
    final k = look.patchBounceStrength;
    for (var i = 0; i < n; i++) {
      final v = (small[i] * 0.6 + large[i] * 0.4) * k;
      out[i * 3] += v * 1.00;
      out[i * 3 + 1] += v * 0.92;
      out[i * 3 + 2] += v * 0.80;
    }
  }

  // 4. 材质影响
  if (materialVariation != null && look.materialStrength > 0) {
    for (var i = 0; i < n; i++) {
      final f = 1.0 + (materialVariation[i] - 1.0) * look.materialStrength;
      out[i * 3] *= f;
      out[i * 3 + 1] *= f;
      out[i * 3 + 2] *= f;
    }
  }

  // 5. 阴影色偏（暗部偏蓝）
  if (look.shadowBlueTint > 0) {
    for (var i = 0; i < n; i++) {
      final lum = (out[i * 3] + out[i * 3 + 1] + out[i * 3 + 2]) / 3.0;
      final wgt = (1.0 - lum * 2.0).clamp(0.0, 1.0) * look.shadowBlueTint;
      out[i * 3 + 1] += wgt * 0.05;
      out[i * 3 + 2] += wgt * 0.10;
    }
  }

  // 6. 对比度（晴天硬光 → 高对比）：在 sRGB 感知域做平滑 S 曲线
  if ((look.contrast - 1.0).abs() > 1e-3) {
    final k = look.contrast;
    for (var i = 0; i < n * 3; i++) {
      final s = linearToSrgb(out[i]);
      final curve = s * s * (3.0 - 2.0 * s);
      out[i] = srgbToLinear(s + (curve - s) * (k - 1.0));
    }
  }

  // 7. 曝光 / 饱和度（用户微调，线性域）
  if ((look.exposure - 1.0).abs() > 1e-4) {
    for (var i = 0; i < n * 3; i++) {
      out[i] *= look.exposure;
    }
  }
  if ((look.saturation - 1.0).abs() > 1e-4) {
    for (var i = 0; i < n; i++) {
      final gray = (out[i * 3] + out[i * 3 + 1] + out[i * 3 + 2]) / 3.0;
      for (var c = 0; c < 3; c++) {
        out[i * 3 + c] = gray + (out[i * 3 + c] - gray) * look.saturation;
      }
    }
  }

  // 8. 镜头渐晕
  if (look.vignetteStrength > 0) {
    final cx = width / 2.0, cy = height / 2.0;
    final maxDist = math.sqrt(cx * cx + cy * cy);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x - cx, dy = y - cy;
        final dist = math.sqrt(dx * dx + dy * dy) / maxDist;
        final v = 1.0 - look.vignetteStrength * dist * dist;
        final i = (y * width + x) * 3;
        out[i] *= v;
        out[i + 1] *= v;
        out[i + 2] *= v;
      }
    }
  }

  // 9. CMOS 响应曲线
  if (look.sensorCurveStrength > 0) {
    for (var i = 0; i < n * 3; i++) {
      final v = out[i].clamp(0.0, 1.0);
      out[i] = out[i] * (1.0 + look.sensorCurveStrength * (1.0 - v));
    }
  }

  // 10. 限幅
  for (var i = 0; i < n * 3; i++) {
    out[i] = out[i].clamp(0.0, 1.0);
  }
  return out;
}

/// 线性 RGB → sRGB 字节流（RGB，长度 w*h*3）。
Uint8List encodeSrgbBytes(Float32List linear) {
  final out = Uint8List(linear.length);
  for (var i = 0; i < linear.length; i++) {
    out[i] = (linearToSrgb(linear[i]) * 255.0 + 0.5).clamp(0, 255).toInt();
  }
  return out;
}

/// sRGB 字节 → 线性浮点。
Float32List decodeSrgbToLinear(Uint8List bytes) {
  final out = Float32List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    out[i] = srgbToLinear(bytes[i] / 255.0);
  }
  return out;
}
