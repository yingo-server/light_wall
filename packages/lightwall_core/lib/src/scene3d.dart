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

const double _kTwoPi = 2.0 * math.pi;

/// 1/φ = (√5−1)/2，黄金比共轭。用作低差异方位序列（数学常数，非调参）。
const double _kGoldenRatioConj = 0.6180339887498949;

/// 方向空间锥采样的样本数。
///
/// 为什么是**固定** 64 而不按半影宽度分档（旧实现的 5/9/17）：
/// 分档会把"量化级数"绑到与半影无关的量上（窗宽、代表距离），正午
/// `penumbra ≈ 0.0085` 恰落入 5 样本档 ⟹ 可见比例只有 6 级、半影带出现
/// 等高线台阶；而框宽/距离一变又跳到别的档。固定 64 后台阶宽度
/// < 0.2 px（远小于 1 px），且与窗宽、距离、窗格数全部解耦。
/// 成本由两条精确早退兜住：绝大多数像素（光斑内部、窗洞之外）只用 1 次
/// 求交，只有真正跨窗框边缘的窄带像素才付 64 次。
const int _kConeSamples = 64;

/// 日面临边昏暗系数（Eddington 灰体近似 / 可见带的经验值 u ≈ 0.6）：
/// I(μ)/I(1) ≈ 1 − u(1 − μ)，μ 为日面点到日心方向夹角的余弦。
/// 出处：Eddington (1926) 灰体近似给出 u = 0.6；Claret (2000) 对可见带的
/// 太阳临边昏暗拟合亦给出 u ≈ 0.55–0.65。取 0.6 不计日面"均匀亮盘"。
const double _kLimbDarkeningU = 0.6;

/// 3D 场景参数（对应参考实现 lighting.json 的 scene 段）。
///
/// 【默认值依据】（报告 scene3d[18]）默认值取一间"真实小卧室"的量测：
/// 房间 5.0×3.0×4.5 m、窗 1.2×1.5 m（窗台 0.9 m、窗心高 2.05 m）、
/// 相机高 1.25 m（站姿眼高）、垂直 FOV 50°。其中：
///   · `windowCz = −0.9` 是**构图参数**（让斜射光束扫进画面），无建筑依据；
///     若要物理化，应由"窗在墙上的真实偏心"给出（待决策）。
///   · `cameraDist/roomW/FOV` 恰好让水平视场卡住房间宽度 —— 同样是取景选择，
///     不是物理量（相机应由"拍摄位置 + 焦距 + 传感器"给出）。
/// 这些量应尽可能来自真实房间/相机的量测或用户输入。
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
    this.outerFrameWidthM = 0.050,
    this.muntinWidthM = 0.025,
    this.cameraH = 1.25,
    this.cameraDist = 3.0,
    this.cameraFovDeg = 50.0,
    this.wallThicknessM = 0.30,
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

  /// 窗心相对墙中线的水平偏移（米）。
  ///
  /// 默认 −0.9（原文档写 "留 −0.5 与参考实现一致"，与代码默认值矛盾——
  /// 文档已按代码改正）。该偏移本身无物理出处：注释自陈目的是"让斜射光束
  /// 扫进画面"，即**构图参数**。
  /// TODO(待决策)：窗在墙上的偏心量应由"真实房间/窗位量测"或产品构图意图
  /// 给出（例如窗居中 0.0，或按建筑模数偏心），不应留一个无依据的 −0.9。
  final double windowCz;

  final int gridRows;
  final int gridCols;

  /// 【已废弃口径】窗框宽度 / 窗格短边。
  ///
  /// 只在 [outerFrameWidthM] / [muntinWidthM] 显式传 null 时作为兜底使用。
  /// 保留此字段仅为兼容既有调用方（pipeline.RenderSpec.gridFrameRatio）；
  /// 新代码请用绝对宽度。理由见 [outerFrameWidthM]。
  final double gridFrameRatio;

  /// 窗扇外框（窗洞四周可见边框）宽度，**绝对值（米）**。
  ///
  /// 物理量出处：住宅门窗型材可视面宽度 40–60 mm（GB/T 8478 铝合金门窗、
  /// 以及常见铝木复合扇框系列），取中值 50 mm。
  ///
  /// 旧实现用 `gridFrameRatio × 窗格短边`（无量纲比 × 取决于窗格数的长度），
  /// 于是"改窗格数就改了物理框宽"：3×2 网格（格 0.6×0.5）→ 50 mm，
  /// 3×3 网格（格 0.4×0.5）→ 40 mm，玻璃面积随之跳变约 10%。
  /// 框宽是**绝对长度**，与窗格数无关，故改为独立参数。
  final double? outerFrameWidthM;

  /// 中挺 / 格条可见宽度，**绝对值（米）**。
  ///
  /// 物理量出处：住宅窗玻璃格条（中挺、棂条）可视宽度 20–30 mm，取 25 mm。
  /// 相邻两扇玻璃之间的中挺总宽 = 本值（每侧各占一半），
  /// 与 [outerFrameWidthM]（窗洞四周外框）是两个独立的物理尺寸。
  final double? muntinWidthM;

  /// 相机高度（米）、到观察墙的距离（米）、**垂直**视场角（度）。
  ///
  /// FOV 口径：针孔相机的**垂直**半角 = fov/2（水平半角 = atan(tan(fov/2)·aspect)）。
  /// 16:9 下 50° 垂直 ≈ 81° 水平（等效 35mm 画幅约 20 mm 镜头，属室内广角）。
  /// 旧实现未注明口径；若参考的 50° 原意是水平/对角，整体视角会差 20~30°。
  final double cameraH;
  final double cameraDist;
  final double cameraFovDeg;

  /// 窗洞墙厚（米）——窗洞是穿过墙体的**隧道**（reveal），不是零厚度平面。
  ///
  /// 低太阳角时，阳光要穿过这段隧道才能进屋：入射角 α 时有效透光口在平行
  /// 光线上整体平移 d·tanα（d = 墙厚），α 大时被削掉的部分可达窗宽的可观
  /// 比例，甚至让光斑提前消失。旧实现把墙/窗框当作零厚度二维面，低太阳角
  /// （正是本产品的主场景）下光斑会一直延伸到不该出现的位置。
  /// 常见住宅外墙/窗洞深度 0.2~0.4 m，取 0.30 m。
  final double wallThicknessM;

  SceneConfig copyWith({
    int? gridRows,
    int? gridCols,
    double? gridFrameRatio,
    double? outerFrameWidthM,
    double? muntinWidthM,
    double? windowW,
    double? windowH,
    double? cameraFovDeg,
    double? cameraH,
    double? cameraDist,
    double? wallThicknessM,
    double? windowCy,
    double? windowCz,
    double? roomW,
    double? roomD,
    // roomH 此前写死为原值：`copyWith(roomH: …)` 会被静默忽略，用户无法
    // 把层高改成真实常见的 2.7 m。这里补齐（纯 API 缺口，非策略问题）。
    double? roomH,
  }) =>
      SceneConfig(
        roomW: roomW ?? this.roomW,
        roomH: roomH ?? this.roomH,
        roomD: roomD ?? this.roomD,
        windowW: windowW ?? this.windowW,
        windowH: windowH ?? this.windowH,
        windowCy: windowCy ?? this.windowCy,
        windowCz: windowCz ?? this.windowCz,
        gridRows: gridRows ?? this.gridRows,
        gridCols: gridCols ?? this.gridCols,
        gridFrameRatio: gridFrameRatio ?? this.gridFrameRatio,
        outerFrameWidthM: outerFrameWidthM ?? this.outerFrameWidthM,
        muntinWidthM: muntinWidthM ?? this.muntinWidthM,
        cameraH: cameraH ?? this.cameraH,
        cameraDist: cameraDist ?? this.cameraDist,
        cameraFovDeg: cameraFovDeg ?? this.cameraFovDeg,
        wallThicknessM: wallThicknessM ?? this.wallThicknessM,
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

  /// 画面宽高比。**只有在 [setImageSize] 之后才有意义**（此前静默返回 1.0）。
  /// 需要宽高比时应尽量由调用方显式传入 (w,h)，不要依赖这个隐式状态
  /// （报告 scene3d[21]：把状态混进几何对象、给出静默的错误默认值）。
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
    // 像素**中心**映射：(x+0.5)/w ∈ (0,1) → NDC ∈ (−1,1)，传感器物理边界
    // 对应 ±1。旧实现用 x/(w−1) 把视场定义在最外像素中心之间，等效焦距偏大
    // (w−1)/w（缩略/预览档可达 1.6%~2.8%）。
    for (var y = 0; y < h; y++) {
      final ny = 1.0 - 2.0 * (y + 0.5) / h;
      for (var x = 0; x < w; x++) {
        final nx = 2.0 * (x + 0.5) / w - 1.0;
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

  /// 射线与观察墙（z = 0）求交。
  ///
  /// 房间是 z=0 处的观察墙与侧墙 x=±roomW/2、地板 y=0、天花 y=roomH 围成的
  /// 有限矩形。本项目尚未建地板/天花的材质模型，故对越界射线**按墙点钳制**
  /// 后着色（而不是丢弃）：若丢弃，越界像素会走 tracer 的兜底分支，在夜间
  /// 大曝光下被放大成一条**横贯画面的亮带**（实测亮度 200 对墙面的 50）。
  /// 钳制相当于"墙延伸到画面下缘"，视觉上远小于亮带；地板建模列于待决。
  (Float64List, Float64List) rayWallIntersectBatch(
      Float64List origins, Float64List dirs) {
    final n = dirs.length ~/ 3;
    final hitMask = Float64List(n);
    final pts = Float64List(n * 3);
    final halfW = cfg.roomW * 0.5;
    final hMax = cfg.roomH;
    for (var i = 0; i < n; i++) {
      final o3 = i * 3;
      final dz = dirs[o3 + 2];
      if (dz.abs() <= 1e-9) continue;
      final t = -origins[o3 + 2] / dz;
      if (t <= 0) continue;
      final x = origins[o3] + t * dirs[o3];
      final y = origins[o3 + 1] + t * dirs[o3 + 1];
      hitMask[i] = 1.0;
      pts[o3] = x.clamp(-halfW, halfW);
      pts[o3 + 1] = y.clamp(0.0, hMax);
      pts[o3 + 2] = 0.0;
    }
    return (hitMask, pts);
  }

  /// 窗面到观察墙的**代表距离**（米）。
  ///
  /// 仅用于"只要求量级"的用途：窗口立体角量级（atmosphere.typicalWindowSolidAngle）
  /// 与旧口径参数换算（tracer 的 legacy penumbra 比例 → 光源角半径）。
  ///
  /// **半影计算已不再使用本函数**：半影半径是墙点 P 的局部量
  /// r(P) = t(P)·tan θ☉（t = P 沿太阳方向到窗平面的距离），逐点算成本为零
  /// （见 [windowVisibilityBatch]）。原先"全画面共用一个代表距离"的写法会让
  /// 近窗角软 23×、远角锐 2×（真实跨度 0.6 mm → 28 mm，相差 47×）。
  ///
  /// 旧实现末尾的 `.clamp(0.5, 50.0)` 是无出处的钳制（默认几何下 2.95 m，
  /// 从不触发，只在异常配置下把物理量替换成常数），已删除。
  double typicalWindowToWallDistance() {
    final pl = placement();
    final double dx, dz;
    if (pl.wall == Wall.east || pl.wall == Wall.west) {
      // 窗平面 x = planeCoord，窗的水平轴 u 是 z
      dx = pl.planeCoord; // 到观察墙 x = 0
      dz = pl.uCenter; // 窗的水平位置（z）到观察墙 z = 0
    } else {
      // 窗平面 z = roomD，窗的水平轴 u 是 x
      dx = pl.uCenter; // 窗的水平位置（x）到观察墙中线
      dz = pl.planeCoord; // 到观察墙 z = 0
    }
    final dy = pl.vCenter - cfg.cameraH;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  WindowPlacement placement() {
    final halfW = cfg.windowW * 0.5;
    final halfH = cfg.windowH * 0.5;
    // 窗必须落在墙内：把窗口矩形钳到墙面范围内（否则"墙外虚空"也会透光，
    // 出现无物理来源的亮区）。旧实现不做任何校验，copyWith 放大 windowH
    // 即可构造非法场景。
    final v0 = (cfg.windowCy - halfH).clamp(0.0, cfg.roomH);
    final v1 = (cfg.windowCy + halfH).clamp(0.0, cfg.roomH);
    switch (winWall) {
      case Wall.east:
      case Wall.west:
        final center = cfg.roomD * 0.5 + cfg.windowCz;
        return WindowPlacement(
          wall: winWall,
          u0: (center - halfW).clamp(0.0, cfg.roomD),
          u1: (center + halfW).clamp(0.0, cfg.roomD),
          v0: v0,
          v1: v1,
          planeCoord: winWall == Wall.east ? cfg.roomW * 0.5 : -cfg.roomW * 0.5,
        );
      case Wall.back:
        final halfRoom = cfg.roomW * 0.5;
        return WindowPlacement(
          wall: Wall.back,
          u0: (cfg.windowCz - halfW).clamp(-halfRoom, halfRoom),
          u1: (cfg.windowCz + halfW).clamp(-halfRoom, halfRoom),
          v0: v0,
          v1: v1,
          planeCoord: cfg.roomD,
        );
    }
  }

  /// 玻璃净区（窗格矩形列表，按 (u0,u1,v0,v1) 连续四元组排列）。
  ///
  /// 窗框宽度是**绝对长度参数**（[SceneConfig.outerFrameWidthM] 外框、
  /// [SceneConfig.muntinWidthM] 中挺），与窗格数解耦：旧实现取
  /// `gridFrameRatio × 窗格短边`，改窗格数就改了物理框宽（3×2 → 50 mm、
  /// 3×3 → 40 mm），玻璃面积随之跳变 ~10%，而框宽是固定的物理尺寸。
  /// 同时修掉"外圈边框只有内框中挺一半厚"的倒置：窗洞四周用
  /// [SceneConfig.outerFrameWidthM]，相邻窗格之间每侧各缩 [SceneConfig.muntinWidthM]/2
  /// （合计正好一个中挺宽度），两者相互独立。
  Float64List _glassPanes(WindowPlacement pl) {
    final spanU = (pl.u1 - pl.u0).abs();
    final spanV = (pl.v1 - pl.v0).abs();
    final cols = math.max(1, cfg.gridCols);
    final rows = math.max(1, cfg.gridRows);
    final cellU = spanU / cols;
    final cellV = spanV / rows;
    final u0 = math.min(pl.u0, pl.u1);
    final v0 = math.min(pl.v0, pl.v1);
    // 兜底（仅当调用方显式传 null 保留旧的"比例"口径）
    final cellShort = math.min(cellU, cellV);
    final legacy = cfg.gridFrameRatio * cellShort;
    final outer = cfg.outerFrameWidthM ?? legacy;
    final muntin = cfg.muntinWidthM ?? legacy;
    final halfM = muntin * 0.5;
    final panes = Float64List(cols * rows * 4);
    for (var r = 0; r < rows; r++) {
      final vLo = v0 + r * cellV + (r == 0 ? outer : halfM);
      final vHi = v0 + (r + 1) * cellV - (r == rows - 1 ? outer : halfM);
      for (var c = 0; c < cols; c++) {
        final uLo = u0 + c * cellU + (c == 0 ? outer : halfM);
        final uHi = u0 + (c + 1) * cellU - (c == cols - 1 ? outer : halfM);
        final k = (r * cols + c) * 4;
        panes[k] = uLo;
        panes[k + 1] = uHi;
        panes[k + 2] = vLo;
        panes[k + 3] = vHi;
      }
    }
    return panes;
  }

  static bool _inPanes(Float64List panes, double u, double v) {
    for (var k = 0; k < panes.length; k += 4) {
      if (u >= panes[k] && u <= panes[k + 1] && v >= panes[k + 2] &&
          v <= panes[k + 3]) {
        return true;
      }
    }
    return false;
  }

  /// 窗格净区域判定：相对坐标 (u,v) ∈ [0,1]² 是否落在玻璃区（非窗框）。
  bool inGlassArea(double uRel, double vRel) {
    final pl = placement();
    final panes = _glassPanes(pl);
    final u = math.min(pl.u0, pl.u1) + uRel * (pl.u1 - pl.u0).abs();
    final v = math.min(pl.v0, pl.v1) + vRel * (pl.v1 - pl.v0).abs();
    return _inPanes(panes, u, v);
  }

  /// 批量判定：从墙点 P 沿"朝向太阳"的方向追到窗户平面，是否穿窗。
  ///
  /// [sunDir] 为"太阳射向房间"的方向（对 P 求太阳方向需取负）。
  /// [sunAngularRadiusDeg] 为**光源（日面 + 环日散射）的角半径（度）**，
  /// 由外部天文/大气模块给出（缺省取 astro [sunAngularDiameterDeg] 的一半，
  /// 即几何日面）。本文件不自定义任何"角径放大"幂律。
  ///
  /// ## 物理模型（本次修正）
  /// 太阳不是点光源，墙点 P 看到的是**以太阳中心方向为轴、半顶角 θ☉ 的圆锥**
  /// 与窗平面的交线。因此：
  ///   · 半影半径是**局部量** `r(P) = t(P)·tan θ☉`（t = P 沿该方向到窗平面的
  ///     距离），本函数内部逐点算出 t 就地使用。旧实现在调用方用"全画面唯一
  ///     代表距离"换算成一个比例常数，等于把 0.6 mm（近窗角）到 28 mm（远角）
  ///     的 47× 变化抹平成一个 13.7 mm 常数（近窗软 23×、远角锐 2×）。
  ///   · 采样在**方向空间**做（球冠上面积均匀），足迹的椭圆各向异性
  ///     （长短轴比 1/cosInc、长轴沿太阳方向在窗面的投影）由此自动得到；
  ///     旧实现在窗平面撒**正圆**（cosInc=0.5 时沿拉伸方向欠糊 2×）。
  ///   · 可见比例是 0~1 的**连续**量。采样数固定 [_kConeSamples] 且逐像素
  ///     做 Cranley–Patterson 方位旋转：旧实现按半影比例分档 5/9/17，正午
  ///     `penumbra≈0.0085` 恰落入 5 样本档 ⟹ 只有 6 级灰度、出现台阶
  ///     （与注释自称"避免阶梯"相反），且档位随窗宽漂移。
  ///   · 球冠采样用 `cos γ = 1 − u(1 − cos θ☉)`、`u = (s+0.5)/N`（中点分层），
  ///     每个等面积环带恰有一个样本；旧实现取 `f = sqrt(s/N)`，s 最大 N−1，
  ///     最外环带（占总面积 1/N，N=5 时 20%）永不采样，半影系统性偏窄。
  ///   · 样本按临边昏暗加权 I(μ)/I(1) ≈ 1 − u(1 − μ)（可视带 u ≈ 0.6），
  ///     μ = 样本方向与日心的夹角余弦。旧实现等价于"日面均匀辐亮度"。
  ///   · 光源角半径**不由本文件造**：日面几何角径恒为 0.5331°（±1.7% 随日地
  ///     距离变化），与高度角无关；"低太阳角前向散射把日轮糊成 2~3° 均匀亮盘"
  ///     是错误表述（环日散射是低辐亮度的幂律尾部，且总能量远小于直射光束）。
  ///     环日散射的角分布应由外部大气模块折算成等效角半径后传入。
  ///
  /// 返回"可见比例"（0~1）作为软遮挡系数：全在玻璃内 → 1、全被窗框挡 → 0、
  /// 跨界 → 半影。
  ///
  /// 【未建模，次要】极低太阳角时日轮被大气折射**压扁**（上下缘折射差约 0.2°，
  /// 垂直方向压扁约 30%）。这里把日面当正圆处理；影响仅在地平线附近，且此时
  /// 光束已极弱（scene3d[11]）。
  Float64List windowVisibilityBatch(
    Float64List pts,
    List<double> sunDir, {
    double? sunAngularRadiusDeg,
    double aod550 = 0.05,
  }) {
    final n = pts.length ~/ 3;
    final out = Float64List(n);
    final sl = math.sqrt(
        sunDir[0] * sunDir[0] + sunDir[1] * sunDir[1] + sunDir[2] * sunDir[2]);
    if (sl <= 1e-12) return out;
    // 单位化的"P → 太阳"方向
    final tx = -sunDir[0] / sl;
    final ty = -sunDir[1] / sl;
    final tz = -sunDir[2] / sl;

    // 光源角半径：外部给定优先；缺省用几何日面半角（单一真源在 astro）
    final altDeg = math.asin(ty.clamp(-1.0, 1.0)) / kDeg;
    final diskDeg =
        (sunAngularRadiusDeg ?? sunAngularDiameterDeg(altDeg) * 0.5).abs();
    // ── 两分量光源：日面 + **环日散射 aureole** ──
    //
    // 真实太阳直射不是纯圆盘：气溶胶米氏前向散射在日轮外铺开一条低辐亮度
    // 的幂律尾（环日辐射 CSR，晴天空气溶胶下约占直射能量 10~20%，角半宽
    // 约 2°）。它决定光斑边缘的柔化与四周的微光晕。此前实现只有几何日面
    // （0.2665° 半角，3 m 墙上仅 ~2.8 cm ≈ 5 px），边缘因此刀切、"像贴上去"。
    //
    // 采样：64 样本切两组 —— 宽锥 8 个（分布平缓，少量即够），日面 56 个
    // 按面积均匀分层并乘临边昏暗；权重按能量比归一到 1。
    //
    // 环日/直射能量比 wAureole 不写死：由气溶胶光学厚度 AOD550 给出。
    // 经验依据（Hess & Koepke 对 CSR 的参数化，晴空气溶胶量级）：
    //   AOD→0（瑞利大气）时环日辐射趋近瑞利前向峰值，占直射约 5%；
    //   AOD=0.05（23 km 能见度）约 12%；AOD=0.4（霾）可达 30%。
    // 用有理式 w = 0.05 + 0.19·√(AOD/(AOD+0.05)) 拟合上述三点，单调有界。
    final aod = aod550.clamp(0.0, 1.5);
    final wAureole =
        0.05 + 0.19 * math.sqrt(aod / (aod + 0.05));
    const double aureoleHalfDeg = 2.0;
    final thetaDisk = diskDeg * kDeg;
    final thetaHalo = aureoleHalfDeg * kDeg;
    const int nHalo = 8;
    const int nDisk = _kConeSamples - nHalo;

    // ── 方向空间球冠采样表（与像素无关，整帧算一次）──
    final cosG = Float64List(_kConeSamples);
    final sinG = Float64List(_kConeSamples);
    final wgt = Float64List(_kConeSamples);
    final phi = Float64List(_kConeSamples);
    var sumW = 0.0;
    // 先求日面临边昏暗和，用于能量比归一
    var ldSum = 0.0;
    for (var s = 0; s < nDisk; s++) {
      final cg = 1.0 - ((s + 0.5) / nDisk) * (1.0 - math.cos(thetaDisk));
      ldSum += 1.0 - _kLimbDarkeningU * (1.0 - cg);
    }
    for (var s = 0; s < _kConeSamples; s++) {
      final isHalo = s < nHalo;
      final th = isHalo ? thetaHalo : thetaDisk;
      final n = isHalo ? nHalo : nDisk;
      final f = ((isHalo ? s : s - nHalo) + 0.5) / n;
      final cg = 1.0 - f * (1.0 - math.cos(th));
      cosG[s] = cg;
      sinG[s] = math.sqrt(math.max(0.0, 1.0 - cg * cg));
      // 方位：黄金角序列（低差异），逐像素再加一个旋转量去相关
      phi[s] = _kTwoPi * ((s * _kGoldenRatioConj) % 1.0);
      if (isHalo) {
        wgt[s] = wAureole / nHalo;
      } else {
        wgt[s] = (1.0 - wAureole) * (1.0 - _kLimbDarkeningU * (1.0 - cg)) /
            math.max(ldSum, 1e-9);
      }
      sumW += wgt[s];
    }
    // 与 toSun 正交的基
    final (b1x, b1y, b1z, b2x, b2y, b2z) = _orthoBasis(tx, ty, tz);

    final pl = placement();
    final panes = _glassPanes(pl);
    final eastWest = pl.wall == Wall.east || pl.wall == Wall.west;
    final plane = pl.planeCoord;
    final uLo = math.min(pl.u0, pl.u1), uHi = math.max(pl.u0, pl.u1);
    final vLo = math.min(pl.v0, pl.v1), vHi = math.max(pl.v0, pl.v1);
    final rhoMargin =
        math.sin(thetaHalo) * (1.0 + math.sin(thetaHalo)); // 用宽锥包络

    // 窗洞侧壁（reveal）：窗洞是穿过墙厚 d 的隧道。光线除在**内**墙面落在
    // 玻璃上，还必须穿出**外**墙面时仍落在窗洞开口内，否则被侧壁挡住。
    final outwardSign = pl.wall == Wall.west ? -1.0 : 1.0;
    final planeOuter = plane + outwardSign * cfg.wallThicknessM;

    for (var i = 0; i < n; i++) {
      final o = i * 3;
      final px = pts[o], py = pts[o + 1], pz = pts[o + 2];
      // ── 中心方向的交点 (u_c, v_c) 与距离 t_c ──
      final double tC, uc, vc;
      if (eastWest) {
        if (tx.abs() < 1e-12) continue;
        tC = (plane - px) / tx;
        if (tC <= 0) continue;
        uc = pz + tC * tz;
        vc = py + tC * ty;
      } else {
        if (tz.abs() < 1e-12) continue;
        tC = (plane - pz) / tz;
        if (tC <= 0) continue;
        uc = px + tC * tx;
        vc = py + tC * ty;
      }
      // reveal（中心方向）：外墙侧落点必须在窗洞开口内
      final tCo =
          eastWest ? (planeOuter - px) / tx : (planeOuter - pz) / tz;
      final uco = eastWest ? pz + tCo * tz : px + tCo * tx;
      final vco = py + tCo * ty;
      if (uco < uLo || uco > uHi || vco < vLo || vco > vHi) continue;
      // ── 锥体足迹在 (u,v) 上的包围盒半宽（线性化后严格上界 + 二次残差余量）──
      double duu, duv, dvu, dvv;
      if (eastWest) {
        duu = tC * (b1z - b1x * tz / tx);
        duv = tC * (b2z - b2x * tz / tx);
        dvu = tC * (b1y - b1x * ty / tx);
        dvv = tC * (b2y - b2x * ty / tx);
      } else {
        duu = tC * (b1x - b1z * tx / tz);
        duv = tC * (b2x - b2z * tx / tz);
        dvu = tC * (b1y - b1z * ty / tz);
        dvv = tC * (b2y - b2z * ty / tz);
      }
      final hu = rhoMargin * math.sqrt(duu * duu + duv * duv);
      final hv = rhoMargin * math.sqrt(dvu * dvu + dvv * dvv);

      // 精确早退 1：足迹包围盒与窗洞无交集 ⟹ 该点看不到任何日面方向（全暗）。
      if (uc + hu < uLo || uc - hu > uHi || vc + hv < vLo || vc - hv > vHi) {
        continue;
      }
      // 精确早退 2：足迹整体落在**单块玻璃**内 ⟹ 可见比例恒为 1（全亮）。
      // （半影带只占画面上极窄的一条，绝大多数像素走这两条早退，
      //   整帧成本与单样本实现同量级。）
      var fullyVisible = false;
      for (var k = 0; k < panes.length; k += 4) {
        if (uc - hu >= panes[k] &&
            uc + hu <= panes[k + 1] &&
            vc - hv >= panes[k + 2] &&
            vc + hv <= panes[k + 3] &&
            // reveal：外墙侧中心落点也在同一块玻璃内
            uco >= panes[k] &&
            uco <= panes[k + 1] &&
            vco >= panes[k + 2] &&
            vco <= panes[k + 3]) {
          fullyVisible = true;
          break;
        }
      }
      if (fullyVisible) {
        out[i] = 1.0;
        continue;
      }

      // ── 半影像素：方向空间采样（逐像素方位旋转，去相关/去结构走样）──
      final spin = _kTwoPi * _hash01(i);
      var acc = 0.0;
      for (var s = 0; s < _kConeSamples; s++) {
        final cp = math.cos(phi[s] + spin);
        final sp = math.sin(phi[s] + spin);
        final sg = sinG[s];
        final lx = cosG[s] * tx + sg * (cp * b1x + sp * b2x);
        final ly = cosG[s] * ty + sg * (cp * b1y + sp * b2y);
        final lz = cosG[s] * tz + sg * (cp * b1z + sp * b2z);
        double u, v;
        if (eastWest) {
          if (lx.abs() < 1e-12) continue;
          final t = (plane - px) / lx;
          if (t <= 0) continue;
          u = pz + t * lz;
          v = py + t * ly;
        } else {
          if (lz.abs() < 1e-12) continue;
          final t = (plane - pz) / lz;
          if (t <= 0) continue;
          u = px + t * lx;
          v = py + t * ly;
        }
        if (_inPanes(panes, u, v)) {
          // reveal：外墙侧落点也必须在窗洞开口内
          final to = eastWest ? (planeOuter - px) / lx : (planeOuter - pz) / lz;
          final uo = eastWest ? pz + to * lz : px + to * lx;
          final vo = py + to * ly;
          if (uo >= uLo && uo <= uHi && vo >= vLo && vo <= vHi) {
            acc += wgt[s];
          }
        }
      }
      out[i] = acc / sumW;
    }
    return out;
  }

  /// 与单位向量 (x,y,z) 正交的两个单位向量（Duff 等人的无分支构造：取
  /// |z| 较小者做叉乘，不需要额外的特殊分支）。
  static (double, double, double, double, double, double) _orthoBasis(
      double x, double y, double z) {
    // 选一个与 n 不平行的轴：|n.x| < 0.9 用 x 轴，否则用 y 轴
    final double ax, ay, az;
    if (x.abs() < 0.9) {
      ax = 1.0;
      ay = 0.0;
      az = 0.0;
    } else {
      ax = 0.0;
      ay = 1.0;
      az = 0.0;
    }
    var ux = ay * z - az * y;
    var uy = az * x - ax * z;
    var uz = ax * y - ay * x;
    final ul = math.sqrt(ux * ux + uy * uy + uz * uz);
    if (ul <= 1e-12) return (1.0, 0.0, 0.0, 0.0, 1.0, 0.0);
    ux /= ul;
    uy /= ul;
    uz /= ul;
    final wx = y * uz - z * uy;
    final wy = z * ux - x * uz;
    final wz = x * uy - y * ux;
    return (ux, uy, uz, wx, wy, wz);
  }

  /// 像素索引的确定性散列 → [0,1)。常数取自 MurmurHash3 的尾部混合
  /// （fmix32），是无量纲的散列常数，非物理参数。
  static double _hash01(int i) {
    var h = (i * 0x9E3779B1) & 0xFFFFFFFF;
    h = (h ^ (h >>> 16)) & 0xFFFFFFFF;
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF;
    h = (h ^ (h >>> 13)) & 0xFFFFFFFF;
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF;
    h = (h ^ (h >>> 16)) & 0xFFFFFFFF;
    return h / 4294967296.0;
  }

  /// 窗户外法线（房间坐标，指向窗外）。
  ///
  /// **按真实朝向方位角连续计算**，不量化到三面墙。
  ///
  /// 规范系的方位角约定：canonical(az) = (sin az, 0, −cos az)，
  /// 即 0° = −Z（相机朝向）、90° = +X、180° = +Z。
  ///
  /// 早期实现把法线量化成 (1,0,0)/(−1,0,0)/(0,0,±1) 三选一：360 个方位角里
  /// 有 176 个会算错入射余弦（例如窗朝 136°、太阳 90° 时真值 0.653、
  /// 量化后 0.000），只有正东/正西/正南/正北恰好精确 —— 这也是单元测试
  /// 没能暴露它的原因。连续形式对任意方位角都精确，且与
  /// [windowNormalAzRoom] 天然自洽（后者曾与量化法线给出互相矛盾的结果）。
  ///
  /// 注：房间几何（窗户落在哪面墙）仍需离散化，那是**几何建模**的近似；
  /// 但入射余弦是**光学量**，必须用真实朝向，不能继承几何的量化误差。
  List<double> windowOutwardNormal() {
    final az = windowNormalAzRoom * kDeg;
    return <double>[math.sin(az), 0.0, -math.cos(az)];
  }

  /// 窗面法线方位角（规范系）—— **真实朝向，不量化到墙面**。
  double get windowNormalAzRoom => toRoomAz(windowAz);

  // ─────────────────────────── 选择规则 ───────────────────────────

  static Wall _wallForWindow(double windowAz, double viewWallAz) {
    final canonical = normAz(windowAz + 180.0 - viewWallAz);
    if (azDelta(canonical, 90.0) <= 45.0) return Wall.east;
    if (azDelta(canonical, 270.0) <= 45.0) return Wall.west;
    return Wall.back;
  }

  /// 由窗户朝向选择观察墙（= 房间相对地理的旋转）。
  ///
  /// 让窗所在墙的外法线**精确等于** [windowAz]：取 viewWallAz = windowAz ± 90
  /// （窗落在侧墙），观察墙即与该墙垂直的那面（斜切，全天有长条光斑扫过）。
  ///
  /// 旧实现为"让光斑扫进画面"反解朝向（东西向配垂直墙、南北向一律 90），
  /// 后果有两处：① 窗法线被量化到 3 面墙，176/360 个方位角算错入射余弦；
  /// ② 在 45°/135°/225°/315° 处不连续（输入 135°→viewWall 225，
  /// 136°→viewWall 90，1° 的输入跳 135° 构图）。本式对任意方位角连续且精确。
  static double chooseViewWall(double windowAz) {
    final w = normAz(windowAz);
    return w < 180.0 ? normAz(w + 90.0) : normAz(w - 90.0);
  }
}
