// 验证 1：室内环境光的绝对量级 —— 代码的魔法常数 vs 物理值
//
// 思路：用代码自己的天空亮度分布 (skyLuminanceFactor) 与几何，
// 算出「观察墙上的平均照度 / 天顶辐亮度」这个纯几何-分布量，
// 再乘上天顶辐亮度与水平漫射照度的关系，得到物理上正确的
// 室内漫射照度（以 DNI 为单位），和 skyIrradiance() 的魔数比较。
import 'dart:math' as math;

import 'package:lightwall_core/lightwall_core.dart';

const double kDeg = math.pi / 180.0;

// 与 atmosphere.dart 的 _skyRadiance 一致（含地平线下 0.12 的魔数）
double skyRad(double dirY, double gamma, double sunZen, double sunAlt) {
  const belowHorizon = 0.12;
  const blend = 0.06;
  if (dirY <= -blend) return belowHorizon;
  final zr = math.acos(dirY.clamp(-1.0, 1.0));
  final s = skyLuminanceFactor(zr.clamp(0.0, math.pi * 0.5), gamma, sunZen, sunAlt);
  if (dirY >= blend) return s;
  final t = (dirY + blend) / (2 * blend);
  return belowHorizon * (1 - t) + s * t;
}

/// 半球积分：E = ∫ L cosθ dω = ∫φ Lz cosθ sinθ dθ dφ
double hemiIntegral(double sunZen, double sunAlt, {double? fixedDirY}) {
  const nt = 360, nz = 180;
  var acc = 0.0;
  for (var i = 0; i < nz; i++) {
    final th = (i + 0.5) * (math.pi * 0.5) / nz; // 天顶角
    final cosT = math.cos(th);
    final sinT = math.sin(th);
    for (var j = 0; j < nt; j++) {
      final ph = (j + 0.5) * 2 * math.pi / nt; // 方位角（相对太阳方位）
      final dy = cosT; // 方向的天顶余弦
      final gamma =
          math.acos((sinT * math.cos(ph)).clamp(-1.0, 1.0)); // 与太阳夹角
      acc += skyRad(dy, gamma, sunZen, sunAlt) * cosT * sinT;
    }
  }
  final dth = (math.pi * 0.5) / nz;
  final dph = 2 * math.pi / nt;
  return acc * dth * dph;
}

/// 竖直面（面向太阳方位）漫射照度积分
double vertIntegral(double sunZen, double sunAlt) {
  const nt = 360, nz = 180;
  var acc = 0.0;
  for (var i = 0; i < nz; i++) {
    final th = (i + 0.5) * (math.pi * 0.5) / nz;
    final cosT = math.cos(th);
    final sinT = math.sin(th);
    for (var j = 0; j < nt; j++) {
      final ph = (j + 0.5) * 2 * math.pi / nt;
      // 面法线沿 ph=0 的水平方向
      final cosInc = sinT * math.cos(ph);
      if (cosInc <= 0) continue;
      final dy = cosT;
      final gamma = math.acos((sinT * math.cos(ph)).clamp(-1.0, 1.0));
      acc += skyRad(dy, gamma, sunZen, sunAlt) * cosInc * sinT;
    }
  }
  final dth = (math.pi * 0.5) / nz;
  final dph = 2 * math.pi / nt;
  return acc * dth * dph;
}

/// 观察墙上「窗面孔径积分」的平均值（每单位天顶辐亮度）
/// 复刻 apertureIlluminance，但**不做均值归一化**
double wallMeanAperture(double sunAlt, {int nx = 60, int ny = 40}) {
  final scene = Scene3D(SceneConfig(), 90); // 东窗
  final pl = scene.placement();
  final sunZen = (90.0 - sunAlt).clamp(0.0, 90.0);
  const sunAzGeo = 90.0;
  final sd = scene.sunToRoomDir(sunAzGeo, sunAlt);
  final ts = <double>[-sd[0], -sd[1], -sd[2]];
  final su = 64, sv = 64;
  final dA = ((pl.u1 - pl.u0).abs() * (pl.v1 - pl.v0).abs()) / (su * sv);
  var sum = 0.0;
  var cnt = 0;
  for (var iy = 0; iy < ny; iy++) {
    final py = (iy + 0.5) / ny * 3.0; // 房间高 3m
    for (var ix = 0; ix < nx; ix++) {
      final px = ((ix + 0.5) / nx - 0.5) * 5.0; // 房间宽 5m
      var acc = 0.0;
      for (var si = 0; si < su; si++) {
        final u = pl.u0 + (pl.u1 - pl.u0) * (si + 0.5) / su;
        for (var sj = 0; sj < sv; sj++) {
          final v = pl.v0 + (pl.v1 - pl.v0) * (sj + 0.5) / sv;
          final dx = pl.planeCoord - px, dy = v - py, dz = u - 0.0;
          final r2 = dx * dx + dy * dy + dz * dz;
          final r = math.sqrt(math.max(r2, 1e-6));
          final cosWin = dx.abs() / r;
          final cosWall = dz.abs() / r;
          final inv = 1.0 / r;
          final dirX = dx * inv, dirY = dy * inv, dirZ = dz * inv;
          final cosG = (dirX * ts[0] + dirY * ts[1] + dirZ * ts[2])
              .clamp(-1.0, 1.0);
          final lum = skyRad(dirY, math.acos(cosG), sunZen, sunAlt);
          acc += dA * cosWin * cosWall / r2 * lum;
        }
      }
      sum += acc;
      cnt++;
    }
  }
  return sum / cnt; // 单位：sr（每单位 Lz）
}

void main() {
  const lats = <double>[15.0, 30.0, 45.0, 60.0, 75.0];
  print('alt   I_h(sr)  I_v(sr)  I_v/I_h  墙均孔径Ē(sr)  Ē/I_h   '
      '物理环境/DNI  代码环境  倍数');
  for (final alt in lats) {
    final sunZen = (90.0 - alt).clamp(0.0, 90.0);
    final ih = hemiIntegral(sunZen, alt);
    final iv = vertIntegral(sunZen, alt);
    final ea = wallMeanAperture(alt);
    // 物理：E_dh ≈ 0.125·DNI（晴空实测 0.10~0.15，ASHRAE 给 0.056）
    const kDiffuseRatio = 0.125;
    final phys = kDiffuseRatio * ea / ih; // 以 DNI 为单位
    final code = skyIrradiance(alt); // 魔数 0.22·sin^0.6
    print('${alt.toStringAsFixed(0).padLeft(3)}  '
        '${ih.toStringAsFixed(3)}   ${iv.toStringAsFixed(3)}   '
        '${(iv / ih).toStringAsFixed(3)}    ${ea.toStringAsFixed(4)}      '
        '${(ea / ih).toStringAsFixed(5)}   '
        '${phys.toStringAsFixed(5)}      ${code.toStringAsFixed(4)}   '
        '${(code / phys).toStringAsFixed(1)}x');
  }

  // 代码自己的 beam 归一化（DNI 的代理量）
  print('');
  print('alt  beam(代码=solarIrradiance)  代码 ambient/beam  物理 ambient/beam');
  for (final alt in lats) {
    final beam = solarIrradiance(alt);
    final sunZen = (90.0 - alt).clamp(0.0, 90.0);
    final ih = hemiIntegral(sunZen, alt);
    final ea = wallMeanAperture(alt);
    final physRatio = 0.125 * ea / ih;
    print('${alt.toStringAsFixed(0).padLeft(3)}  ${beam.toStringAsFixed(3)}'
        '                        ${(skyIrradiance(alt) / beam).toStringAsFixed(3)}'
        '             ${physRatio.toStringAsFixed(5)}'
        '   (差 ${(skyIrradiance(alt) / beam / physRatio).toStringAsFixed(0)}x)');
  }
}
