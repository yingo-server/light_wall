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
      expect(s.azimuth, closeTo(180.0, 1.5));
    });

    test('上午 9 点太阳在东偏南方向', () {
      final s = sunPosition(39.9042, 116.4074, DateTime.parse('2025-06-21T09:00:00+08:00'));
      expect(s.altitude, closeTo(45.8, 0.3));
      expect(s.azimuth, closeTo(96.7, 0.3));
    });

    test('夜间高度角为负', () {
      final s = sunPosition(39.9042, 116.4074, DateTime.parse('2025-06-21T02:00:00+08:00'));
      expect(s.altitude, lessThan(0));
    });
  });

  group('大气与辐照度', () {
    test('分波长透过率：正午偏白，低角偏红', () {
      final noon = solarIrradianceRgb(60.0);
      expect((noon[0] - noon[2]).abs(), lessThan(0.12)); // 通道接近
      final low = solarIrradianceRgb(3.0);
      expect(low[0], greaterThan(low[2])); // 红 > 蓝
    });

    test('辐照度随高度角单调上升', () {
      expect(solarIrradiance(10), lessThan(solarIrradiance(30)));
      expect(solarIrradiance(30), lessThan(solarIrradiance(60)));
    });

    test('天光在夜间为 0，白天随高度角上升', () {
      expect(skyIrradiance(-5), 0.0);
      expect(skyIrradiance(45.8), closeTo(0.180, 0.01));
      expect(skyIrradiance(20), lessThan(skyIrradiance(60)));
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
      // 南向窗：观察墙正对窗户，窗落在身后的墙上
      expect(Scene3D(SceneConfig(), 180).winWall, Wall.back);
      // 北向窗：北半球无直射，几何上同样成立
      final n = Scene3D(SceneConfig(), 0);
      expect(n.winWall, isNotNull);
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
      expect(cos2, 0.0);
    });
  });

  group('室内照度物理', () {
    test('互反射底 k = ρ/(1−ρ)', () {
      expect(interreflectionFloor(0.55), closeTo(1.2222, 0.001));
    });

    test('空气光在室内只有千分之几（不应硬凑雾感）', () {
      final f = airlightFraction(4.0);
      expect(f, lessThan(0.01));
      expect(f, greaterThan(0.0));
    });

    test('视觉适应：晴天 ≈ 1，暗处提亮，夜间不提亮', () {
      expect(eyeExposureEv(1.0, sunAlt: 45), closeTo(1.0, 0.01));
      expect(eyeExposureEv(0.25, sunAlt: 45), greaterThan(1.3));
      expect(eyeExposureEv(0.25, sunAlt: 0), closeTo(1.0, 0.01));
    });
  });
}
