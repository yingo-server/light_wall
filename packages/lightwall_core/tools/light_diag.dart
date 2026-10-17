// 光照合理性回归：批量渲染多场景并输出可判定的统计量
//
// 为什么需要它：单看某一张图"看着还行"不能证明算法对。这里把
// 关键约束写成数值断言，任何一次算法改动导致的亮度失衡都能立刻显现：
//   · 过曝比例（>=250）不应 >2%：ACES 应该压住高光
//   · 死黑比例（<=8）不应 >25%：室内互反射底应托住暗部
//   · 白天图均值应在 [40, 210]：既不欠曝也不过曝
//   · 同一时刻同一朝向两次渲染必须逐字节一致（确定性）
//
// 用法：dart run tools/light_diag.dart [--json]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lightwall_core/lightwall_core.dart';

const double kLat = 39.9042;
const double kLon = 116.4074;

class Case {
  const Case(this.name, this.time, this.window);
  final String name;
  final String time;
  final double window;
}

const List<Case> kCases = <Case>[
  Case('冬至 08:30 东窗', '2025-12-21T08:30:00+08:00', 90),
  Case('冬至 12:00 东窗', '2025-12-21T12:00:00+08:00', 90),
  Case('冬至 15:30 西窗', '2025-12-21T15:30:00+08:00', 270),
  Case('冬至 09:30 南窗', '2025-12-21T09:30:00+08:00', 180),
  Case('夏至 07:00 东窗', '2025-06-21T07:00:00+08:00', 90),
  Case('夏至 12:00 东窗', '2025-06-21T12:00:00+08:00', 90),
  Case('夏至 18:00 西窗', '2025-06-21T18:00:00+08:00', 270),
  Case('春分 10:00 东窗', '2026-03-20T10:00:00+08:00', 90),
  Case('日落 17:20 西窗', '2025-12-21T17:20:00+08:00', 270),
  Case('暮光 17:50 西窗', '2025-12-21T17:50:00+08:00', 270),
  Case('夜间 23:00 东窗', '2025-12-21T23:00:00+08:00', 90),
];

Uint8List syntheticWall(int w, int h) {
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final n = valueNoise(x / 13.0, y / 13.0, 7);
      final v = (150 + 28 * n).round().clamp(0, 255);
      final i = (y * w + x) * 3;
      out[i] = v;
      out[i + 1] = (v * 0.98).round();
      out[i + 2] = (v * 0.94).round();
    }
  }
  return out;
}

Map<String, double> stats(Uint8List rgb) {
  var sum = 0.0;
  var over = 0;
  var dark = 0;
  for (var i = 0; i < rgb.length; i += 3) {
    final y = 0.2126 * rgb[i] + 0.7152 * rgb[i + 1] + 0.0722 * rgb[i + 2];
    sum += y;
    if (y >= 250) over++;
    if (y <= 8) dark++;
  }
  final n = rgb.length / 3;
  return <String, double>{
    'mean': sum / n,
    'over': over / n,
    'dark': dark / n,
  };
}

/// 单个场景异常不拖垮整个门禁：捕获后由调用方记为该 case 的失败行。
T? tryOrNull<T>(T Function() f) {
  try {
    return f();
  } catch (_) {
    return null;
  }
}

void main(List<String> argv) {
  const w = 320, h = 180;
  final base = syntheticWall(w, h);
  final rows = <Map<String, Object?>>[];
  var fails = 0;

  for (final c in kCases) {
    final t = DateTime.parse(c.time);
    final res = tryOrNull(() => render(
      baseRgb: base,
      width: w,
      height: h,
      spec: RenderSpec(
        time: t,
        lat: kLat,
        lon: kLon,
        windowAz: c.window,
      ),
    ));
    if (res == null) {
      fails++;
      rows.add(<String, Object?>{
        'case': c.name,
        'source': 'EXCEPTION',
        'sunAlt': 0.0, 'beam': 0.0, 'cos': 0.0, 'visible': 0.0, 'ev': 0.0,
        'mean': 0.0, 'over': 0.0, 'dark': 0.0,
        'problems': <String>['渲染抛出异常（内部错误）'],
      });
      continue;
    }
    final s = stats(res.rgb);
    final beam = res.light.beamIrradiance;
    final vis = res.albedoStats['visible_ratio'] ?? 0;
    final cos = res.albedoStats['incidence_cos'] ?? 0;
    final ev = res.albedoStats['exposure_ev'] ?? 1;

    final problems = <String>[];
    // 白天亮度区间：只对**有太阳**的场景断言。暮光/夜间本来就该暗，
    // 把它们算进"白天"等于要求黄昏和正午一样亮。
    final isDay = res.light.source == LightSource.sun;
    if (isDay && (s['mean']! < 40 || s['mean']! > 210)) {
      problems.add('白天均值超出 [40,210]');
    }
    if (s['over']! > 0.02) problems.add('过曝 >2%');
    if (s['dark']! > 0.25) problems.add('死黑 >25%');
    // 暮光不得比深夜更暗（民用暮光仍有天顶余晖 + 地平线亮带）
    if (res.light.source == LightSource.twilight && s['mean']! < 25) {
      problems.add('暮光过暗（应亮于深夜）');
    }
    // 有直射的条件：白天 + 光能照到**观察墙**（观察墙内法线房间系 +Z，
    // 故要求 toSun.z > 0：太阳在观察墙正面半球）+ 窗户入射余弦够大。
    // 【注意】仅看窗户入射余弦是不够的：夏至早晨太阳在东偏北，
    // 东窗 cos 高达 0.90，但光从北侧来，照不到朝南的观察墙 ——
    // 这种情况下"无光斑"才是物理正确的。
    final scene = Scene3D(SceneConfig(), c.window);
    // sunToRoomDir 返回的是"光射向房间"的**传播方向**；指向太阳取负。
    final toSunZ = -scene.sunToRoomDir(res.light.sunAz, res.light.sunAlt)[2];
    final reachesViewWall = toSunZ > 0.05;
    if (isDay && reachesViewWall && cos > 0.25 && vis < 0.005 && beam > 0.05) {
      problems.add('入射余弦 ${cos.toStringAsFixed(2)} 却无光斑');
    }
    if (problems.isNotEmpty) fails++;

    rows.add(<String, Object?>{
      'case': c.name,
      'source': res.light.source.name,
      'sunAlt': double.parse(res.light.sunAlt.toStringAsFixed(1)),
      'beam': double.parse(beam.toStringAsFixed(3)),
      'cos': double.parse(cos.toStringAsFixed(3)),
      'visible': double.parse(vis.toStringAsFixed(4)),
      'ev': double.parse(ev.toStringAsFixed(3)),
      'mean': double.parse(s['mean']!.toStringAsFixed(1)),
      'over': double.parse((s['over']! * 100).toStringAsFixed(2)),
      'dark': double.parse((s['dark']! * 100).toStringAsFixed(2)),
      'problems': problems,
    });
  }

  // 确定性：同参数两次渲染逐字节一致
  final a = render(
    baseRgb: base,
    width: w,
    height: h,
    spec: RenderSpec(
      time: DateTime.parse('2025-12-21T08:30:00+08:00'),
      lat: kLat,
      lon: kLon,
      windowAz: 90,
    ),
  );
  final b = render(
    baseRgb: base,
    width: w,
    height: h,
    spec: RenderSpec(
      time: DateTime.parse('2025-12-21T08:30:00+08:00'),
      lat: kLat,
      lon: kLon,
      windowAz: 90,
    ),
  );
  var identical = a.rgb.length == b.rgb.length;
  if (identical) {
    for (var i = 0; i < a.rgb.length; i++) {
      if (a.rgb[i] != b.rgb[i]) {
        identical = false;
        break;
      }
    }
  }
  if (!identical) fails++;

  if (argv.contains('--json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'cases': rows,
      'deterministic': identical,
      'fails': fails
    }));
  } else {
    stdout.writeln(
        '场景                     光源    高度   直射    cos   可见%   EV   均值  过曝%  死黑%  问题');
    for (final r in rows) {
      stdout.writeln('${(r['case']! as String).padRight(22)}'
          '${(r['source']! as String).padRight(8)}'
          '${(r['sunAlt']!).toString().padLeft(6)}'
          '${(r['beam']!).toString().padLeft(7)}'
          '${(r['cos']!).toString().padLeft(7)}'
          '${((r['visible']! as double) * 100).toStringAsFixed(1).padLeft(7)}'
          '${(r['ev']!).toString().padLeft(6)}'
          '${(r['mean']!).toString().padLeft(7)}'
          '${(r['over']!).toString().padLeft(7)}'
          '${(r['dark']!).toString().padLeft(7)}   '
          '${(r['problems']! as List).join('; ')}');
    }
    stdout.writeln('\n确定性: ${identical ? 'OK' : '失败'}'
        ' · 问题场景: $fails / ${kCases.length}');
  }
  exitCode = fails > 0 ? 1 : 0;
}
