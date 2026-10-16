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
///
/// 立场修正（报告 MA 系列）：从**单张照片**反推反射率/法线/粗糙度是病态的
/// 逆问题（对任意 R 都有 S=I/R），过去那套"min 通道当光照 / 局部方差当粗糙度
/// / 亮度梯度当法线 / 比周围亮当高光"的做法会**伪造**出物理上不存在的结构
/// （把底图花纹当浮雕、把对比度当微表面粗糙度）。这里只保留有物理依据的部分：
///   · 漫反射基色 ρ = Retinex 去光照后的 albedo（不再二次去光照）；
///   · 粗糙度取室内涂装墙面的物理合理常数；
///   · 法线取真实几何（平面墙）；
///   · 镜面能量由 tracer 的 Fresnel 项承担（不需要伪造的高光图）。
/// 逐像素的粗糙度/法线/镜面若要真正恢复，需要多发/多视角输入或材质库，属
/// 产品定位级决策（见待决策）。
MaterialMaps extractMaterial(Float32List rClean, int w, int h) {
  final n = w * h;

  // ── 1. 漫反射基色 ρ = 反射率 ──
  // 直接来自 Retinex 的 albedo（已经剥离了光照），按能量守恒钳到 [0,1]。
  // 旧实现又对这张图取"通道最小值当光照"再除一次 —— 二次去光照；而且
  // "shading=min(R,G,B)"这个彩色先验只在**灰色光照**下成立，有色物体上会把
  // 物体的色度当光照除掉（色度被夸大约 5×）；末尾的"均值归一到 1"还抹掉了
  // 不同底图的绝对反射率。
  final albedo = Float32List(n * 3);
  for (var i = 0; i < n * 3; i++) {
    albedo[i] = rClean[i].clamp(0.0, 1.0);
  }

  // ── 2. 粗糙度：室内涂装墙面/壁纸的物理合理常数（α≈0.5）──
  final roughness = Float32List(n);
  for (var i = 0; i < n; i++) {
    roughness[i] = 0.5;
  }

  // ── 3. 法线：平面墙的真实几何法线 (0,0,1) ──
  final normal = Float32List(n * 3);
  for (var i = 0; i < n; i++) {
    normal[i * 3 + 2] = 1.0;
  }

  // ── 4. 镜面：由 tracer 的 Fresnel 承担 ──
  final specular = Float32List(n);

  // ── 5. 高度图 / 水面：不再从 albedo 积分高度、不做阈值水面判定 ──
  final heightMap = Float32List(n);
  final isWater = Uint8List(n);

  return MaterialMaps(
    width: w,
    height: h,
    albedo: albedo,
    roughness: roughness,
    normal: normal,
    specular: specular,
    heightMap: heightMap,
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
