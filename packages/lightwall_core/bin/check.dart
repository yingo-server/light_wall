import 'dart:typed_data';
import 'package:lightwall_core/lightwall_core.dart';

void main() {
  // 北京 2025-06-21 09:00 (+08:00)
  final t = DateTime.parse('2025-06-21T09:00:00+08:00');
  final s = sunPosition(39.9042, 116.4074, t);
  print(
      'sun az=${s.azimuth.toStringAsFixed(2)} alt=${s.altitude.toStringAsFixed(2)}');
  final rs = sunRiseSet(39.9042, 116.4074, t.toLocal());
  print(
      'rise=${rs.rise} set=${rs.set}  dayLen=${dayLengthHours(39.9042, t).toStringAsFixed(2)}h');
  final irr = solarIrradianceRgb(45.8);
  print(
      'irr=${irr.map((v) => v.toStringAsFixed(3)).toList()}  scalar=${solarIrradiance(45.8).toStringAsFixed(3)}');
  print('sky=${skyIrradiance(45.8).toStringAsFixed(4)}');
  print(
      'sunColor=${sunColorFromAltitude(45.8).map((v) => v.toStringAsFixed(3)).toList()}');
  print(
      'sunColor5=${sunColorFromAltitude(5).map((v) => v.toStringAsFixed(3)).toList()}');
  final m = moonPosition(39.9042, 116.4074, t);
  print(
      'moon az=${m.azimuth.toStringAsFixed(1)} alt=${m.altitude.toStringAsFixed(1)} phase=${moonPhase(t).toStringAsFixed(3)}');
  // 正午高度角应与理论值一致（90-|39.9-23.44| ≈ 73.54）
  final noon = sunPosition(
      39.9042, 116.4074, DateTime.parse('2025-06-21T12:00:00+08:00'));
  print('noon alt=${noon.altitude.toStringAsFixed(2)} (理论 73.54)');
  // 模糊与噪声冒烟
  final n = valueNoise(0.3, 0.7, 1);
  final b = blurGray(Float32List.fromList(List.filled(64, 1.0)), 8, 8, 2.0);
  print(
      'noise=${n.toStringAsFixed(3)} blur0=${b[0].toStringAsFixed(3)} aces=${acesToneMap(2.0).toStringAsFixed(3)}');
  print('OK');
}
