import 'dart:typed_data';
import 'package:lightwall_core/lightwall_core.dart';
import 'package:test/test.dart';
void main() {
  test('d3', () {
    final vw = Scene3D.chooseViewWall(180, sunAzGeo: 143.0, lat: 39.9042);
    final s = Scene3D(SceneConfig(), 180, viewWallAz: vw);
    // 模拟 pipeline 注入
    final toSunXZ = <double>[-s.sunToRoomDir(143.0, 16.3)[0], -s.sunToRoomDir(143.0, 16.3)[2]];
    final denom = toSunXZ[0] * s.chamferNx + toSunXZ[1] * s.chamferNz;
    final uAxisX = -s.chamferNz, uAxisZ = s.chamferNx;
    final t = s.chamferD / denom;
    final uOrigin = s.cfg.roomD * 0.5 * uAxisZ;
    final u = (t * toSunXZ[0] * uAxisX + t * toSunXZ[1] * uAxisZ - uOrigin)
        .clamp(-(s.cfg.roomW + s.cfg.roomD) * 0.25, (s.cfg.roomW + s.cfg.roomD) * 0.25);
    s.setChamferWindowU(u);
    final sunDir = s.sunToRoomDir(143.0, 16.3);
    final pts = Float64List.fromList([0, 1.5, 0, -2.0, 1.5, 0, -2.5, 1.0, 0]);
    final vis = s.windowVisibilityBatch(pts, sunDir);
    final pl = s.placement();
    print('d=${s.chamferD.toStringAsFixed(2)} uInj=${u.toStringAsFixed(2)} 窗u=[${pl.u0.toStringAsFixed(2)},${pl.u1.toStringAsFixed(2)}] vis=${vis.toList()}');
  });
}
