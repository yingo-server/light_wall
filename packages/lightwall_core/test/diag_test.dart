import 'dart:typed_data';
import 'package:lightwall_core/lightwall_core.dart';
import 'package:test/test.dart';
void main() {
  test('diag', () {
    final r = render(
      baseRgb: Uint8List.fromList(List.filled(240*135*3, 128)),
      width: 240, height: 135,
      spec: RenderSpec(
        time: DateTime.parse('2025-12-21T12:00:00+08:00'),
        lat: 39.9042, lon: 116.4074, windowAz: -1),
    );
    print('noon: sunAz=${r.light.sunAz} alt=${r.light.sunAlt} visible=${r.albedoStats['visible_ratio']}');
    final s = Scene3D(SceneConfig(), 135, viewWallAz: Scene3D.chooseViewWall(135, sunAzGeo: r.light.sunAz, lat: 39.9042));
    print('viewWall=${s.viewWallAz} winWall=${s.winWall} 法线=${s.windowNormalAzRoom}');
    print('toSun=${s.sunToRoomDir(r.light.sunAz, r.light.sunAlt)}');
  });
}
