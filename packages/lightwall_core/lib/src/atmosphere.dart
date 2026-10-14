// 室内光照物理（晴天专用）
//
// 参考实现里这一层是为"任意天气"设计的（云量/降水/湿度/能见度/地面状态）。
// 本项目**禁用天气系统、只允许晴天**，于是：
//   · 云量恒 0 → 云透过率、云修正因子全部为 1（直接删掉分支）
//   · 无降水   → 水膜覆盖率 0、湿面响应 0
//   · 能见度 20km → 气溶胶光学厚度取基准 0.05
//   · 地面状态恒为"干"→ 反照率 0.25
// 保留的仍然是**真正与物理有关**的部分：大气质量、分波长透过率、
// 窗户面光源积分、室内互反射底、视觉适应曝光。
import 'dart:math' as math;
import 'dart:typed_data';

import 'scene3d.dart';

/// 室内平均反射率（白灰墙面 + 水泥地）。
const double kRoomAlbedo = 0.55;

/// 干燥地面反照率。
const double kGroundAlbedoDry = 0.25;

/// 视觉适应幂律指数（Stevens 幂律，文献 0.33~0.5）。
const double kEyeAdaptGamma = 0.40;

/// 暮光高度角阈值（低于此角度按暗适应处理，不再提亮）。
const double kTwilightAltDeg = 10.0;

/// 直射/漫射分解（晴天）。
///
/// 晴天无云，故直射即晴空直射，漫射即晴空天光；
/// 唯一参与的物理量是太阳高度角（已在 clearBeam/clearDiffuse 中体现）。
({double beam, double diffuse, double hardness}) splitIrradiance(
    double clearBeam, double clearDiffuse) {
  final total = clearBeam + clearDiffuse;
  return (
    beam: clearBeam,
    diffuse: clearDiffuse,
    hardness: total > 1e-9 ? clearBeam / total : 0.0,
  );
}

/// 视觉适应曝光倍率（EV）：人眼/相机的自动曝光。
///
/// 晴天下 E ≈ 1，EV ≈ 1；黄昏时按高度角淡出适应，避免"把夜晚提亮成白天"。
double eyeExposureEv(double illuminance,
    {double ref = 1.0, double sunAlt = 45.0}) {
  if (illuminance <= 0) return 1.0;
  final w = (math.max(0.0, sunAlt) / kTwilightAltDeg).clamp(0.0, 1.0);
  if (w <= 0) return 1.0;
  final evRaw = math.pow(ref / illuminance, kEyeAdaptGamma).toDouble();
  final ev = 1.0 + w * (evRaw - 1.0);
  return ev.clamp(0.25, 4.0);
}

/// 窗户开口的照度场 —— 把窗户当**矩形面光源**做面积分。
///
/// 物理：有限大面光源对墙点的照度
///     E(P) = ∫∫_窗面  L · cosθ_win · cosθ_wall / r²  dA
/// 用 samplesY × samplesZ 采样求和近似。归一化到均值 1（只重新分配光，
/// 不改变总曝光）。
///
/// ⚠ 这个"面光源积分"是室内明暗过渡的关键：若用窗心单点（点光源），
/// 1/r² 衰减过陡，会把照度场做成"以窗心为圆心的径向光晕"；
/// 真实窗户是扩展光源，照度场是**沿离窗方向缓慢下降的软场**。
Float64List apertureIlluminance(
  Float64List pts,
  Float64List valid,
  Scene3D scene, {
  int samplesY = 3,
  int samplesZ = 3,
  int stride = 1,
}) {
  final pl = scene.placement();
  final n = valid.length;
  final e = Float64List(n);

  // 窗面在世界坐标下的矩形（东/西墙为 (z,y)，后墙为 (x,y)）
  final u0 = pl.u0, u1 = pl.u1, v0 = pl.v0, v1 = pl.v1;
  final plane = pl.planeCoord;
  final dA = ((u1 - u0).abs() * (v1 - v0).abs()) / (samplesY * samplesZ);

  // 逐点（支持按 stride 跳点，随后上采样）
  for (var i = 0; i < n; i += stride) {
    if (valid[i] <= 0) continue;
    final o = i * 3;
    // 画面可能略宽于房间：把点夹到房间内，避免边缘出现假的亮带
    final px = pts[o].clamp(-scene.cfg.roomW * 0.5, scene.cfg.roomW * 0.5);
    final py = pts[o + 1].clamp(0.0, scene.cfg.roomH);
    final pz = pts[o + 2].clamp(0.0, scene.cfg.roomD);
    var acc = 0.0;
    for (var si = 0; si < samplesY; si++) {
      final u = u0 + (u1 - u0) * (si + 0.5) / samplesY;
      for (var sj = 0; sj < samplesZ; sj++) {
        final v = v0 + (v1 - v0) * (sj + 0.5) / samplesZ;
        double dx, dy, dz, cosWin;
        if (pl.wall == Wall.east || pl.wall == Wall.west) {
          dx = plane - px;
          dy = v - py;
          dz = u - pz;
          cosWin = dx.abs();
        } else {
          dx = u - px;
          dy = v - py;
          dz = plane - pz;
          cosWin = dz.abs();
        }
        final r2 = dx * dx + dy * dy + dz * dz;
        final r = math.sqrt(math.max(r2, 1e-6));
        final cosWall = dz.abs() / r; // 观察墙法线为 +Z
        acc += dA * (cosWin / r) * cosWall / r2;
      }
    }
    e[i] = acc;
  }

  // 归一化（用有效区均值）
  var sum = 0.0;
  var cnt = 0;
  for (var i = 0; i < n; i++) {
    if (valid[i] > 0) {
      sum += e[i];
      cnt++;
    }
  }
  final mean = cnt > 0 ? sum / cnt : 1.0;
  final inv = mean > 1e-12 ? 1.0 / mean : 0.0;
  for (var i = 0; i < n; i++) {
    e[i] *= inv;
  }
  return e;
}

/// 室内多次互反射的"均匀底"：k = ρ/(1−ρ)。
///
/// ρ=0.55 的白灰房间 → k ≈ 1.22：光在墙面/地面之间反复弹射，
/// 形成一层近似全房间均匀的照度底 —— 这就是"天空主导时几乎铺满整个房间"。
double interreflectionFloor([double? roomAlbedo]) {
  final rho = (roomAlbedo ?? kRoomAlbedo).clamp(0.0, 0.95);
  return rho / math.max(1e-6, 1.0 - rho);
}

/// 照度场混合：窗口直入 + 互反射底（并保持均值 1）。
///
/// 照度场是**低频场**，因此在缩小网格上计算、再上采样回全分辨率
/// （与参考实现用 working_size 的做法一致），速度提升数倍而视觉无差。
Float64List illuminationField(
  Float64List pts,
  Float64List valid,
  Scene3D scene, {
  int width = 0,
  int height = 0,
  int maxWork = 512,
}) {
  if (width > 0 && height > 0) {
    final shortSide = width < height ? width : height;
    if (shortSide > maxWork) {
      final scale = maxWork / shortSide;
      final ww = (width * scale).round().clamp(32, width);
      final wh = (height * scale).round().clamp(32, height);
      final sw = width / ww;
      final sh = height / wh;
      // 取每块的代表点（近邻抽样）
      final subPts = Float64List(ww * wh * 3);
      final subValid = Float64List(ww * wh);
      for (var y = 0; y < wh; y++) {
        for (var x = 0; x < ww; x++) {
          final sx = (x * sw).floor().clamp(0, width - 1);
          final sy = (y * sh).floor().clamp(0, height - 1);
          final si = sy * width + sx;
          final di = (y * ww + x);
          subValid[di] = valid[si];
          subPts[di * 3] = pts[si * 3];
          subPts[di * 3 + 1] = pts[si * 3 + 1];
          subPts[di * 3 + 2] = pts[si * 3 + 2];
        }
      }
      final low = _fieldFrom(subPts, subValid, scene, ww, wh);
      // 上采样（双线性）
      final out = Float64List(width * height);
      for (var y = 0; y < height; y++) {
        final fy = (y + 0.5) * (wh / height) - 0.5;
        var y0 = fy.floor();
        final wy = fy - y0;
        final y1 = (y0 + 1).clamp(0, wh - 1);
        if (y0 < 0) y0 = 0;
        for (var x = 0; x < width; x++) {
          final fx = (x + 0.5) * (ww / width) - 0.5;
          var x0 = fx.floor();
          final wx = fx - x0;
          final x1 = (x0 + 1).clamp(0, ww - 1);
          if (x0 < 0) x0 = 0;
          final a = low[y0 * ww + x0];
          final b = low[y0 * ww + x1];
          final c = low[y1 * ww + x0];
          final d = low[y1 * ww + x1];
          out[y * width + x] =
              (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy;
        }
      }
      return out;
    }
  }
  return _fieldFrom(pts, valid, scene, width, height);
}

Float64List _fieldFrom(
    Float64List pts, Float64List valid, Scene3D scene, int width, int height) {
  final e = apertureIlluminance(pts, valid, scene);
  final k = interreflectionFloor();
  final out = Float64List(e.length);
  for (var i = 0; i < e.length; i++) {
    final f = (e[i] + k) / (1.0 + k);
    out[i] = f.clamp(1e-4, 1e4);
  }
  return out;
}

/// 空气光占比（晴空能见度 20km，室内光程几米 → 实际只有千分之几）。
double airlightFraction(double pathM, {double visM = 20000.0}) {
  const k = 3.912;
  final beta = k / math.max(50.0, visM);
  return (1.0 - math.exp(-beta * math.max(0.0, pathM))).clamp(0.0, 1.0);
}

/// 窗户入射余弦：透过窗户的辐射通量 ∝ 窗的投影面积 = A·cosθ。
///
/// 参考实现里这是一个**真 bug 的修复**：早期版本只做"能不能穿过去"的
/// 二元判定，没有乘入射余弦，于是太阳几乎与窗面平行（掠射）时，
/// 本该几乎没有直射进屋，却照样投出大片光斑。
double windowIncidenceCos(List<double> toSun, List<double> windowNormal) =>
    math.max(
        0.0,
        toSun[0] * windowNormal[0] +
            toSun[1] * windowNormal[1] +
            toSun[2] * windowNormal[2]);
