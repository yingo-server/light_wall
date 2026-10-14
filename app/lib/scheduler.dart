// 渲染调度器：每 3 分钟渲染一次并设为壁纸
//
// 关键设计：**渲染走 isolate**，绝不在 UI 线程做重活 ——
// 光线追踪是纯计算，放到 isolate 里跑，主线程只负责托盘与面板，
// 因此界面永远不卡。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:lightwall_core/lightwall_core.dart';

import 'settings.dart';
import 'variables.dart';
import 'win32.dart';

/// 一次渲染的输入。
class RenderJob {
  RenderJob({
    required this.baseRgb,
    required this.width,
    required this.height,
    required this.spec,
    required this.textAlpha,
    required this.outBmpPath,
    required this.outPngPath,
    required this.outputDir,
  });

  final Uint8List baseRgb;
  final int width;
  final int height;
  final RenderSpec spec;
  final Float32List? textAlpha;
  final String outBmpPath;

  /// 顺带存一份 PNG（便于在面板里预览与排查）。
  final String outPngPath;
  final String outputDir;
}

/// 渲染结果（从 isolate 传回）。
class RenderOutcome {
  RenderOutcome({
    required this.ok,
    required this.message,
    required this.text,
    required this.source,
    required this.sunAlt,
    required this.sunAz,
    required this.beam,
    required this.visibleRatio,
    required this.elapsedMs,
    required this.pngBytes,
  });

  final bool ok;
  final String message;

  /// 最终落到墙上的文案。
  final String text;
  final String source;
  final double sunAlt;
  final double sunAz;
  final double beam;
  final double visibleRatio;
  final int elapsedMs;

  /// 预览用 PNG 字节。
  final Uint8List pngBytes;
}

/// 文字光栅化（在 isolate 内完成，产出 alpha 蒙版）。
///
/// 之所以自己画而不直接用 Flutter 的 TextPainter：isolate 里没有
/// `dart:ui` 的字体引擎上下文，TextPainter 在后台 isolate 中不可靠。
/// 这里走 `ui.ParagraphBuilder` 的替代方案 —— 用 Canvas 记录绘制，
/// 再读回 alpha 通道。
Future<Float32List> rasterizeText({
  required String text,
  required String fontFamily,
  required int width,
  required int height,
  required double fontRatio,
  required double posX,
  required double posY,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = math.max(8.0, height * fontRatio);
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      fontFamily: fontFamily,
      fontSize: size,
      textAlign: TextAlign.center,
      maxLines: 4,
    ),
  );
  for (final line in _splitLines(text)) {
    builder.addText(line);
  }
  final paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: width.toDouble()));
  canvas.drawParagraph(
      paragraph,
      Offset((width * posX / 100) - paragraph.maxIntrinsicWidth / 2,
          (height * posY / 100) - paragraph.height / 2));
  final picture = recorder.endRecording();

  // 1x 光栅化到 alpha 图
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  image.dispose();
  final rgba = bytes!.buffer.asUint8List();
  final alpha = Float32List(width * height);
  for (var i = 0; i < width * height; i++) {
    alpha[i] = rgba[i * 4 + 3] / 255.0;
  }
  return alpha;
}

List<String> _splitLines(String text) {
  if (text.contains('\n')) {
    return text.split('\n').where((e) => e.trim().isNotEmpty).toList();
  }
  final t = text.replaceAll(',', '，');
  if (t.contains('，') && t.length > 3) {
    final parts = t.split('，');
    final out = <String>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      out.add(i < parts.length - 1 ? '${parts[i]}，' : parts[i]);
    }
    return out;
  }
  return <String>[t];
}

/// 渲染调度器。
class RenderScheduler {
  RenderScheduler(this.settings);

  final AppSettings settings;

  static const Duration interval = Duration(minutes: 3);

  Timer? _timer;
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);
  final ValueNotifier<RenderOutcome?> last = ValueNotifier<RenderOutcome?>(null);
  final ValueNotifier<DateTime?> nextRun = ValueNotifier<DateTime?>(null);
  final ValueNotifier<String> status = ValueNotifier<String>('待命');

  int _seq = 0;
  bool _running = false;

  /// 启动定时器。
  void start({bool renderNow = true}) {
    stop();
    if (renderNow) unawaited(render());
    scheduleNext();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (DateTime.now().isAfter(nextRun.value ?? DateTime.now())) {
        unawaited(render());
        scheduleNext();
      }
    });
  }

  void scheduleNext() {
    nextRun.value = DateTime.now().add(interval);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 立即渲染一次。
  Future<void> render() async {
    if (_running) return;
    _running = true;
    busy.value = true;
    status.value = '渲染中…';
    final started = DateTime.now();
    try {
      final outcome = await _runOnce();
      last.value = outcome;
      status.value = outcome.ok
          ? '已更新 · ${DateTime.now().hour.toString().padLeft(2, '0')}:'
              '${DateTime.now().minute.toString().padLeft(2, '0')}'
          : '失败：${outcome.message}';
      if (outcome.ok) {
        Win32.setWallpaper(outcome.pngBytes.isEmpty ? '' : _lastBmpPath);
      }
    } catch (e) {
      status.value = '异常：$e';
    } finally {
      busy.value = false;
      _running = false;
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (ms < 1000) {
        // 保持"每 3 分钟"的节奏，不因单次快渲染而提前
        await Future<void>.delayed(Duration(milliseconds: 1000 - ms));
      }
      scheduleNext();
    }
  }

  String _lastBmpPath = '';

  Future<RenderOutcome> _runOnce() async {
    final now = DateTime.now();
    final dir = Directory('${Win32.dataDir().path}\\wallpapers')
      ..createSync(recursive: true);
    _cleanup(dir, keep: 24);

    // 1) 底图
    final base = _loadBase();

    // 2) 文案：模板 → 变量 → 渲染
    final seq = _seq++;
    final ctx = Variables.build(
      now: now,
      lat: settings.lat,
      lon: settings.lon,
      windowAz: settings.windowAz,
      seq: seq,
    );
    final engine = TemplateEngine(ctx);
    final text = engine.render(settings.template).trim();

    // 3) 文字 alpha
    final alpha = text.isEmpty
        ? null
        : await rasterizeText(
            text: text,
            fontFamily: settings.fontFamily,
            width: base.width,
            height: base.height,
            fontRatio: settings.fontRatio,
            posX: settings.posX,
            posY: settings.posY,
          );

    // 4) 交给 isolate 做光追
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final bmpPath = '${dir.path}\\lw_$stamp.bmp';
    final pngPath = '${dir.path}\\lw_$stamp.png';
    _lastBmpPath = bmpPath;

    final job = RenderJob(
      baseRgb: base.rgb,
      width: base.width,
      height: base.height,
      spec: RenderSpec(
        time: now,
        lat: settings.lat,
        lon: settings.lon,
        windowAz: settings.windowAz,
        seed: 20251014 + seq,
        aged: settings.agedParams,
        materialCoupling: settings.materialCoupling,
        gridRows: settings.gridRows,
        gridCols: settings.gridCols,
        gridFrameRatio: settings.gridFrameRatio,
        look: LookConfig(
          exposure: settings.exposure,
          saturation: settings.saturation,
        ),
      ),
      textAlpha: alpha,
      outBmpPath: bmpPath,
      outPngPath: pngPath,
      outputDir: dir.path,
    );

    final sw = Stopwatch()..start();
    final result = await Isolate.run(() => _renderInIsolate(job));
    sw.stop();

    if (result.ok) {
      Win32.setWallpaper(job.outBmpPath);
      return RenderOutcome(
        ok: true,
        message: '完成',
        text: text,
        source: result.source,
        sunAlt: result.sunAlt,
        sunAz: result.sunAz,
        beam: result.beam,
        visibleRatio: result.visibleRatio,
        elapsedMs: sw.elapsedMilliseconds,
        pngBytes: result.png,
      );
    }
    return RenderOutcome(
      ok: false,
      message: result.message,
      text: text,
      source: '',
      sunAlt: 0,
      sunAz: 0,
      beam: 0,
      visibleRatio: 0,
      elapsedMs: sw.elapsedMilliseconds,
      pngBytes: Uint8List(0),
    );
  }

  /// 载入底图（内置资源或用户文件），并按屏幕尺寸缩放。
  ({Uint8List rgb, int width, int height}) _loadBase() {
    // 用户导入的底图（轮换）
    if (settings.backgrounds.isNotEmpty) {
      final idx = settings.backgroundCursor % settings.backgrounds.length;
      settings.backgroundCursor = (settings.backgroundCursor + 1) % settings.backgrounds.length;
      try {
        final f = File(settings.backgrounds[idx]);
        if (f.existsSync()) {
          final img = decodePng(f.readAsBytesSync());
          return _fit(img, Win32.screenSize);
        }
      } catch (_) {}
    }
    final asset = kBuiltinBackgrounds[
        settings.builtinIndex % kBuiltinBackgrounds.length];
    final bytes = _readAssetBytes(asset);
    if (bytes != null) {
      final img = decodePng(bytes);
      return _fit(img, Win32.screenSize);
    }
    // 兜底：程序生成一张中性灰墙
    final size = Win32.screenSize;
    final rgb = Uint8List(size.$1 * size.$2 * 3);
    for (var i = 0; i < size.$1 * size.$2; i++) {
      final n = valueNoise((i % size.$1) / 9.0, (i ~/ size.$1) / 9.0, 3);
      final v = (146 + 22 * n).round().clamp(0, 255);
      rgb[i * 3] = v;
      rgb[i * 3 + 1] = (v * 0.985).round();
      rgb[i * 3 + 2] = (v * 0.95).round();
    }
    return (rgb: rgb, width: size.$1, height: size.$2);
  }

  ({Uint8List rgb, int width, int height}) _fit(
      ({Uint8List rgb, int width, int height}) img, (int, int) screen) {
    if (img.width == screen.$1 && img.height == screen.$2) return img;
    final scaled = resizeRgbBytes(img.rgb, img.width, img.height, screen.$1, screen.$2);
    return (rgb: scaled, width: screen.$1, height: screen.$2);
  }

  void _cleanup(Directory dir, {required int keep}) {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bmp') || f.path.endsWith('.png'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(keep)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// 内置底图（打包在资源里）。
const List<String> kBuiltinBackgrounds = <String>[
  'assets/backgrounds/microcement.png',
  'assets/backgrounds/bluebrick.png',
  'assets/backgrounds/concrete.png',
];

Uint8List? _readAssetBytes(String path) {
  // 通过 rootBundle 读取；失败返回 null
  return _assetLoader?.call(path);
}

Uint8List? Function(String path)? _assetLoader;

void setAssetLoader(Uint8List? Function(String path) loader) {
  _assetLoader = loader;
}

/// 在 isolate 内执行渲染（顶层函数，便于 Isolate.run）。
Future<_RawRenderResult> _renderInIsolate(RenderJob job) async {
  final result = render(
    baseRgb: job.baseRgb,
    width: job.width,
    height: job.height,
    spec: job.spec,
    textAlpha: job.textAlpha,
  );
  final png = encodePng(result.rgb, result.width, result.height);
  try {
    File(job.outBmpPath).writeAsBytesSync(
        encodeBmp(result.rgb, result.width, result.height), flush: true);
  } catch (e) {
    return _RawRenderResult(false, '写 BMP 失败: $e', '', 0, 0, 0, 0, Uint8List(0));
  }
  try {
    File(job.outPngPath).writeAsBytesSync(png, flush: true);
  } catch (_) {}
  return _RawRenderResult(
    true,
    '',
    result.light.source.name,
    result.light.sunAlt,
    result.light.sunAz,
    result.light.beamIrradiance,
    result.albedoStats['visible_ratio'] ?? 0,
    png,
  );
}

class _RawRenderResult {
  _RawRenderResult(this.ok, this.message, this.source, this.sunAlt, this.sunAz,
      this.beam, this.visibleRatio, this.png);

  final bool ok;
  final String message;
  final String source;
  final double sunAlt;
  final double sunAz;
  final double beam;
  final double visibleRatio;
  final Uint8List png;
}

/// 三通道字节缩放。
Uint8List resizeRgbBytes(Uint8List src, int sw, int sh, int dw, int dh) {
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
        final v = (a * (1 - wx) + b * wx) * (1 - wy) +
            (cc * (1 - wx) + d * wx) * wy;
        out[(y * dw + x) * 3 + c] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}
