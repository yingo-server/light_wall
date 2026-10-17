// LightWall 命令行渲染器（纯 Dart，无 Flutter）
//
// 用途：
//   1. 本地/CI 快速验证光照效果（不开窗口、不需要 GPU）
//   2. 批量出图（配合 --out 目录）
//   3. 作为"算法回归"的固定入口：同一组参数必须给出同一张图
//
// 用法示例：
//   dart run bin/render.dart --bg 微水泥.png --time 2025-06-21T09:00:00+08:00 \
//        --lat 39.9042 --lon 116.4074 --window east --out out.png
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lightwall_core/lightwall_core.dart';

/// 罗盘朝向名 → 方位角。
const Map<String, double> kWindowAz = <String, double>{
  'n': 0,
  'ne': 45,
  'e': 90,
  'se': 135,
  's': 180,
  'sw': 225,
  'w': 270,
  'nw': 315,
  'north': 0,
  'east': 90,
  'south': 180,
  'west': 270,
  'left': 270,
  'right': 90,
};

void main(List<String> argv) {
  final args = _parseArgs(argv);
  if (args.containsKey('help')) {
    stdout.writeln(_usage);
    return;
  }

  final bgPath = args['bg'] ?? '';
  if (bgPath.isEmpty) {
    stderr.writeln('缺少 --bg（底图路径）');
    exitCode = 2;
    return;
  }
  if (!File(bgPath).existsSync()) {
    stderr.writeln('底图不存在: $bgPath');
    exitCode = 2;
    return;
  }

  final image = loadImageFile(bgPath);
  var w = image.width;
  var h = image.height;
  final outW = int.tryParse(args['width'] ?? '');
  final outH = int.tryParse(args['height'] ?? '');
  var rgb = image.rgb;
  if (outW != null && outH != null && (outW != w || outH != h)) {
    rgb = _resizeRgb(rgb, w, h, outW, outH);
    w = outW;
    h = outH;
  }

  final windowAz = _windowAzFrom(args['window'] ?? 'right');
  double _req(String k, double dflt, String name) {
    final raw = args[k];
    if (raw == null) return dflt;
    final v = double.tryParse(raw);
    if (v == null) {
      stderr.writeln('错误：--$k 不是有效数字 "$raw"（$name）');
      exit(2);
    }
    return v;
  }
  final lat = _req('lat', 39.9042, '纬度，北正');
  final lon = _req('lon', 116.4074, '经度，东正');
  DateTime time;
  final timeRaw = args['time'];
  if (timeRaw != null) {
    final t = DateTime.tryParse(timeRaw);
    if (t == null) {
      stderr.writeln('错误：无法解析时间 "$timeRaw"（示例：2025-06-21T09:00:00+08:00，务必带时区）');
      exit(2);
    }
    time = t;
  } else {
    time = DateTime.now();
  }

  Float32List? textAlpha;
  final maskPath = args['text-alpha'];
  int maskW = 0, maskH = 0;
  if (maskPath != null && File(maskPath).existsSync()) {
    final mask = loadImageFile(maskPath);
    maskW = mask.width; maskH = mask.height;
    if (maskW == w && maskH == h) {
      textAlpha = Float32List(w * h);
      for (var i = 0; i < w * h; i++) {
        textAlpha[i] = mask.rgb[i * 3] / 255.0;
      }
    }
  }

  if (textAlpha == null && maskPath != null) {
    stderr.writeln('错误：文字蒙版文件不存在 "$maskPath"');
    exit(2);
  } else if (textAlpha != null &&
      (maskW != w || maskH != h)) {
    stderr.writeln('错误：--text-alpha 蒙版尺寸 ${maskW}x${maskH} 与底图 ${w}x$h 不一致，'
        '请用同尺寸蒙版（生成端 make_text_mask.py 传相同 --width --height）');
    exit(2);
  }

  final style = (args['style'] ?? 'default').toLowerCase();
  final aged = switch (style) {
    'clean' => AgedParams.clean,
    'aged' || 'old' => AgedParams.aged,
    _ => const AgedParams(),
  };

  double? d(String k) => double.tryParse(args[k] ?? '');
  final sceneCfg = SceneConfig(
    gridRows: int.tryParse(args['grid-rows'] ?? '') ?? 3,
    gridCols: int.tryParse(args['grid-cols'] ?? '') ?? 2,
    gridFrameRatio: d('grid-frame') ?? 0.10,
    windowW: d('window-w') ?? 1.2,
    windowH: d('window-h') ?? 1.5,
    windowCy: d('window-cy') ?? 2.05,
    windowCz: d('window-cz') ?? -0.9,
    cameraH: d('camera-h') ?? 1.25,
    cameraDist: d('camera-dist') ?? 3.0,
    cameraFovDeg: d('fov') ?? 50.0,
    roomW: d('room-w') ?? 5.0,
    roomD: d('room-d') ?? 4.5,
  );

  final visibilityM = _req('visibility', 20000.0, '大气能见度，米');
  final look = LookConfig(
    exposure: double.tryParse(args['exposure'] ?? '') ?? 1.0,
    saturation: double.tryParse(args['saturation'] ?? '') ?? 1.0,
    materialStrength: double.tryParse(args['material'] ?? '') ?? 0.55,
  );

  final spec = RenderSpec(
    time: time,
    lat: lat,
    lon: lon,
    windowAz: windowAz,
    sceneCfg: SceneConfigValue(sceneCfg),
    gridRows: sceneCfg.gridRows,
    gridCols: sceneCfg.gridCols,
    gridFrameRatio: sceneCfg.gridFrameRatio,
    seed: int.tryParse(args['seed'] ?? '') ?? 20251014,
    aged: aged,
    visibilityM: visibilityM,
    materialCoupling: double.tryParse(args['coupling'] ?? '') ?? 0.0,
    look: look,
    applyAging: maskPath != null,
  );

  final sw = Stopwatch()..start();
  final result = render(
    baseRgb: rgb,
    width: w,
    height: h,
    spec: spec,
    textAlpha: textAlpha,
  );
  sw.stop();

  final outPath = args['out'] ?? 'out.png';
  File(outPath)
      .writeAsBytesSync(encodePng(result.rgb, result.width, result.height));

  final summary = <String, Object?>{
    'out': outPath,
    'size': '${result.width}x${result.height}',
    'ms': sw.elapsedMilliseconds,
    'source': result.light.source.name,
    'sun_alt': double.parse(result.light.sunAlt.toStringAsFixed(2)),
    'sun_az': double.parse(result.light.sunAz.toStringAsFixed(2)),
    'beam': double.parse(result.light.beamIrradiance.toStringAsFixed(4)),
    'diffuse': double.parse(result.light.diffuseIrradiance.toStringAsFixed(4)),
    'window_az': windowAz,
    'stats': result.albedoStats
        .map((k, v) => MapEntry(k, double.parse(v.toStringAsFixed(4)))),
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
}

double _windowAzFrom(String v) {
  final key = v.toLowerCase();
  if (kWindowAz.containsKey(key)) return kWindowAz[key]!;
  final num = double.tryParse(key);
  if (num != null) return num;
  return 90.0;
}

Uint8List _resizeRgb(Uint8List src, int sw, int sh, int dw, int dh) {
  final out = Uint8List(dw * dh * 3);
  final xr = sw / dw;
  final yr = sh / dh;
  for (var y = 0; y < dh; y++) {
    final sy = ((y + 0.5) * yr - 0.5).clamp(0, sh - 1);
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, sh - 1);
    final wy = sy - y0;
    for (var x = 0; x < dw; x++) {
      final sx = ((x + 0.5) * xr - 0.5).clamp(0, sw - 1);
      final x0 = sx.floor();
      final x1 = math.min(x0 + 1, sw - 1);
      final wx = sx - x0;
      for (var c = 0; c < 3; c++) {
        final a = src[(y0 * sw + x0) * 3 + c];
        final b = src[(y0 * sw + x1) * 3 + c];
        final cc = src[(y1 * sw + x0) * 3 + c];
        final d = src[(y1 * sw + x1) * 3 + c];
        final v =
            (a * (1 - wx) + b * wx) * (1 - wy) + (cc * (1 - wx) + d * wx) * wy;
        out[(y * dw + x) * 3 + c] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}

const String _usage = '''
LightWall 命令行渲染器（纯 Dart · 零 Flutter / GPU 依赖）

  在任何环境都能跑：不创建窗口、不链接 Flutter、不需要显卡驱动。
  图形环境不可用时（远程会话 / 无显卡虚拟机），用它代替
  light_wall.exe --render 出图。

  --bg <path>           底图路径（必需，PNG）
  --out <path>          输出 PNG（默认 out.png）
  --time <iso>          时间，如 2025-06-21T09:00:00+08:00（默认现在）
  --lat <deg> --lon <deg>
  --window <o>          窗户朝向：n/ne/e/se/s/sw/w/nw 或 left/right（默认 right）
  --grid-rows <n> --grid-cols <n> --grid-frame <0~1>
  --window-cy <m> --window-cz <m> --window-w <m> --window-h <m>
  --camera-h <m> --camera-dist <m> --fov <deg> --room-w <m> --room-d <m>
  --width <px> --height <px>
  --visibility <m>      大气能见度（米，默认 20000；影响太阳光谱衰减与环日散射占比）
  --style default|clean|aged
  --exposure --saturation --material --coupling
  --text-alpha <path>   文字 alpha 蒙版 PNG
  --seed <n>
  --help
''';

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[key] = argv[++i];
    } else {
      out[key] = '';
    }
  }
  return out;
}
