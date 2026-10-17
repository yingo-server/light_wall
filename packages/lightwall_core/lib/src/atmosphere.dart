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

import 'mathx.dart';
import 'scene3d.dart';
import 'sky.dart';

/// 室内平均反射率（白灰墙面 + 水泥地）。见 [interreflectionFloor] 的
/// 面积加权口径；此处给出默认场景的等效值。
const double kRoomAlbedo = 0.55;

/// 干燥地面反照率。
const double kGroundAlbedoDry = 0.25;

/// 湿地面（雨后）反照率：水膜镜面化 + 暗化。丙类 --cloud --wet-ground 用。
const double kGroundAlbedoWet = 0.08;

// 说明：旧实现有 `splitIrradiance`（返回 beam/diffuse/hardness，全仓库无
// 消费者）与 `eyeExposureEv`（按太阳高度角淡出的增益，用"入射照度取幂"、
// 量纲无意义，且已被 sceneExposureEv 取代、渲染路径不再调用）——两者均为
// 死代码，已删除。曝光只保留 [sceneExposureEv] 一条物理路径。

/// 天顶半球上"相对天顶亮度分布"的余弦加权积分：
///     I_h = ∫∫ f(dir)·cosθ·sinθ dθ dφ   （单位 sr）
///
/// 用途：把"水平面漫射照度 E_sky"换算成"天顶亮度"。
///     E_sky = ∫ L·cosθ dΩ = L_z · I_h   ⇒   L_z = E_sky / I_h
/// 对朗伯天空 f ≡ 1 时 I_h = π ≈ 3.1416；CIE 晴空（地平线比天顶亮）
/// 时 I_h > π。早期实现直接假定 I_h = π（`L = E_sky/π`），与它自己的
/// CIE 天空分布不自洽，是环境光量级偏差的一个来源。
///
/// 该积分只依赖**固定的** CIE 晴空系数，是常数 —— 缓存结果。否则它会被
/// 窗面积分的**每个采样点**调用（一次 2048 步），单帧退化成几十秒。
double? _ihCache;
double horizontalDiffuseIntegral({int nTheta = 32, int nPhi = 64}) {
  final cached = _ihCache;
  if (cached != null) return cached;
  final dTheta = (math.pi / 2) / nTheta;
  final dPhi = 2 * math.pi / nPhi;
  var acc = 0.0;
  for (var i = 0; i < nTheta; i++) {
    final theta = (i + 0.5) * dTheta;
    final f = skyLuminanceFactor(theta, math.pi / 2, 0.0, 45.0);
    acc += f * math.cos(theta) * math.sin(theta) * dTheta * dPhi;
  }
  _ihCache = acc;
  return acc;
}

/// 地平线过渡带宽度（方向余弦）。_skyRadiance 与窗面颜色场共用，
/// 单一真源 —— 两处不一致会在地平线产生台阶。
const double kHorizonBlendBand = 0.06;

/// 室外地面（地平线以下方向）的相对辐亮度（天顶亮度 = 1）。
///
/// 物理：地面自身被"直射 + 漫射"照亮后再朗伯反射
///     L_ground = ρ_g · E_ground / π ,  E_ground = E_diffuse·(1 + r_bd)
/// 其中 r_bd = 直射/漫射水平照度比。归一化到天顶亮度 L_z = E_sky/I_h：
///     L_ground / L_z = ρ_g · (I_h/π) · (1 + r_bd)
///
/// 早期实现把地平线以下写死成 0.12，比真实值暗 **5~15×**（含直射的
/// 日照地面与晴空天顶同量级甚至更亮），而且与文件里同样定义却从未使用的
/// `kGroundAlbedoDry = 0.25` 直接矛盾。
double groundRadianceRelative(double beamToDiffuse,
    {double groundAlbedo = kGroundAlbedoDry}) {
  return groundAlbedo *
      (horizontalDiffuseIntegral() / math.pi) *
      (1.0 + math.max(0.0, beamToDiffuse));
}
///
/// 窗外不是"一片均匀的亮"：
///   · 地平线以上 → CIE 晴空亮度分布（太阳附近最亮，背面最暗）
///   · 地平线以下 → 看到的是室外地面/建筑立面，亮度约为地面反照率
///     对天光的反射（远低于天空本身），这也是真实照片里窗下半部
///     明显比上半部暗的原因。
///   · 地平线附近 → 平滑过渡（否则会出现一条硬边）
double _skyRadiance(
    double dirY,
    double gammaRad,
    double sunZenithDeg,
    double sunAltDeg,
    double beamToDiffuse,
    {double groundAlbedo = kGroundAlbedoDry, double cloudCover = 0.0}) {
  // 地平线以下：室外地面/建筑立面。用**物理公式**算（不再是常数 0.12）：
  //   L_ground/L_z = ρ_g·(I_h/π)·(1 + 直射/漫射比)
  final belowHorizon = groundRadianceRelative(beamToDiffuse,
      groundAlbedo: groundAlbedo);
  final blend = kHorizonBlendBand;
  if (dirY <= -blend) return belowHorizon;
  final zenithRad = math.acos(dirY.clamp(-1.0, 1.0));
  final sky = skyLuminanceFactor(
      zenithRad.clamp(0.0, math.pi * 0.5), gammaRad, sunZenithDeg, sunAltDeg,
      cloudCover: cloudCover);
  if (dirY >= blend) return sky;
  final t = (dirY + blend) / (2 * blend); // 0 → 下, 1 → 上
  return belowHorizon * (1 - t) + sky * t;
}

/// 窗户开口的照度场 —— 把窗户当**矩形面光源**做面积分。
///
/// 物理：有限大面光源对墙点的照度
///     E(P) = ∫∫_窗面  L(dir) · cosθ_win · cosθ_wall / r²  dA
///
/// 关键在 **L(dir)**：它不是常数。透过窗面采样点 Q 看到的窗外方向
/// dir = (Q−P)/|Q−P| 决定该处亮度 —— 太阳那侧的窗户进来更多光，
/// 天顶方向偏蓝偏亮，地平线以下（室外地面/建筑）明显更暗。
/// 早期实现把 L 当成常数 1，环境光因此没有任何方向结构：像一层平灰，
/// 与直射光斑硬叠在一起。
Float64List apertureIlluminance(
  Float64List pts,
  Float64List valid,
  Scene3D scene, {
  List<double>? toSun,
  double sunAltDeg = 45.0,
  double beamToDiffuse = 0.0,
  double groundAlbedo = kGroundAlbedoDry,
  double cloudCover = 0.0,
  int samplesU = 8,
  int samplesV = 8,
}) {
  final pl = scene.placement();
  final n = valid.length;
  final e = Float64List(n);

  // 窗面在世界坐标下的矩形（东/西墙为 (z,y)，后墙为 (x,y)）
  final u0 = pl.u0, u1 = pl.u1, v0 = pl.v0, v1 = pl.v1;
  final plane = pl.planeCoord;

  // 窗格**玻璃覆盖率**：窗框挡住的那部分不参与天光积分。
  // 早期实现用整窗矩形面积做 dA（把窗框当成全透玻璃），环境光因此偏高
  // 约 19%，并丢掉窗框在天光里投下的十字暗影。
  final spanU = (u1 - u0).abs();
  final spanV = (v1 - v0).abs();
  final cols = math.max(1, scene.cfg.gridCols);
  final rows = math.max(1, scene.cfg.gridRows);
  final cellU = spanU / cols;
  final cellV = spanV / rows;
  final frameW = scene.cfg.gridFrameRatio * math.min(cellU, cellV);
  final fGlass = cellU <= 0 || cellV <= 0
      ? 0.0
      : (((cellU - frameW) / cellU) * ((cellV - frameW) / cellV))
          .clamp(0.0, 1.0);

  final dA = spanU * spanV / (samplesU * samplesV) * fGlass;

  final sunZenithDeg = (90.0 - sunAltDeg).clamp(0.0, 90.0);
  final ts = toSun ?? const <double>[0.0, 1.0, 0.0];

  // 逐点积分（矩形面光源的双余弦积分）
  for (var i = 0; i < n; i++) {
    if (valid[i] <= 0) continue;
    final o = i * 3;
    // 画面可能略宽于房间：把点夹到房间内，避免边缘出现假的亮带
    final px = pts[o].clamp(-scene.cfg.roomW * 0.5, scene.cfg.roomW * 0.5);
    final py = pts[o + 1].clamp(0.0, scene.cfg.roomH);
    final pz = pts[o + 2].clamp(0.0, scene.cfg.roomD);
    var acc = 0.0;
    for (var si = 0; si < samplesU; si++) {
      final u = u0 + (u1 - u0) * (si + 0.5) / samplesU;
      for (var sj = 0; sj < samplesV; sj++) {
        final v = v0 + (v1 - v0) * (sj + 0.5) / samplesV;
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
        final inv = 1.0 / r;
        final cosWall = dz.abs() * inv; // 观察墙法线为 +Z

        // 透过该窗面采样点看到的窗外方向（P → Q，继续延伸到室外）
        final dirX = dx * inv, dirY = dy * inv, dirZ = dz * inv;
        final cosG =
            (dirX * ts[0] + dirY * ts[1] + dirZ * ts[2]).clamp(-1.0, 1.0);
        final lum =
            _skyRadiance(dirY, math.acos(cosG), sunZenithDeg, sunAltDeg,
                beamToDiffuse,
                groundAlbedo: groundAlbedo, cloudCover: cloudCover);

        acc += dA * (cosWin * inv) * cosWall * inv2(r2) * lum;
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

/// 逐像素的"地面占比"：进入该墙点的窗光里，来自**地平线以下**（室外地面/
/// 建筑立面）的能量占多少。
///
/// 两条要点：
///   · **连续**：不再把"地平线上下"当二元判定，而以与 `_skyRadiance` 同一
///     带宽（±0.06 方向余弦）做平滑过渡，故颜色随高度连续，无台阶/色带；
///   · **足量采样**：8×8，避免少样本造成离散色阶。
Float64List groundShareField(
  Float64List pts,
  Float64List valid,
  Scene3D scene, {
  int samplesU = 8,
  int samplesV = 8,
}) {
  final pl = scene.placement();
  final n = valid.length;
  final out = Float64List(n);
  final u0 = pl.u0, u1 = pl.u1, v0 = pl.v0, v1 = pl.v1;
  final plane = pl.planeCoord;
  final eastWest = pl.wall == Wall.east || pl.wall == Wall.west;
  final blend = kHorizonBlendBand;
  for (var i = 0; i < n; i++) {
    if (valid[i] <= 0) continue;
    final o = i * 3;
    final px = pts[o].clamp(-scene.cfg.roomW * 0.5, scene.cfg.roomW * 0.5);
    final py = pts[o + 1].clamp(0.0, scene.cfg.roomH);
    final pz = pts[o + 2].clamp(0.0, scene.cfg.roomD);
    var total = 0.0;
    var ground = 0.0;
    for (var si = 0; si < samplesU; si++) {
      final u = u0 + (u1 - u0) * (si + 0.5) / samplesU;
      for (var sj = 0; sj < samplesV; sj++) {
        final v = v0 + (v1 - v0) * (sj + 0.5) / samplesV;
        double dx, dy, dz, cosWin;
        if (eastWest) {
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
        final inv = 1.0 / r;
        final cosWall = dz.abs() * inv;
        final contrib = (cosWin * inv) * cosWall * inv2(r2);
        final dirY = dy * inv;
        // t: 1 = 天空（上），0 = 地面（下），在地平线附近平滑过渡
        final t = ((dirY + blend) / (2 * blend)).clamp(0.0, 1.0);
        total += contrib;
        ground += contrib * (1.0 - t);
      }
    }
    out[i] = total > 1e-12 ? (ground / total).clamp(0.0, 1.0) : 0.0;
  }
  return out;
}

/// 1/r²（内联，避免多次除法）
double inv2(double r2) => 1.0 / math.max(r2, 1e-12);

/// 房间的等效漫反射率（**面积加权 + 扣除窗洞**）：
///   ρ̄ = Σρ_i·A_i / ΣA_i
///
/// 缺省按常见室内装修取：白墙 0.75、顶棚 0.80、水泥地 0.25；窗洞是"黑体
/// 端口"（把光漏到室外），从反射面积中扣除。旧实现直接把整个房间写死一个
/// 0.55（"白灰墙面 + 水泥地"），深色装修（木地板、深色墙）的房间会被错误
/// 提亮、对比度被摊平。
double roomAlbedoAreaWeighted({
  double wallAlbedo = 0.75,
  double ceilingAlbedo = 0.80,
  double floorAlbedo = 0.25,
  double roomW = 5.0,
  double roomH = 3.0,
  double roomD = 4.5,
  double windowArea = 1.8,
}) {
  final aFloor = roomW * roomD;
  final aCeil = roomW * roomD;
  final aWalls = 2 * (roomW * roomH) + 2 * (roomD * roomH);
  final wNet = math.max(0.0, aWalls - windowArea);
  final num = floorAlbedo * aFloor + ceilingAlbedo * aCeil + wallAlbedo * wNet;
  final den = aFloor + aCeil + wNet;
  return den > 1e-9 ? (num / den).clamp(0.0, 0.95) : kRoomAlbedo;
}

/// 室内多次互反射的"均匀底"：k = ρ/(1−ρ)。
///
/// ρ=0.55 的白灰房间 → k ≈ 1.22：光在墙面/地面之间反复弹射，
/// 形成一层近似全房间均匀的照度底。
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
  List<double>? toSun,
  double sunAltDeg = 45.0,
  double beamToDiffuse = 0.0,
  double groundAlbedo = kGroundAlbedoDry,
  double cloudCover = 0.0,
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
        final y0 = (y * sh).floor().clamp(0, height - 1);
        final y1 = (((y + 1) * sh).ceil()).clamp(y0 + 1, height);
        for (var x = 0; x < ww; x++) {
          final x0 = (x * sw).floor().clamp(0, width - 1);
          final x1 = (((x + 1) * sw).ceil()).clamp(x0 + 1, width);
          final di = (y * ww + x);
          // 块内**面积平均**（旧实现取块左上角最近邻，且用单点决定整块
          // valid，会在窗边留下半像素偏移与块状伪影）
          var px = 0.0, py = 0.0, pz = 0.0, vv = 0.0;
          var c = 0;
          for (var sy = y0; sy < y1; sy++) {
            for (var sx = x0; sx < x1; sx++) {
              final si = sy * width + sx;
              px += pts[si * 3];
              py += pts[si * 3 + 1];
              pz += pts[si * 3 + 2];
              vv += valid[si];
              c++;
            }
          }
          final inv = c > 0 ? 1.0 / c : 0.0;
          subPts[di * 3] = px * inv;
          subPts[di * 3 + 1] = py * inv;
          subPts[di * 3 + 2] = pz * inv;
          subValid[di] = vv * inv;
        }
      }
      final low = _fieldFrom(subPts, subValid, scene, ww, wh, toSun, sunAltDeg, beamToDiffuse);
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
  return _fieldFrom(
      pts, valid, scene, width, height, toSun, sunAltDeg, beamToDiffuse);
}

/// 照度场合成：窗口直入 + 互反射。
///
/// **互反射不是常数底，而是一阶 Radiosity 近似**：
///     E_total = E_window + ρ/(1−ρ) · ⟨E_window⟩_room
/// 其中 ⟨⟩_room 是直入场在**房间尺度**上的低频版本 —— 光在室内多次弹射后
/// 细节被抹平，但"离窗远近"的大尺度结构保留下来（靠窗处互反射同样更强）。
///
/// 早期实现用 `(e + k)/(1+k)` 把常数 k 直接混进去：直入的空间对比度被
/// 摊薄一半以上，环境场于是退化成一片平灰，直射光斑像"贴"在上面。
///
/// 最后仍归一化到均值 1：绝对量级由 ambScale 决定，本函数只负责**相对分布**。
Float64List _fieldFrom(Float64List pts, Float64List valid, Scene3D scene,
    int width, int height, List<double>? toSun, double sunAltDeg,
    double beamToDiffuse) {
  final e = apertureIlluminance(pts, valid, scene,
      toSun: toSun, sunAltDeg: sunAltDeg, beamToDiffuse: beamToDiffuse);
  // 等效墙面反射率：面积加权 + 扣窗洞（不再是写死的 0.55）
  final k = interreflectionFloor(roomAlbedoAreaWeighted(
    roomW: scene.cfg.roomW,
    roomH: scene.cfg.roomH,
    roomD: scene.cfg.roomD,
  ));

  // 弹射的模糊半径 = 房间的**平均弦长**（∈ 均值自由程，4V/S），而不是一个
  // 写死的"房间深度的 30%"：4·V/S 是辐射传输中房间尺度的天然长度。
  final Float32List bounced;
  if (width > 0 && height > 0) {
    final pxPerMeter = height / math.max(scene.cfg.roomH, 0.1);
    final vol = scene.cfg.roomW * scene.cfg.roomH * scene.cfg.roomD;
    final surf = 2 *
        (scene.cfg.roomW * scene.cfg.roomD +
            scene.cfg.roomW * scene.cfg.roomH +
            scene.cfg.roomD * scene.cfg.roomH);
    final meanChord = surf > 1e-6 ? 4.0 * vol / surf : scene.cfg.roomD * 0.3;
    final rPx =
        (meanChord * pxPerMeter).clamp(1.0, math.min(width, height) * 0.5);
    bounced = blurGray(
        Float32List.fromList(e.map((v) => v.toDouble()).toList()),
        width,
        height,
        rPx);
  } else {
    bounced = Float32List.fromList(e);
  }

  final out = Float64List(e.length);
  var sum = 0.0;
  var cnt = 0;
  for (var i = 0; i < e.length; i++) {
    final v = e[i] + k * bounced[i];
    out[i] = v;
    if (valid[i] > 0) {
      sum += v;
      cnt++;
    }
  }
  final norm = (cnt > 0 && sum > 1e-12) ? cnt / sum : 1.0;
  for (var i = 0; i < out.length; i++) {
    out[i] = out[i] * norm;
  }
  return out;
}

// 说明：旧实现另有 `airlightFraction(pathM)`（用消光系数冒充"空气光占比"，
// 全仓库仅在测试中被调用）——真正的空气光是 β_s·ω₀·p(θ) 沿光路的积分且应逐
// 波段，室内几米的光程下对画面无可查影响，属死代码，已删除。

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

// ═══════════════════════════════════════════════════════════════════
// 窗玻璃：Fresnel 角依赖透射
// ═══════════════════════════════════════════════════════════════════

/// 普通窗玻璃折射率（钠钙玻璃 ≈ 1.52）。
const double kGlassIor = 1.52;

/// 普通钠钙浮法玻璃（含铁）的**光谱选择性吸收**（乙类⑦，默认启用）：
/// 透过率在 550 nm（绿）处最高，红端（Fe²⁺ 近红外尾延伸入可见）与蓝端
/// （Fe³⁺ 电荷转移）各低约 4~6% → 玻璃厚侧看呈绿色、透射光微偏绿。
/// 归一化到绿通道（保持总能量不变），这是室内直射光斑偏冷绿的物理来源。
/// Low-E/超白玻璃可近似取 1（无选择吸收）。
const glassTint = <double>[0.955, 1.0, 0.965]; // R,G,B 相对透过率

/// 垂直入射的界面反射率 F0 = ((n−1)/(n+1))² ≈ 0.0426（n = 1.52）。
double get kGlassF0 {
  final r = (kGlassIor - 1.0) / (kGlassIor + 1.0);
  return r * r;
}

/// 单界面 Fresnel 反射率的**逐偏振分量**（精确解，非近似）。
///
/// 返回 (Rs, Rp)：s 偏振与 p 偏振的反射率。
///   Snell: sinθt = sinθi / n
///   Rs = |(cosθi − n·cosθt)/(cosθi + n·cosθt)|²
///   Rp = |(n·cosθi − cosθt)/(n·cosθi + cosθt)|²
///
/// 早期实现用 Schlick 近似 `F0+(1−F0)(1−cosθ)^5`：它在 Fresnel 曲线的
/// **拐点**（cosθ ≈ 0.086，恰好落在掠射区）误差最大，|ΔR| ≤ 0.0345，
/// 使掠射透射率偏低 13~15% —— 而低太阳角正是本产品的核心场景。
(double, double) fresnelComponents(double cosTheta, double ior) {
  final c = cosTheta.clamp(0.0, 1.0);
  if (c <= 0.0) return (1.0, 1.0);
  final sin2t = (1.0 - c * c) / (ior * ior);
  final ct = math.sqrt(math.max(0.0, 1.0 - sin2t));
  final rs = (c - ior * ct) / (c + ior * ct);
  final rp = (ior * c - ct) / (ior * c + ct);
  return (rs * rs, rp * rp);
}

/// 单界面 Fresnel 反射率（非偏振，按强度平均）。
double glassReflectance(double cosTheta, {double ior = kGlassIor}) {
  final (rs, rp) = fresnelComponents(cosTheta, ior);
  return 0.5 * (rs + rp);
}

/// **双面玻璃板的总透射率**（两个界面的多次反射按几何级数求和）。
///
/// 真实窗户是两片"空气-玻璃"界面：光进入时反射一次、穿出时再反射一次，
/// 中间的多次来回反射求和：
///     T = (1−R)² / (1 − R²) = (1−R)/(1+R)
///
/// 该式对**每个偏振分量分别成立**（两界面入射角相同 ⇒ 反射率相同），
/// 因此必须逐偏振算 T 再按强度平均，而不是先把 R 平均再代公式 ——
/// 后者在掠射区又引入 −13~15% 的相对误差。
///
/// 这条曲线是**低太阳角时窗户会变暗**的物理原因：
///   cosθ=1.00 → 几乎全透（T≈0.918）
///   cosθ=0.20 → 约一半被反射掉
///   cosθ=0.05 → 几乎全反射（T≈0.14）
double glassTransmittance(double cosTheta, {double ior = kGlassIor}) {
  final c = cosTheta.clamp(0.0, 1.0);
  if (c <= 0.0) return 0.0;
  final (rs, rp) = fresnelComponents(c, ior);
  final ts = (1.0 - rs) / (1.0 + rs);
  final tp = (1.0 - rp) / (1.0 + rp);
  return (0.5 * (ts + tp)).clamp(0.0, 1.0);
}

/// **中空双玻**（双层玻璃，现代窗默认）的总透射。
///
/// 两片平行玻璃 + 空气夹层：每片各有两个界面（外侧/内侧），四个界面串联。
/// 因各片入射角相同（平行板），单片双界面透射 T1 = (1−R)/(1+R)（原函数），
/// 两片总透射为**逐偏振串联**：
///   T_total = T1² / (1 + R²·T1²·(1/(1-R²)) ...)  —— 精确式含片间多次反射。
/// 平行板间多次反射使透射**略高于**单板平方（被反射的光仍有一半机会再进）：
///   T = T1² / (1 − R²)，
/// 其中 R 为单界面反射率（非偏振平均）。该式在小掠射时自动趋于
/// T1²/(1−R²) → 高于单板值，符合能量守恒上限（全反射时多板不再叠加损耗）。
///
/// 对比：单玻 T≈0.918（法向），双玻 T≈0.848（法向）→ 室内直射**系统性
/// 低约 8%**，这正是"真实现代窗户更暗"的物理原因。
double doubleGlassTransmittance(double cosTheta, {double ior = kGlassIor}) {
  final c = cosTheta.clamp(0.0, 1.0);
  if (c <= 0.0) return 0.0;
  final (rs, rp) = fresnelComponents(c, ior);
  // 单片双界面（原 glassTransmittance 的逐偏振值）
  final t1s = (1.0 - rs) / (1.0 + rs);
  final t1p = (1.0 - rp) / (1.0 + rp);
  // 两片串联 + 片间多次反射修正：T2 = T1²/(1−R²)，R 取非偏振平均
  final rAvg = 0.5 * (rs + rp);
  final denom = 1.0 - rAvg * rAvg;
  final ts = t1s * t1s / denom;
  final tp = t1p * t1p / denom;
  return (0.5 * (ts + tp)).clamp(0.0, 1.0);
}

/// 窗户对**观察墙**的双余弦面积积分，在墙面上的均值：
///   Ĝ = ⟨ ∫∫_窗 cosθ_win·cosθ_wall / r² dA ⟩_wall
///
/// 这是"把均值归一化的孔径照度场还原成有量纲照度"的正确因子。
///
/// 物理（F1 的修正）：墙点照度 E_wall(P) = L_win·Ĝ(P)，其中
/// L_win（窗外辐亮度）= E_sky/I_h（朗伯天空时 I_h = π，CIE 晴空时 I_h > π）。
/// 于是
///   E_wall = E_sky · (Ĝ / I_h)。
/// 旧实现把还原因子写成"窗对墙点的**立体角** Ω = A·cosθ/d²"（再除 π），
/// 这对小而远的窗才近似成立：默认几何下 Ω/π = 0.0557，而正确的 Ĝ/I_h ≈
/// 0.0186 → 环境光被系统性抬高 **3.0×（1.58 EV）**，且与太阳高度角无关
/// （傍晚同样过亮）。Ĝ 与 I_h 都是"同一加权"下的几何量，比值才有意义。
double doubleCosineIntegralMean(Scene3D scene, {int nu = 16, int nv = 10}) {
  final pl = scene.placement();
  final u0 = math.min(pl.u0, pl.u1), u1 = math.max(pl.u0, pl.u1);
  final v0 = math.min(pl.v0, pl.v1), v1 = math.max(pl.v0, pl.v1);
  final plane = pl.planeCoord;
  final halfW = scene.cfg.roomW * 0.5;
  final hMax = scene.cfg.roomH;
  final dA = (u1 - u0) / nu * (v1 - v0) / nv;
  final eastWest = pl.wall == Wall.east || pl.wall == Wall.west;
  var sum = 0.0;
  var cnt = 0;
  for (var iy = 0; iy < nv; iy++) {
    final py = (iy + 0.5) / nv * hMax;
    for (var ix = 0; ix < nu; ix++) {
      final px = -halfW + (ix + 0.5) / nu * (2 * halfW);
      var acc = 0.0;
      for (var si = 0; si < nu; si++) {
        final u = u0 + (u1 - u0) * (si + 0.5) / nu;
        for (var sj = 0; sj < nv; sj++) {
          final v = v0 + (v1 - v0) * (sj + 0.5) / nv;
          double dx, dy, dz, cosWin;
          if (eastWest) {
            dx = plane - px;
            dy = v - py;
            dz = u; // 墙点 z = 0
            cosWin = dx.abs();
          } else {
            dx = u - px;
            dy = v - py;
            dz = plane;
            cosWin = dz.abs();
          }
          final r2 = dx * dx + dy * dy + dz * dz;
          final r = math.sqrt(math.max(r2, 1e-9));
          final cosWall = dz.abs() / r; // 观察墙法线 +Z
          acc += dA * (cosWin / r) * cosWall * inv2(r2);
        }
      }
      sum += acc;
      cnt++;
    }
  }
  return cnt > 0 ? sum / cnt : 1.0;
}

/// 窗户对观察墙的**典型立体角**（球面度）。仅保留给调试/回归对照；
/// 环境光量级还原**不再使用它**（见 [doubleCosineIntegralMean]）。
double typicalWindowSolidAngle(Scene3D scene) {
  final pl = scene.placement();
  final aWin = (pl.u1 - pl.u0).abs() * (pl.v1 - pl.v0).abs();
  final d = scene.typicalWindowToWallDistance();
  // 窗心 → 观察墙中心 的方向
  final wx = pl.wall == Wall.back ? pl.uCenter : pl.planeCoord;
  const wallCx = 0.0;
  final wz = pl.wall == Wall.back ? pl.planeCoord : pl.uCenter;
  final tx = wallCx - wx;
  final ty = scene.cfg.cameraH - pl.vCenter;
  final tz = 0.0 - wz;
  final len = math.sqrt(tx * tx + ty * ty + tz * tz);
  final nrm = scene.windowOutwardNormal();
  final cosT =
      ((tx * nrm[0] + ty * nrm[1] + tz * nrm[2]) / math.max(len, 1e-6)).abs();
  return aWin * cosT / math.max(d * d, 1e-6);
}

/// **场景曝光适应**：由**画面中位亮度**决定，带部分适应特性。
///
/// 与旧的 [eyeExposureEv]（已删除）的区别：后者用"入射照度"作输入并按太阳
/// 高度角淡出增益；真实相机测光、人眼适应依据的是**成像面上的亮度统计**。
///
/// 两点修正（报告 I4）：
///   · 测光统计量用**中位数**（相机中央加权测光 / 18% 灰卡的精神：算术均值
///     最容易被高光拉爆，光斑面积稍变画面就整体漂移）。调用方传入已算好的
///     中位亮度。
///   · 去掉了"由本工程光照模型标定"的 refLum 常数：旧式
///     `EV = target·L^(γ−1)·refLum^(−γ)` 把曝光锁死在某一个光照模型上
///     （模型一变就得重调 refLum）。这里改成以**显示中灰**为锚的部分适应
///     `EV = (target/L)^adapt`，无拟合常数。
///
/// `adapt = 0.73` 由 Stevens 幂律（主观亮度 ∝ L^0.33）与显示 EOTF（γ≈2.2）
/// 合成；因后级是 ACES（非幂律），这是近似 —— 精确的部分适应需要相机模型，
/// 属产品决策（见待决策）。
double sceneExposureEv(double frameLum,
    {double target = kDisplayMidGray, double adapt = 0.73}) {
  if (frameLum <= 1e-12) return 1.0;
  final a = adapt.clamp(0.2, 1.0);
  final ev = math.pow(target / frameLum, a).toDouble();
  return ev.clamp(0.02, 5000.0);
}

/// 显示中灰（线性显示值 0.18，对应 18% 灰卡 / ISO 2720）。
const double kDisplayMidGray = 0.18;
