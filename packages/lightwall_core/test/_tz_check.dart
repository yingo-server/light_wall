import 'package:lightwall_core/src/astro.dart';
void main() {
  for (final t in ['2025-12-21T12:16:00+08:00','2025-12-21T16:50:00+08:00','2025-12-21T23:00:00+08:00','2025-12-21T04:16:00-05:00']) {
    final dt = DateTime.parse(t);
    final p = sunPosition(39.9042, 116.4074, dt);
    print('$t  UTC=${dt.toUtc()}  alt=${p.altitude.toStringAsFixed(2)}  az=${p.azimuth.toStringAsFixed(1)}');
  }
}
