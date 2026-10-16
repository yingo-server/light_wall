import 'dart:math' as math;

// 物理内核测试：天文、大气、窗户几何
import 'package:lightwall_core/lightwall_core.dart';
import 'package:test/test.dart';

void main() {
  group('太阳位置', () {
    test('北京夏至正午高度角接近理论值', () {
      // 理论最大高度角 = 90 − |39.9042 − 23.44| ≈ 73.54
      final t = DateTime.parse('2025-06-21T12:14:00+08:00');
      final s = sunPosition(39.9042, 116.4074, t);
      expect(s.altitude, closeTo(73.5, 0.6));
      expect(s.azimuth, closeTo(179.0, 3.0));
    });

    test('上午 9 点太阳在东偏南方向', () {
      final s = sunPosition(
          39.9042, 116.4074, DateTime.parse('2025-06-21T09:00:00+08:00'));
      expect(s.altitude, closeTo(45.8, 0.3));
      expect(s.azimuth, closeTo(96.7, 0.3));
    });

    test('夜间高度角为负', () {
      final s = sunPosition(
          39.9042, 116.4074, DateTime.parse('2025-06-21T02:00:00+08:00'));
      expect(s.altitude, lessThan(0));
    });
  });

  group('大气与辐照度', () {
    test('分波长透过率：正午偏白，低角偏红', () {
      // 口径说明：新实现返回**亮度归一化的线性色度**，红蓝差天然比旧的
      // sRGB 黑体值大（旧值把 gamma 编码的显示值当线性光用）。
      final noon = sunColorFromAltitude(60.0);
      expect(noon[0], greaterThan(noon[2]));
      expect((noon[0] - noon[2]) / noon[0], lessThan(0.45)); // 正午仍偏白
      final low = sunColorFromAltitude(3.0);
      expect(low[0], greaterThan(low[2]));
      expect((low[0] - low[2]) / low[0],
          greaterThan((noon[0] - noon[2]) / noon[0] * 1.8));
      // 色度不得为负（超出 sRGB 色域时应裁剪而非留负值）
      for (final a in <double>[0.0, 0.5, 1.0, 3.0, 10.0, 45.0, 90.0]) {
        for (final v in sunColorFromAltitude(a)) {
          expect(v, greaterThanOrEqualTo(0.0));
        }
      }
    });

    test('光谱积分基准：6500K 黑体（无大气）应接近 D65 白点', () {
      // 对"普朗克光谱 × CIE CMF × sRGB 矩阵"整条链的标定检查：
      // CMF 拟合或色度矩阵写错，这里会立刻失败。
      var x = 0.0, y = 0.0, z = 0.0;
      for (var l = 380.0; l <= 780.0; l += 2.0) {
        final e = planckRel(l, 6500.0) * 2.0;
        x += e * cieX(l);
        y += e * cieY(l);
        z += e * cieZ(l);
      }
      final rgb = xyzToLinearSrgb(x, y, z);
      final m = rgb.reduce((a, b) => a > b ? a : b);
      for (final v in rgb) {
        expect(v / m, closeTo(1.0, 0.06));
      }
    });

    test('辐照度随高度角单调上升', () {
      expect(solarIrradiance(10), lessThan(solarIrradiance(30)));
      expect(solarIrradiance(30), lessThan(solarIrradiance(60)));
    });

    test('天光在夜间为 0，白天随高度角上升', () {
      expect(skyIrradiance(-5), 0.0);
      // 口径更新：旧的 0.22·sin^0.6 是一个在 h→0 处趋于 0 的幂律拟合
      // （0.180 @45.8°），与暮光分支不连续。现改为晴天实测的漫射量级
      // 0.05 + 0.06·sin h（天顶 0.11、地平线 0.05）→ 45.8° 处 ≈ 0.093。
      expect(skyIrradiance(45.8), closeTo(0.093, 0.01));
      expect(skyIrradiance(20), lessThan(skyIrradiance(60)));
      // 与暮光在 h=0 处连续（不出现"日落瞬间全黑"的台阶）
      expect(twilightDiffuse(0.0), closeTo(0.05, 0.005));
      expect(twilightDiffuse(-3.0), lessThan(twilightDiffuse(-1.0)));
      expect(twilightDiffuse(-6.0), greaterThanOrEqualTo(nightSkyIrradiance(0, 0.0)));
    });

    test('Kasten-Young 大气质量在天顶为 1 量级', () {
      expect(airMassKastenYoung(90), closeTo(0.9997, 0.01));
      expect(airMassKastenYoung(30), closeTo(2.0, 0.05));
    });

    test('昼长：夏至约 15 小时', () {
      final h = dayLengthHours(39.9042, DateTime(2025, 6, 21));
      expect(h, closeTo(15.0, 0.4));
    });
  });

  group('窗户朝向（本项目的关键修正）', () {
    test('东西南北四面各自落到正确的墙', () {
      expect(Scene3D(SceneConfig(), 90).winWall, Wall.east);
      expect(Scene3D(SceneConfig(), 270).winWall, Wall.west);
      // 南向窗：观察墙选东侧墙（斜切），南窗落在西墙 —— 正对布局下
      // 低角度冬季光斑物理上落在地板，观察墙永远看不到直射。
      expect(Scene3D(SceneConfig(), 180).winWall, Wall.west);
      // 北向窗：同样配东侧观察墙，北窗落在东墙（canonical=90）
      expect(Scene3D(SceneConfig(), 0).winWall, Wall.east);
    });

    test('参考实现里"西北向"会退化成"西向"，本实现不会', () {
      final nw = Scene3D(SceneConfig(), 315);
      final w = Scene3D(SceneConfig(), 270);
      // 观察墙方位不同 → 说明朝向真的生效了（而不是被当成同一个值）
      expect(nw.viewWallAz, isNot(equals(w.viewWallAz)));
    });

    test('窗户法线方向与朝向一致', () {
      final e = Scene3D(SceneConfig(), 90);
      final nrm = e.windowOutwardNormal();
      expect(nrm[0], 1.0); // 朝东
      final w = Scene3D(SceneConfig(), 270);
      expect(w.windowOutwardNormal()[0], -1.0); // 朝西
    });
  });

  group('窗户入射余弦', () {
    test('掠射时趋近 0（参考实现曾漏乘这一项）', () {
      final scene = Scene3D(SceneConfig(), 90);
      // 太阳正东、与窗面平行 → 入射余弦接近 1（正对）
      final dir = scene.sunToRoomDir(90, 20);
      final toSun = <double>[-dir[0], -dir[1], -dir[2]];
      final cos = windowIncidenceCos(toSun, scene.windowOutwardNormal());
      expect(cos, greaterThan(0.9));
      // 太阳正北（窗在东南侧）→ 直射为 0
      final dir2 = scene.sunToRoomDir(0, 20);
      final toSun2 = <double>[-dir2[0], -dir2[1], -dir2[2]];
      final cos2 = windowIncidenceCos(toSun2, scene.windowOutwardNormal());
      expect(cos2, closeTo(0.0, 1e-9)); // 掠射/背面：浮点意义下的 0
    });

    test('任意方位角的入射余弦都与解析真值一致', () {
      // 旧实现把窗法线**量化到三面墙**（±45°）：360 个方位角里有 176 个
      // 算错入射余弦（例如窗朝 136°、太阳 90° 时真值 0.653、旧代码 0），
      // 只有正东/正西/正南/正北恰好精确 —— 所以旧测试没能暴露它。
      // 这里对所有方位角组合与解析式 cos(Δaz)·cos(alt) 逐一比对。
      for (var waz = 0.0; waz < 360.0; waz += 15.0) {
        final scene = Scene3D(SceneConfig(), waz);
        for (var saz = 0.0; saz < 360.0; saz += 15.0) {
          final sd = scene.sunToRoomDir(saz, 30.0);
          final toSun = <double>[-sd[0], -sd[1], -sd[2]];
          final cos = windowIncidenceCos(toSun, scene.windowOutwardNormal());
          final d = ((saz - waz) % 360.0 + 540.0) % 360.0 - 180.0;
          final truth = math.max(
              0.0, math.cos(d * math.pi / 180.0) * math.cos(30.0 * math.pi / 180.0));
          expect(cos, closeTo(truth, 1e-9), reason: '窗 $waz° / 太阳 $saz°');
        }
      }
    });
  });

  group('室内照度物理', () {
    test('互反射底 k = ρ/(1−ρ)', () {
      expect(interreflectionFloor(0.55), closeTo(1.2222, 0.001));
    });

    test('房间等效反射率按面积加权（扣窗洞）', () {
      final rho = roomAlbedoAreaWeighted();
      // 白墙 0.75 / 顶 0.80 / 水泥地 0.25 的面积加权，结果应介于地板与顶棚
      expect(rho, greaterThan(0.25));
      expect(rho, lessThan(0.80));
    });

    test('曝光：完全适应会抹平昼夜，部分适应保留层次且单调', () {
      // 画面越亮，曝光倍率越小（单调）
      expect(sceneExposureEv(0.5), lessThan(sceneExposureEv(0.05)));
      // 部分适应：亮场景不会被压到与暗场景同亮度关系之外
      expect(sceneExposureEv(1.0), greaterThan(0.0));
    });
  });
}
