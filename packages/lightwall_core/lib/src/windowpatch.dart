// 解析式窗光投影（image-space window patch）
//
// 设计目标：**形状正确、可控、简单**。不再用锥体采样统计"墙点能否看到
// 日面"（那种做法在大窗口 + 低太阳角时会把窗格糊成一团），而是直接把
// 窗矩形沿太阳方向投影到观察墙上，得到平行四边形，再按窗格数画出窗棂。
//
// 数学：窗平面对每个角点 P_w，沿"射向太阳"方向 t 求与观察墙 z=0 的交点：
//   P = P_w + s·t,  s = −P_w.z / t.z
// 四个角点在墙上仍构成一个凸四边形（太阳是平行光）。像素落在四边形内
// 即"被照亮"。窗格坐标用双线性反解（四边形参数化）：
//   若 P = bilerp(A,B,C,D; α,β)，则 α 沿窗宽、β 沿窗高，
//   落在窗棂范围内即为阴影（0），其余为光照（1）。
import 'dart:math' as math;
import 'dart:typed_data';

/// 计算窗光在观察墙上的解析遮罩。
///
/// 返回 length = w*h 的 Float32List：1 = 直射可见，0 = 遮挡/窗外。
/// [softPx]：边缘柔化宽度（像素）。[muntinFrac]：窗棂宽度占窗格的比例。
Float32List analyticWindowMask({
  required int width,
  required int height,
  required List<double> c00, // 窗的左下角（房间系）
  required List<double> c10, // 右下
  required List<double> c01, // 左上
  required List<double> c11, // 右上
  required List<double> toSun,
  required int gridCols,
  required int gridRows,
  required double muntinFrac,
  required double frameFrac,
  double softPx = 6.0,
  required double Function(double x, double y) wallToU,
  required double Function(double x, double y) wallToV,
}) {
  final out = Float32List(width * height);
  final tz = toSun[2];
  // 太阳太低（掠射）时投影会在无穷远处炸开 → 返回全 0，由调用方回退。
  if (tz.abs() < 0.02 || tz < 0) return out;

  List<double> project(List<double> p) {
    final s = -p[2] / tz; // p + s·toSun 的 z 分量归零
    return <double>[p[0] + s * toSun[0], p[1] + s * toSun[1]];
  }

  final a = project(c00); // 墙上的四个角（x,y）
  final b = project(c10);
  final c = project(c11);
  final d = project(c01);

  // 双线性反解：P = a + α(b−a) + β(d−a) + αβ(a−b−d+c)
  // 解二次方程求 (α,β)。退化（平行四边形）时直接线性解。
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // 像素中心 → 墙面坐标（观察墙）
      final px = wallToU(x + 0.5, y + 0.5);
      final py = wallToV(x + 0.5, y + 0.5);
      // 解 (α,β)
      final ex = b[0] - a[0], ey = b[1] - a[1];
      final fx = d[0] - a[0], fy = d[1] - a[1];
      final gx = a[0] - b[0] - d[0] + c[0], gy = a[1] - b[1] - d[1] + c[1];
      final hx = px - a[0], hy = py - a[1];
      double al, be;
      final det = ex * fy - ey * fx;
      if (det.abs() < 1e-9) continue;
      // 先按平行四边形近似求初值
      al = (hx * fy - hy * fx) / det;
      be = (ex * hy - ey * hx) / det;
      // 若有非线性项则校正一次（牛顿一步）
      if (gx.abs() > 1e-9 || gy.abs() > 1e-9) {
        for (var it = 0; it < 2; it++) {
          final rx = a[0] + al * ex + be * fx + al * be * gx - px;
          final ry = a[1] + al * ey + be * fy + al * be * gy - py;
          final j11 = ex + be * gx, j12 = fx + al * gx;
          final j21 = ey + be * gy, j22 = fy + al * gy;
          final dj = j11 * j22 - j12 * j21;
          if (dj.abs() < 1e-12) break;
          al -= (rx * j22 - ry * j12) / dj;
          be -= (j11 * ry - j21 * rx) / dj;
        }
      }
      // 软边：到边界的最小距离（以 0..1 的窗格坐标度量）转像素
      final softA = softPx / math.max(1.0, (b[0] - a[0]).abs() + (b[1] - a[1]).abs());
      final softB = softPx / math.max(1.0, (d[0] - a[0]).abs() + (d[1] - a[1]).abs());
      final edgeA = _softEdge(al, softA);
      final edgeB = _softEdge(be, softB);
      var v = edgeA * edgeB;
      if (v <= 0) continue;
      // 窗格：α 方向 cols 格、β 方向 rows 格；窗棂线处压暗
      final cellA = al * gridCols;
      final cellB = be * gridRows;
      final fa = cellA - cellA.floorToDouble();
      final fb = cellB - cellB.floorToDouble();
      // 窗棂（内框）+ 窗洞外框
      final frameA = _frameFrac(al, frameFrac);
      final frameB = _frameFrac(be, frameFrac);
      final muntinA = (fa < muntinFrac || fa > 1 - muntinFrac) ? 0.0 : 1.0;
      final muntinB = (fb < muntinFrac || fb > 1 - muntinFrac) ? 0.0 : 1.0;
      v *= frameA * frameB * muntinA * muntinB;
      out[y * width + x] = v;
    }
  }
  return out;
}

double _softEdge(double t, double soft) {
  // t ∈ [0,1] 内为 1，外侧 soft 范围内平滑降为 0
  if (t < -soft || t > 1 + soft) return 0.0;
  if (t < 0) {
    final s = (t + soft) / soft;
    return s * s * (3 - 2 * s);
  }
  if (t > 1) {
    final s = (1 + soft - t) / soft;
    return s * s * (3 - 2 * s);
  }
  return 1.0;
}

/// 外框：距离窗洞边界 frameFrac 内为 0（窗框遮挡）。
double _frameFrac(double t, double f) {
  if (t < f || t > 1 - f) return 0.0;
  return 1.0;
}
