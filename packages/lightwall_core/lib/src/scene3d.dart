// 3D 房间、相机与窗户几何
//
// 相比参考实现的关键修正（"算法瑕疵在新项目修复"）：
//   · 参考实现只把窗户朝向分 left/right 两支，其余 8 个罗盘朝向
//     （n/ne/e/se/s/sw/w/nw）全部落到 else 分支被当成"西向窗"，
//     于是"西北向窗"与"西向窗"渲染结果完全一样。
//   · 本项目改为**通用墙面模型**：窗户可落在东/西/后（背对相机）三面墙，
//     由窗户方位角与观察墙方位角共同决定，任意罗盘朝向都真实生效。
//
// 坐标系（房间 = 世界，右手系，+Y 朝上）：
//   规范房间：观察墙位于 z = 0（内法线 +Z），房间向 +Z 延伸至 roomD。
//   地理由"观察墙内法线方位角 viewWallAz"把真实方位角旋转到规范系：
//       规范方位角 = 地理方位角 + 180° − viewWallAz
import 'dart:math' as math;
import 'dart:typed_data';

import 'astro.dart';

/// 窗户所在墙。
enum Wall {
  /// 东墙：x = +roomW/2，外法线朝东（规范方位角 90°）
  east,

  /// 西墙：x = −roomW/2，外法线朝西（规范方位角 270°）
  west,

  /// 后墙：z = +roomD，外法线朝南（规范方位角 180°）—— 位于相机身后
  back,
}

/// 把方位角归一到 [0,360)。
double normAz(double az) {
  var a = az % 360.0;
  if (a < 0) a += 360.0;
  return a;
}

/// 两方位角的最小夹角（0~180°）。
double azDelta(double a, double b) {
  var d = (a - b) % 360.0;
  if (d < 0) d += 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

/// 3D 场景参数（对应参考实现 lighting.json 的 scene 段）。
class SceneConfig {
  SceneConfig({
    this.roomW = 5.0,
    this.roomH = 3.0,
    this.roomD = 4.5,
    this.windowW = 1.2,
    this.windowH = 1.5,
    this.windowCy = 2.05,
    this.windowCz = -0.9,
    this.gridRows = 3,
    this.gridCols = 2,
    this.gridFrameRatio = 0.10,
    this.cameraH = 1.25,
    this.cameraDist = 3.0,
    this.cameraFovDeg = 50.0,
  });

  final double roomW;
  final double roomH;
  final double roomD;

  /// 窗宽（米，沿墙面水平方向）。
  final double windowW;

  /// 窗高（米）。
  final double windowH;

  /// 窗心高度（米）。
  final double windowCy;

  /// 窗心相对墙中线的水平偏移（米）。留 −0.5 与参考实现一致：
  /// 窗户偏向观察墙一侧，斜射光束才能扫进画面。
  final double windowCz;

  final int gridRows;
  final int gridCols;

  /// 窗框宽度 / 窗格短边。
  final double gridFrameRatio;

  final double cameraH;
  final double cameraDist;
  final double cameraFovDeg;

  SceneConfig copyWith({
    int? gridRows,
    int? gridCols,
    double? gridFrameRatio,
    double? windowW,
    double? windowH,
    double? cameraFovDeg,
    double? cameraH,
    double? cameraDist,
    double? windowCy,
    double? windowCz,
    double? roomW,
    double? roomD,
  }) =>
      SceneConfig(
        roomW: roomW ?? this.roomW,
        roomH: roomH,
        roomD: roomD ?? this.roomD,
        windowW: windowW ?? this.windowW,
        windowH: windowH ?? this.windowH,
        windowCy: windowCy ?? this.windowCy,
        windowCz: windowCz ?? this.windowCz,
        gridRows: gridRows ?? this.gridRows,
        gridCols: gridCols ?? this.gridCols,
        gridFrameRatio: gridFrameRatio ?? this.gridFrameRatio,
        cameraH: cameraH ?? this.cameraH,
        cameraDist: cameraDist ?? this.cameraDist,
        cameraFovDeg: cameraFovDeg ?? this.cameraFovDeg,
      );
}

/// 窗户在墙上的位置（抽象出横向 u / 纵向 v 两个轴）。
class WindowPlacement {
  WindowPlacement({
    required this.wall,
    required this.u0,
    required this.u1,
    required this.v0,
    required this.v1,
    required this.planeCoord,
  });

  final Wall wall;

  /// 横向范围：东/西墙为 z，后墙为 x。
  final double u0;
  final double u1;

  /// 纵向范围（y）。
  final double v0;
  final double v1;

  /// 墙面在法线轴上的坐标。
  final double planeCoord;

  double get uCenter => (u0 + u1) * 0.5;
  double get vCenter => (v0 + v1) * 0.5;
}

/// 房间 + 相机 + 窗户。
class Scene3D {
  Scene3D(this.cfg, double windowAz, {double? viewWallAz})
      : windowAz = normAz(windowAz),
        viewWallAz = normAz(viewWallAz ?? chooseViewWall(windowAz)) {
    winWall = _wallForWindow(this.windowAz, this.viewWallAz);
  }

  final SceneConfig cfg;

  /// 窗户朝向（地理方位角，度）。
  final double windowAz;

  /// 观察墙内法线方位角（度）。
  final double viewWallAz;

  /// 窗户所在墙（由前两者推导）。
  late final Wall winWall;

  int _imgW = 0;
  int _imgH = 0;

  double get aspect => _imgH == 0 ? 1.0 : _imgW / _imgH;

  /// 相机位置（房间坐标）。
  List<double> get camPos => <double>[0.0, cfg.cameraH, cfg.cameraDist];

  /// 地理方位角 → 规范房间方位角。
  double toRoomAz(double geoAz) => normAz(geoAz + 180.0 - viewWallAz);

  /// 观察墙内法线（房间坐标，恒为 +Z）。
  static const List<double> viewNormal = <double>[0, 0, 1];

  /// 太阳光线方向（从太阳射向房间），房间坐标。
  List<double> sunToRoomDir(double sunAzGeo, double sunAlt) {
    final az = toRoomAz(sunAzGeo) * kDeg;
    final alt = sunAlt * kDeg;
    final cosAlt = math.cos(alt);
    final toSun = <double>[
      math.sin(az) * cosAlt,
      math.sin(alt),
      -math.cos(az) * cosAlt,
    ];
    return <double>[-toSun[0], -toSun[1], -toSun[2]];
  }

  void setImageSize(int w, int h) {
    _imgW = w;
    _imgH = h;
  }

  /// 批量生成相机射线：返回 (origins, points 用 dirs)，均为 Float64List。
  (Float64List, Float64List) screenToRayBatch(int w, int h) {
    setImageSize(w, h);
    final origins = Float64List(w * h * 3);
    final dirs = Float64List(w * h * 3);
    final cam = camPos;
    final tanHalf = math.tan(cfg.cameraFovDeg * 0.5 * kDeg);
    final asp = w / h;
    final denomX = (w - 1) == 0 ? 1 : (w - 1);
    final denomY = (h - 1) == 0 ? 1 : (h - 1);
    for (var y = 0; y < h; y++) {
      final ny = 1.0 - 2.0 * y / denomY;
      for (var x = 0; x < w; x++) {
        final nx = 2.0 * x / denomX - 1.0;
        var dx = nx * tanHalf * asp;
        final dy = ny * tanHalf;
        const dz = -1.0;
        final inv = 1.0 / math.sqrt(dx * dx + dy * dy + dz * dz);
        dx *= inv;
        final dy2 = dy * inv;
        final dz2 = dz * inv;
        final i = (y * w + x) * 3;
        origins[i] = cam[0];
        origins[i + 1] = cam[1];
        origins[i + 2] = cam[2];
        dirs[i] = dx;
        dirs[i + 1] = dy2;
        dirs[i + 2] = dz2;
      }
    }
    return (origins, dirs);
  }

  /// 射线与观察墙（z = 0）求交。返回 (命中掩码, 交点)。
  (Float64List, Float64List) rayWallIntersectBatch(
      Float64List origins, Float64List dirs) {
    final n = dirs.length ~/ 3;
    final hitMask = Float64List(n);
    final pts = Float64List(n * 3);
    for (var i = 0; i < n; i++) {
      final o3 = i * 3;
      final dz = dirs[o3 + 2];
      if (dz.abs() <= 1e-9) continue;
      final t = -origins[o3 + 2] / dz;
      if (t <= 0) continue;
      hitMask[i] = 1.0;
      pts[o3] = origins[o3] + t * dirs[o3];
      pts[o3 + 1] = origins[o3 + 1] + t * dirs[o3 + 1];
      pts[o3 + 2] = 0.0;
    }
    return (hitMask, pts);
  }

  /// 窗户在墙面上的范围。
  WindowPlacement placement() {
    final halfW = cfg.windowW * 0.5;
    final halfH = cfg.windowH * 0.5;
    final v0 = cfg.windowCy - halfH;
    final v1 = cfg.windowCy + halfH;
    switch (winWall) {
      case Wall.east:
      case Wall.west:
        final center = cfg.roomD * 0.5 + cfg.windowCz;
        return WindowPlacement(
          wall: winWall,
          u0: center - halfW,
          u1: center + halfW,
          v0: v0,
          v1: v1,
          planeCoord: winWall == Wall.east ? cfg.roomW * 0.5 : -cfg.roomW * 0.5,
        );
      case Wall.back:
        return WindowPlacement(
          wall: Wall.back,
          u0: cfg.windowCz - halfW,
          u1: cfg.windowCz + halfW,
          v0: v0,
          v1: v1,
          planeCoord: cfg.roomD,
        );
    }
  }

  /// 窗格净区域判定：相对坐标 (u,v) ∈ [0,1]² 是否落在玻璃区（非窗框）。
  bool inGlassArea(double uRel, double vRel) {
    final pl = placement();
    final spanU = (pl.u1 - pl.u0).abs();
    final spanV = (pl.v1 - pl.v0).abs();
    final cols = math.max(1, cfg.gridCols);
    final rows = math.max(1, cfg.gridRows);
    final cellU = spanU / cols;
    final cellV = spanV / rows;
    final cellShort = math.min(cellU, cellV);
    final frame = cfg.gridFrameRatio * cellShort;
    final half = frame * 0.5;

    var uPhys = uRel * spanU;
    var vPhys = vRel * spanV;
    final col =
        (uPhys / (cellU <= 0 ? 1e-6 : cellU)).floor().clamp(0, cols - 1);
    final row =
        (vPhys / (cellV <= 0 ? 1e-6 : cellV)).floor().clamp(0, rows - 1);
    uPhys -= col * cellU;
    vPhys -= row * cellV;
    return uPhys >= half &&
        uPhys <= cellU - half &&
        vPhys >= half &&
        vPhys <= cellV - half;
  }

  /// 批量判定：从墙点 P 沿"朝向太阳"的方向追到窗户平面，是否穿窗。
  ///
  /// [sunDir] 为"太阳射向房间"的方向，对 P 求太阳方向需取负。
  /// [penumbra] 为半影采样半径（相对窗宽），0 表示硬边。
  Float64List windowVisibilityBatch(
    Float64List pts,
    List<double> sunDir, {
    double penumbra = 0.0,
  }) {
    final n = pts.length ~/ 3;
    final out = Float64List(n);
    final toSun = <double>[-sunDir[0], -sunDir[1], -sunDir[2]];
    final samples = penumbra <= 1e-6 ? 1 : 5;
    // 5 点采样：中心 + 沿太阳角直径方向的两对偏移
    for (var i = 0; i < n; i++) {
      final o = i * 3;
      var acc = 0.0;
      for (var s = 0; s < samples; s++) {
        final ox = s == 0 ? 0.0 : 0.0;
        final oy = s == 0 ? 0.0 : 0.0;
        if (_visibleThroughWindow(pts, o, toSun, ox, oy, penumbra, s))
          acc += 1.0;
      }
      out[i] = acc / samples;
    }
    return out;
  }

  bool _visibleThroughWindow(Float64List pts, int o, List<double> toSun,
      double ox, double oy, double penumbra, int sample) {
    final pl = placement();
    final px = pts[o], py = pts[o + 1], pz = pts[o + 2];
    double u, v;
    if (pl.wall == Wall.east || pl.wall == Wall.west) {
      final lx = toSun[0];
      if (lx.abs() < 1e-9) return false;
      final t = (pl.planeCoord - px) / lx;
      if (t <= 0) return false;
      u = pz + t * toSun[2];
      v = py + t * toSun[1];
    } else {
      final lz = toSun[2];
      if (lz.abs() < 1e-9) return false;
      final t = (pl.planeCoord - pz) / lz;
      if (t <= 0) return false;
      u = px + t * toSun[0];
      v = py + t * toSun[1];
    }
    if (penumbra > 1e-6) {
      // 半影：在窗面上按太阳角直径做小范围抖动采样
      final r = penumbra * (pl.u1 - pl.u0);
      if (sample == 1) u += r;
      if (sample == 2) u -= r;
      if (sample == 3) v += r;
      if (sample == 4) v -= r;
    }
    if (u < pl.u0 || u > pl.u1 || v < pl.v0 || v > pl.v1) return false;
    final uRel = (u - pl.u0) / math.max(pl.u1 - pl.u0, 1e-6);
    final vRel = (v - pl.v0) / math.max(pl.v1 - pl.v0, 1e-6);
    return inGlassArea(uRel, vRel);
  }

  /// 窗户外法线（房间坐标，指向窗外）。
  List<double> windowOutwardNormal() {
    switch (winWall) {
      case Wall.east:
        return <double>[1, 0, 0];
      case Wall.west:
        return <double>[-1, 0, 0];
      case Wall.back:
        return <double>[0, 0, 1];
    }
  }

  /// 窗面法线方位角（规范系）。
  double get windowNormalAzRoom {
    switch (winWall) {
      case Wall.east:
        return 90.0;
      case Wall.west:
        return 270.0;
      case Wall.back:
        return 180.0;
    }
  }

  // ─────────────────────────── 选择规则 ───────────────────────────

  static Wall _wallForWindow(double windowAz, double viewWallAz) {
    final canonical = normAz(windowAz + 180.0 - viewWallAz);
    if (azDelta(canonical, 90.0) <= 45.0) return Wall.east;
    if (azDelta(canonical, 270.0) <= 45.0) return Wall.west;
    return Wall.back;
  }

  /// 由窗户朝向选择观察墙：
  ///   · 东西向窗户 → 选与之垂直、且朝南的那面墙（保留参考实现的斜切长光斑）
  ///   · 南北向窗户 → 垂直墙接不到直射，改为正对窗户的对面墙
  static double chooseViewWall(double windowAz) {
    final w = normAz(windowAz);
    // 与"东西方向"的偏离（取离东/西更近的那个）
    final devE = azDelta(w, 90.0);
    final devW = azDelta(w, 270.0);
    final dev = devE < devW ? devE : devW;
    if (dev > 45.0) return normAz(w + 180.0);
    final a = normAz(w + 90.0);
    final b = normAz(w - 90.0);
    return azDelta(a, 180.0) <= azDelta(b, 180.0) ? a : b;
  }
}
