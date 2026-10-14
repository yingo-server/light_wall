// PBR 材质提取（从 Retinex 反射率图推断）
//
// 从参考实现移植并整理。物理依据：
//   albedo   彩色先验：shading 是灰的，通道最小值近似 shading
//   roughness 局部方差小 → 光滑；大 → 粗糙
//   normal    亮度梯度（单光源光度立体近似）
//   specular  局部亮度超出周围环境的部分
//   height    法线积分（仅用于视觉增强）
//   is_water  低反射率 + 低粗糙度
import 'dart:math' as math;
import 'dart:typed_data';

import 'mathx.dart';

/// 材质通道集合。
class MaterialMaps {
  MaterialMaps({
    required this.width,
    required this.heightMap,
    required this.albedo,
    required this.roughness,
    required this.normal,
    required this.specular,
    required this.height,
    required this.isWater,
  });

  final int width;
  final int height;

  /// (w*h*3) 漫反射基色，均值 ≈ 1
  final Float32List albedo;

  /// (w*h) 粗糙度 0.1~0.9
  final Float32List roughness;

  /// (w*h*3) 单位法线（+Z 朝外）
  final Float32List normal;

  /// (w*h) 镜面强度 0~1
  final Float32List specular;

  /// (w*h) 相对高度，归一化到 [-1,1]
  final Float32List heightMap;

  /// (w*h) 水面标记
  final Uint8List isWater;

  double get waterRatio {
    var c = 0;
    for (var i = 0; i < isWater.length; i++) {
      if (isWater[i] != 0) c++;
    }
    return isWater.isEmpty ? 0 : c / isWater.length;
  }
}

/// 从反射率图 R_clean（RGB 交错，长度 w*h*3）提取材质。
MaterialMaps extractMaterial(Float32List rClean, int w, int h) {
  final n = w * h;

  // ── 1. 亮度 ──
  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    lum[i] = 0.2126 * rClean[i * 3] +
        0.7152 * rClean[i * 3 + 1] +
        0.0722 * rClean[i * 3 + 2];
  }

  // ── 2. Albedo（彩色先验）──
  final shading = Float32List(n);
  for (var i = 0; i < n; i++) {
    final r = rClean[i * 3], g = rClean[i * 3 + 1], b = rClean[i * 3 + 2];
    shading[i] = math.min(r, math.min(g, b));
  }
  final shadeBlur = blurGray(shading, w, h, math.max(4.0, math.min(w, h) * 0.03));
  final albedo = Float32List(n * 3);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = math.max(shadeBlur[i], 1e-6);
    for (var c = 0; c < 3; c++) {
      albedo[i * 3 + c] = rClean[i * 3 + c] / s;
    }
    sum += (albedo[i * 3] + albedo[i * 3 + 1] + albedo[i * 3 + 2]) / 3.0;
  }
  final mean = sum / math.max(1, n);
  if (mean > 1e-6) {
    final inv = 1.0 / mean;
    for (var i = 0; i < n * 3; i++) {
      albedo[i] = (albedo[i] * inv).clamp(0.05, 3.0);
    }
  }

  // ── 3. Roughness（局部方差）──
  final radius = math.max(3.0, math.min(w, h) * 0.008);
  final localMean = blurGray(lum, w, h, radius);
  final lumSq = Float32List(n);
  for (var i = 0; i < n; i++) {
    lumSq[i] = lum[i] * lum[i];
  }
  final localSq = blurGray(lumSq, w, h, radius);
  final roughness = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = math.max(localSq[i] - localMean[i] * localMean[i], 0.0);
    final std = math.sqrt(v);
    roughness[i] = ((std / math.max(localMean[i], 1e-4)) * 2.0).clamp(0.10, 0.90);
  }

  // ── 4. Normal（亮度梯度）──
  final lumSmooth = blurGray(lum, w, h, math.max(1.5, math.min(w, h) * 0.003));
  final gx = Float32List(n);
  final gy = Float32List(n);
  sobelGray(lumSmooth, w, h, gx, gy);
  final normal = Float32List(n * 3);
  for (var i = 0; i < n; i++) {
    final nx = -gx[i], ny = -gy[i], nz = 1.0;
    final inv = 1.0 / math.sqrt(nx * nx + ny * ny + 1.0);
    normal[i * 3] = nx * inv;
    normal[i * 3 + 1] = ny * inv;
    normal[i * 3 + 2] = nz * inv;
  }

  // ── 5. Specular（局部高光）──
  final large = blurGray(lum, w, h, math.max(8.0, math.min(w, h) * 0.05));
  final specular = Float32List(n);
  var peak = 0.0;
  for (var i = 0; i < n; i++) {
    final v = math.max(lum[i] - large[i], 0.0);
    specular[i] = v;
    if (v > peak) peak = v;
  }
  if (peak > 1e-6) {
    for (var i = 0; i < n; i++) {
      specular[i] = specular[i] / peak;
    }
  }

  // ── 6. Height（法线积分）──
  final height = Float32List(n);
  final hx = Float64List(n);
  final hy = Float64List(n);
  for (var y = 0; y < h; y++) {
    var acc = 0.0;
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      acc += -normal[i * 3] / math.max(normal[i * 3 + 2], 1e-4);
      hx[i] = acc;
    }
  }
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    for (var y = 0; y < h; y++) {
      final i = y * w + x;
      acc += -normal[i * 3 + 1] / math.max(normal[i * 3 + 2], 1e-4);
      hy[i] = acc;
    }
  }
  var hMean = 0.0;
  for (var i = 0; i < n; i++) {
    height[i] = (hx[i] + hy[i]) * 0.5;
    hMean += height[i];
  }
  hMean /= math.max(1, n);
  var hMax = 0.0;
  for (var i = 0; i < n; i++) {
    height[i] -= hMean;
    final a = height[i].abs();
    if (a > hMax) hMax = a;
  }
  if (hMax > 1e-6) {
    for (var i = 0; i < n; i++) {
      height[i] /= hMax;
    }
  }

  // ── 7. 水面判定 ──
  final isWater = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final l = (albedo[i * 3] + albedo[i * 3 + 1] + albedo[i * 3 + 2]) / 3.0;
    isWater[i] = (l < 0.10 && roughness[i] < 0.20) ? 1 : 0;
  }

  return MaterialMaps(
    width: w,
    height: h,
    albedo: albedo,
    roughness: roughness,
    normal: normal,
    specular: specular,
    heightMap: height,
    isWater: isWater,
  );
}

/// 材质起伏图（用于叠字的材质耦合）：均值 ≈ 1，>1 凸起、<1 凹陷。
Float32List materialVariation(Float32List rClean, int w, int h) {
  final n = w * h;
  final lum = Float32List(n);
  for (var i = 0; i < n; i++) {
    lum[i] = (rClean[i * 3] + rClean[i * 3 + 1] + rClean[i * 3 + 2]) / 3.0;
  }
  final large = blurGray(lum, w, h, math.max(10.0, math.min(w, h) * 0.05));
  final out = Float32List(n);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final v = lum[i] / math.max(large[i], 1e-6);
    out[i] = v;
    sum += v;
  }
  final mean = sum / math.max(1, n);
  if (mean > 1e-6) {
    for (var i = 0; i < n; i++) {
      out[i] = (out[i] / mean).clamp(0.65, 1.45);
    }
  }
  return out;
}
