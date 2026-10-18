// LightWall TUI 向导（Linux/Android-Termux）
//
// 纯 Dart，零第三方依赖。逐项询问渲染参数：回车取默认/网络默认，
// 主动询问一次，答完即渲染。也接受与 render.dart 相同的 --flags 跳过询问。
//
// 用法：
//   ./lightwall_tui            交互向导
//   ./lightwall_tui --help     参数说明（同 render.dart）
import 'dart:convert';
import 'dart:io';

/// 从 stdin 读一行；EOF/空输入返回 null（→ 调用方取默认）。
String? askLine(String prompt, String def, {String? hint}) {
  final h = hint == null ? '' : '  ($hint)';
  stdout.write('$prompt [默认: $def]$h > ');
  final line = stdin.readLineSync(encoding: utf8);
  final v = line?.trim() ?? '';
  return v.isEmpty ? null : v;
}

void main(List<String> argv) {
  // 非交互模式：把参数原样转交 render.dart 的逻辑（同目录同版本）。
  if (argv.isNotEmpty) {
    // 转发语义：本工具不带参数时才做向导；带参数时直接提示并退出。
    stdout.writeln('TUI 向导不接受命令行参数。带参数渲染请用 lightwall_render；'
        '交互模式请直接运行 lightwall_tui（无参数）。');
    exitCode = 2;
    return;
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final renderPath = '$exeDir/lightwall_render';
  if (!File(renderPath).existsSync() && !File('$renderPath.exe').existsSync()) {
    stderr.writeln('未找到同目录的 lightwall_render 渲染内核：$renderPath');
    exitCode = 2;
    return;
  }

  stdout.writeln('══════════ LightWall 渲染向导 ══════════');
  stdout.writeln('逐项输入，直接回车取【默认】值。\n');

  final answers = <String, String>{};

  String ask(String key, String prompt, String def, {String? hint}) {
    final v = askLine(prompt, def, hint: hint);
    answers[key] = v ?? def;
    return answers[key]!;
  }

  // ── 底图：同目录找 *.png，找到就默认用，多张时询问 ──
  final pngs = Directory(exeDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.png'))
      .map((f) => f.path.split(Platform.pathSeparator).last)
      .toList();
  String bg;
  if (pngs.isEmpty) {
    bg = ask('bg', '底图 PNG 路径', 'wall.png');
  } else if (pngs.length == 1) {
    bg = pngs.first;
    stdout.writeln('底图：$bg（同目录自动发现）');
    answers['bg'] = bg;
  } else {
    stdout.writeln('发现多张底图：${pngs.join(", ")}');
    bg = ask('bg', '底图文件名', pngs.first);
  }

  // ── 网络/地点参数（回车即默认：北京）──
  final lat = ask('lat', '纬度（北正）', '39.9042');
  final lon = ask('lon', '经度（东正）', '116.4074');
  final tz = ask('tz', '时区（ISO 偏移）', '+08:00');
  final window = ask('window', '窗户朝向 n/ne/e/se/s/sw/w/nw', 'e');

  // ── 时间 ──
  final now = DateTime.now().toLocal();
  final nowIso =
      '${now.year.toString().padLeft(4, "0")}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}'
      'T${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:00$tz';
  final time = ask('time', '时间（ISO，须带时区）', nowIso);

  // ── 丙类可选（默认全关）──
  // 室内灯默认值时间感知：夜里渲染必然全黑（无室内灯时），
  // 向导按当前小时给默认 0.6，白天回车即 0。
  final hour = now.hour;
  final indoorDef = (hour >= 18 || hour < 6) ? '0.6' : '0';
  final indoor = ask('indoor-light', '室内灯相对强度（夜间默认 0.6）', indoorDef);
  final cloud = ask('cloud', '云量 0~1', '0');
  final cityGlow = ask('city-glow', '城市光污染（市区≈2）', '0');
  final lux = ask('absolute-lux', '绝对量纲 lux（回车=自动曝光）', '');

  // ── 输出 ──
  final width = ask('width', '输出宽度（px）', '1280');
  final height = ask('height', '输出高度（px）', '720');
  final out = ask('out', '输出文件', 'lightwall.png');

  stdout.writeln('\n参数确认：');
  answers.forEach((k, v) => stdout.writeln('  $k = ${v.isEmpty ? "（自动）" : v}'));
  stdout.write('\n开始渲染？回车继续 / 输入 n 退出 > ');
  final go = stdin.readLineSync(encoding: utf8)?.trim().toLowerCase();
  if (go == 'n' || go == 'no') {
    stdout.writeln('已取消。');
    return;
  }

  final args = <String>[
    '--bg', bg,
    '--lat', lat,
    '--lon', lon,
    '--window', window,
    '--time', time,
    '--cloud', cloud,
    '--city-glow', cityGlow,
    '--indoor-light', indoor,
    '--width', width,
    '--height', height,
    '--out', out,
  ];
  // tz 不透传：time 已带偏移；absolute-lux 仅在非空时传。
  args.removeWhere((a) => a == '--tz-unused');
  if (lux.trim().isNotEmpty) args.addAll(['--absolute-lux', lux.trim()]);

  stdout.writeln('\n渲染中…');
  final sw = Stopwatch()..start();
  final r = Process.runSync(renderPath, args);
  sw.stop();
  stdout.write(r.stdout);
  if (r.exitCode != 0) {
    stderr.write(r.stderr);
    exitCode = r.exitCode;
    return;
  }
  final f = File(out);
  stdout.writeln(
      '\n完成：$out（${f.existsSync() ? f.lengthSync() : 0} 字节，${sw.elapsedMilliseconds} ms）');
}
