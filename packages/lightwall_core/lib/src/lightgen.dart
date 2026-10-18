// 窗光生成器（algorithmic wall lighting）
//
// 目标：**只看视觉结果**。不模拟光线传播、不做辐射积分、不跑锥体采样。
// 输入是几个面向画面的量（入射角、光斑面积、光晕），输出一张成品。
//
// 画面构成（三层叠加，全部在 0..1 的显示域里）：
//   1. 墙基底：底图反射率 × 环境光（冷色，暗部偏蓝）
//   2. 窗光斑：平行四边形 + 窗棂网格，暖色，边缘柔和
//   3. 光晕：光斑的大半径模糊叠加（镜头散射/空气散射的观感）
//
// 所有可调量集中在 [LightLook]，用户改这里就能改画面。
import 'dart:math' as math;
import 'dart:typed_data';

/// 面向画面的光照参数（不是物理量）。
class LightLook {
  const LightLook({
    this.patchWarmth = 1.0, // 光斑暖度：0=中性，1=暖黄，>1 更橙
    this.shadowCool = 1.0, // 暗部冷度：0=中性，1=蓝灰，>1 更蓝
    this.glowRadius = 0.09, // 光晕半径（画面宽度比例）
    this.glowStrength = 0.35, // 光晕强度
    this.patchSoftness = 0.012, // 光斑边缘柔化（画面宽度比例）
    this.patchBrightness = 1.0, // 光斑亮度
    this.ambientLevel = 0.20, // 环境光（墙基底）亮度
    this.contrast = 1.0,
    this.exposure = 1.0,
    this.grain = 0.010, // 颗粒（夜景更明显）
  });

  final double patchWarmth;
  final double shadowCool;
  final double glowRadius;
  final double glowStrength;
  final double patchSoftness;
  final double patchBrightness;
  final double ambientLevel;
  final double contrast;
  final double exposure;
  final double grain;

  LightLook copyWith({
    double? patchWarmth,
    double? shadowCool,
    double? glowRadius,
    double? glowStrength,
    double? patchSoftness,
    double? patchBrightness,
    double? ambientLevel,
    double? contrast,
    double? exposure,
    double? grain,
  }) =>
      LightLook(
        patchWarmth: patchWarmth ?? this.patchWarmth,
        shadowCool: shadowCool ?? this.shadowCool,
        glowRadius: glowRadius ?? this.glowRadius,
        glowStrength: glowStrength ?? this.glowStrength,
        patchSoftness: patchSoftness ?? this.patchSoftness,
        patchBrightness: patchBrightness ?? this.patchBrightness,
        ambientLevel: ambientLevel ?? this.ambientLevel,
        contrast: contrast ?? this.contrast,
        exposure: exposure ?? this.exposure,
        grain: grain ?? this.grain,
      );
}

/// 生成一面被窗光照射的墙。
///
/// [albedo]：墙面反射率（来自底图的 Retinex 分解），长度 w*h*3。
/// [sunAzRel]：太阳相对**窗法线**的水平偏角（度，0=正对窗）。
/// [sunAlt]：太阳高度角（度）。低角 → 光斑竖直拉长（面积变大）。
/// [warmColor]/[coolColor]：光斑色与阴影色（0..1 线性）。
Float32List generateWallLight({
  required int width,
  required int height,
  required Float32List albedo,
  required double sunAzRel,
  required double sunAlt,
  required double windowW,
  required double windowH,
  required int cols,
  required int rows,
  required LightLook look,
  List<double> warmColor = const [1.00, 0.72, 0.42],
  List<double> coolColor = const [0.30, 0.42, 0.62],
}) {
  final n = width * height;
  final out = Float32List(n * 3);

  // ── 1. 光斑几何（全部按画面比例算，不进世界坐标）──
  //
  // 面积：窗在墙上的等大投影 ≈ windowW × windowH，但太阳低时竖直方向被
  // 拉长 1/sin(alt)（斜射投影），面积随之变大 → "不同时段近光面积不同"。
  final altRad = (sunAlt.clamp(1.0, 89.0)) * math.pi / 180.0;
  final stretch = (1.0 / math.sin(altRad)).clamp(1.0, 4.2);
  // 画面里窗的标称尺寸（占画面宽/高的比例）
  final baseW = (windowW / 3.9).clamp(0.14, 0.55);
  final baseH = (windowH / 2.9).clamp(0.14, 0.55);
  final patchW = baseW;
  final patchH = (baseH * stretch).clamp(0.14, 0.92);

  // 位置：太阳偏角把光斑横向推走（偏得越多越靠边），高度角决定上下
  final azRad = sunAzRel * math.pi / 180.0;
  final cx = 0.46 + math.sin(azRad) * 0.42;
  final cy = 0.46 - (1.0 - math.sin(altRad)) * 0.06;

  // 斜切：太阳偏射时光斑是平行四边形（上边比下边偏得多）
  final skew = math.sin(azRad) * 0.30 + 0.10;

  final soft = math.max(look.patchSoftness, 1e-4);

  // ── 2. 逐像素 ──
  for (var y = 0; y < height; y++) {
    final v = (y + 0.5) / height; // 0 上 1 下
    for (var x = 0; x < width; x++) {
      final u = (x + 0.5) / width;
      final i = y * width + x;
      final i3 = i * 3;

      // 光斑局部坐标（含斜切）
      final dx = u - (cx + skew * (0.5 - v));
      final dy = v - cy;
      // 归一化到窗半宽/半高
      // 透视：远处（上）变窄 → 梯形；同时上下左右按 v 轻微压缩
      final persp = 1.0 + 0.30 * (v - cy);
      final pu = dx / (patchW * 0.5 * persp);
      final pv = dy / (patchH * 0.5);

      // 边缘柔化（屏幕空间近似：把 soft 转成归一坐标单位）
      final su = soft / (patchW * 0.5);
      final sv = soft / (patchH * 0.5);
      final eu = _edge(pu, su);
      final ev = _edge(pv, sv);
      var mask = eu * ev;

      // 窗棂网格（相对窗内归一坐标 0..1）
      if (mask > 0.001) {
        final gu = (pu + 1.0) * 0.5; // 0..1
        final gv = (pv + 1.0) * 0.5;
        // 外框
        const f = 0.035;
        if (gu < f || gu > 1 - f || gv < f || gv > 1 - f) mask = 0.0;
        if (mask > 0) {
          final ca = (gu * cols) % 1.0;
          final cb = (gv * rows) % 1.0;
          // 窗棂宽度：屏幕上看约 4~6 px 的效果（按归一化 0.09）
          const m = 0.085;
          // 窗棂不是纯黑：它被窗玻璃散射与室内环境照亮（参考图里窗棂是
          // 半透明的灰，不是硬黑线）
          const barLevel = 0.16;
          final ma = (ca < m || ca > 1 - m) ? barLevel : 1.0;
          final mb = (cb < m || cb > 1 - m) ? barLevel : 1.0;
          mask *= ma * mb;
        }
      }

      // ── 3. 合成 ──
      final aR = albedo[i3], aG = albedo[i3 + 1], aB = albedo[i3 + 2];
      // 环境（冷）：整体压暗 + 偏蓝
      final amb = look.ambientLevel;
      final cr = coolColor[0] * amb;
      final cg = coolColor[1] * amb;
      final cb = coolColor[2] * amb;

      // 光斑（暖）
      final pw = look.patchBrightness;
      final pr = warmColor[0] * pw;
      final pg = warmColor[1] * pw;
      final pb = warmColor[2] * pw;

      var r = aR * (cr + mask * pr);
      var g = aG * (cg + mask * pg);
      var b = aB * (cb + mask * pb);

      out[i3] = r;
      out[i3 + 1] = g;
      out[i3 + 2] = b;
    }
  }

  // ── 4. 光晕（光斑的大半径模糊，加在画面里）──
  if (look.glowStrength > 0) {
    final bright = Float32List(n);
    for (var i = 0; i < n; i++) {
      bright[i] = math.max(
          0.0,
          (out[i * 3] + out[i * 3 + 1] + out[i * 3 + 2]) / 3.0 -
              look.ambientLevel * 0.5);
    }
    final rad = math.max(2.0, look.glowRadius * width);
    final g1 = _blur(bright, width, height, rad * 0.35);
    final g2 = _blur(bright, width, height, rad);
    for (var i = 0; i < n; i++) {
      final add = (g1[i] * 0.6 + g2[i] * 0.4) * look.glowStrength;
      out[i * 3] += add * warmColor[0] * 0.9;
      out[i * 3 + 1] += add * warmColor[1] * 0.9;
      out[i * 3 + 2] += add * warmColor[2] * 0.9;
    }
  }

  return out;
}

/// 边缘函数：|t| < 1 内为 1，外侧 soft 范围内平滑降到 0。
double _edge(double t, double soft) {
  final a = t.abs();
  if (a <= 1.0) return 1.0;
  final e = (a - 1.0) / soft;
  if (e >= 1.0) return 0.0;
  final s = 1.0 - e;
  // 三次平滑（比 smoothstep 更“绵”）——参考照片的边缘是长距离渐隐
  return s * s * s * (s * (s * 6 - 15) + 10);
}

/// 可分离盒式模糊（两次求近似高斯）。
Float32List _blur(Float32List src, int w, int h, double radius) {
  final r = math.max(1, radius.round());
  final tmp = Float32List(src.length);
  final out = Float32List(src.length);
  // 水平
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      var c = 0;
      for (var k = -r; k <= r; k++) {
        final xx = x + k;
        if (xx < 0 || xx >= w) continue;
        s += src[y * w + xx];
        c++;
      }
      tmp[y * w + x] = c > 0 ? s / c : 0.0;
    }
  }
  // 垂直
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      var c = 0;
      for (var k = -r; k <= r; k++) {
        final yy = y + k;
        if (yy < 0 || yy >= h) continue;
        s += tmp[yy * w + x];
        c++;
      }
      out[y * w + x] = c > 0 ? s / c : 0.0;
    }
  }
  return out;
}
