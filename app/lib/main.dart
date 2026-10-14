// LightWall · 应用入口
//
// 三条启动路径共用一份初始化，区别只在"干完活要不要留在窗口里"：
//
//   默认        载入设置 → 起窗口 → 起托盘 → 起调度器 → 挂面板（常驻）
//   --render    渲染一张写到 --out（或默认目录）→ 进程退出（CI / 脚本用）
//   --shot      按 --ui-page 渲染某页界面 → 抓图存到 --shot 指定的 png → 退出
//               （GitHub Actions 的无头 UI 回归用）
//
// 任何一步失败都不让进程崩：兜底渲染 [_FatalApp]，说明原因并给一个退出按钮。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart';
import 'package:window_manager/window_manager.dart';

import 'assets_bridge.dart';
import 'panel.dart';
import 'scheduler.dart';
import 'settings.dart';
import 'tray_host.dart';

// ─────────────────────────────────────────────────────────────
// 1) 命令行参数
// ─────────────────────────────────────────────────────────────

/// `--ui-page` 的合法取值。
const List<String> kUiPages = <String>['home', 'text', 'bg', 'settings'];

/// 解析出来的命令行参数。
class CliOptions {
  const CliOptions({
    required this.help,
    required this.renderOnce,
    required this.outPath,
    required this.shotPath,
    required this.uiPage,
    required this.errors,
  });

  /// 打印帮助后退出。
  final bool help;

  /// `--render`：渲染一张后退出。
  final bool renderOnce;

  /// `--out <path>`：渲染结果另存到该路径。
  final String? outPath;

  /// `--shot <png>`：截图指定页面后退出。
  final String? shotPath;

  /// `--ui-page <home|text|bg|settings>`：要截图的页面。
  final String uiPage;

  /// 参数错误（打印到 stderr 并以退出码 2 结束）。
  final List<String> errors;

  /// 是否是"跑完就退出"的一次性任务。
  bool get isOneShot => help || renderOnce || shotPath != null;

  static const String usage = '''
LightWall 光墙 —— Windows 物理光照壁纸引擎

用法：light_wall.exe [选项]

选项：
  --render                 渲染一张壁纸后立即退出（不显示托盘）
  --out <path>             与 --render 配合，把结果另存为该文件
  --shot <path.png>        截取界面并写入 PNG 后退出（CI UI 回归用）
  --ui-page <page>         --shot 要截的页面：home|text|bg|settings
                           默认 home
  --help, -h               显示本帮助并退出

示例：
  light_wall.exe
  light_wall.exe --render --out C:\\tmp\\wall.png
  light_wall.exe --shot ui-home.png --ui-page home
''';

  /// 解析 [args]。未知参数不致命，只记进 [errors]。
  factory CliOptions.parse(List<String> args) {
    var help = false;
    var renderOnce = false;
    String? out;
    String? shot;
    var page = 'home';
    final errors = <String>[];

    // 注：Dart 的 switch 不允许像 C 那样贯穿，必须逐 case 跳出，
    // 因此这里用「取值 → 分派」的形式，而不是 fall-through。
    String? valueOf(String name) {
      if (i + 1 >= args.length) {
        errors.add('$name 缺少参数');
        return null;
      }
      return args[++i];
    }

    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      switch (a) {
        case '--help':
        case '-h':
        case '/?':
          help = true;
          break;
        case '--render':
          renderOnce = true;
          break;
        case '--out':
          out = valueOf('--out');
          break;
        case '--shot':
          shot = valueOf('--shot');
          break;
        case '--ui-page':
          final v = valueOf('--ui-page')?.toLowerCase();
          if (v == null) {
            break;
          }
          if (!kUiPages.contains(v)) {
            errors.add('--ui-page 取值非法：$v（可选 ${kUiPages.join('/')}）');
          } else {
            page = v;
          }
          break;
        default:
          errors.add('未知参数：$a');
          break;
      }
    }
    return CliOptions(
      help: help,
      renderOnce: renderOnce,
      outPath: out,
      shotPath: shot,
      uiPage: page,
      errors: errors,
    );
  }
}

/// `--ui-page` → 面板左侧导航栏的页签下标（与 PanelPage 内部顺序一致）。
int uiPageIndex(String page) => switch (page) {
      'text' => 1,
      'bg' => 2,
      'settings' => 3,
      _ => 0,
    };

// ─────────────────────────────────────────────────────────────
// 2) 入口
// ─────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final cli = CliOptions.parse(args);
  if (cli.errors.isNotEmpty) {
    for (final e in cli.errors) {
      stderr.writeln('[LightWall] 参数错误：$e');
    }
    stderr.writeln(CliOptions.usage);
    exitCode = 2;
    return;
  }
  if (cli.help) {
    stdout.writeln(CliOptions.usage);
    return;
  }

  try {
    if (cli.renderOnce) {
      await _runRenderOnce(cli);
    } else if (cli.shotPath != null) {
      await _runShot(cli);
    } else {
      await _runInteractive();
    }
  } catch (e, st) {
    // 兜底：一次性任务里没有窗口，直接写 stderr + 退出码；
    // 常驻路径则弹一个 Material 错误页，而不是让进程静默消失。
    if (cli.isOneShot) {
      stderr.writeln('[LightWall] 致命错误：$e');
      stderr.writeln(st);
      exitCode = 1;
      return;
    }
    debugPrint('[LightWall] 致命错误：$e\n$st');
    runApp(_FatalApp(error: '$e', stack: '$st'));
  }
}

// ─────────────────────────────────────────────────────────────
// 3) `--render`：渲染一张 → 落盘 → 退出
// ─────────────────────────────────────────────────────────────

/// 渲染一次并写文件。
///
/// 结构上刻意不碰 window_manager / tray_manager：CI 上跑它时既不需要窗口，
/// 也不需要托盘，少一层原生依赖就少一处失败点。
Future<void> _runRenderOnce(CliOptions cli) async {
  final settings = AppSettings.load();

  // 资源桥：已构建的 exe 里资源在 data/flutter_assets 下，磁盘读比
  // PlatformChannel 更稳；读不到再退回预热的内存缓存。
  setAssetLoader((String path) =>
      loadAssetBytesFromDisk(path) ?? loadAssetBytesSync(path));
  await initAssets();

  final scheduler = RenderScheduler(settings);
  stdout.writeln('[LightWall] 开始渲染…  模板「${settings.template}」');
  await scheduler.render();

  final out = scheduler.last.value;
  if (out == null || !out.ok) {
    stderr.writeln('[LightWall] 渲染失败：${out?.message ?? '未知错误'}');
    exitCode = 1;
    return;
  }
  if (cli.outPath != null) {
    try {
      final target = File(cli.outPath!);
      if (target.parent.path.isNotEmpty) {
        target.parent.createSync(recursive: true);
      }
      target.writeAsBytesSync(out.pngBytes, flush: true);
      stdout.writeln('[LightWall] 已写入 ${target.path}');
    } catch (e) {
      stderr.writeln('[LightWall] 写入 ${cli.outPath} 失败：$e');
      exitCode = 1;
      return;
    }
  }
  stdout.writeln('[LightWall] 渲染完成 ${out.elapsedMs} ms · '
      '光源 ${out.source} · 太阳高度 ${out.sunAlt.toStringAsFixed(1)}° · '
      '直射光斑 ${(out.visibleRatio * 100).toStringAsFixed(1)}%');
}

// ─────────────────────────────────────────────────────────────
// 4) `--shot`：无头截图 → 退出（GitHub Actions UI 回归）
// ─────────────────────────────────────────────────────────────

/// 截一张指定页面的图然后退出。
///
/// CI 友好的三个要点：
///   1. 不用 `window_manager`，不 show()/hide()，因此不依赖桌面会话；
///      截图内容来自一棵独立的 Widget 树，窗口可见不可见都无所谓。
///   2. 抓图走 `RenderRepaintBoundary.toImage()` —— 纯软件光栅，
///      无 GPU 的 runner 上照样出 PNG。
///   3. 只等有限帧数（建树 → 选中页签 → 重绘），然后立刻写文件退出，
///      不会在 CI 上挂死等一个"永远不会来的事件"。
Future<void> _runShot(CliOptions cli) async {
  final settings = AppSettings.load();

  // 截图模式下同样用磁盘优先的资源读取，保证离线可复现。
  setAssetLoader((String path) =>
      loadAssetBytesFromDisk(path) ?? loadAssetBytesSync(path));
  await initAssets();

  final scheduler = RenderScheduler(settings);
  // 让"概览"页有真实的预览图与光照数据可截。
  await scheduler.render();

  final boundary = GlobalKey(debugLabel: 'lw_shot_boundary');
  runApp(_ShotApp(
    settings: settings,
    scheduler: scheduler,
    boundaryKey: boundary,
  ));

  await _pumpFrames(4);

  final index = uiPageIndex(cli.uiPage);
  if (index != 0) {
    final ok = await _selectNavRailTab(boundary, index);
    if (ok) {
      await _pumpFrames(4);
    } else {
      // 兜底：模拟点击失败就退回概览页，仍然产出图片，不让 CI 红掉。
      stdout.writeln('[LightWall] 警告：无法切换到「${cli.uiPage}」页，'
          '已退回概览页截图');
    }
  }

  final bytes = await _capturePng(boundary);
  if (bytes == null) {
    stderr.writeln('[LightWall] 截图失败：拿不到 PNG 字节');
    exitCode = 1;
    return;
  }
  try {
    final f = File(cli.shotPath!);
    if (f.parent.path.isNotEmpty) {
      f.parent.createSync(recursive: true);
    }
    f.writeAsBytesSync(bytes, flush: true);
    stdout.writeln('[LightWall] 截图已保存：${f.path}（页面 ${cli.uiPage}）');
  } catch (e) {
    stderr.writeln('[LightWall] 写入截图失败：$e');
    exitCode = 1;
    return;
  }
  // runApp 之后不会自动退出，必须显式结束进程。
  exit(0);
}

/// 连续推 [times] 帧，等布局与光栅化落定。
Future<void> _pumpFrames(int times) async {
  final binding = WidgetsBinding.instance;
  for (var i = 0; i < times; i++) {
    await binding.endOfFrame;
    // 让出一轮事件循环，保证异步的字体/图片解码有机会完成。
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 从 [boundary] 对应的 RepaintBoundary 抓一张 PNG。
Future<Uint8List?> _capturePng(GlobalKey boundary) async {
  final ctx = boundary.currentContext;
  if (ctx == null) return null;
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) return null;
  if (obj.debugNeedsPaint) {
    // 还没画完，再等一帧
    await WidgetsBinding.instance.endOfFrame;
  }
  try {
    final ui.Image image = await obj.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (e) {
    debugPrint('[LightWall] 截图异常：$e');
    return null;
  }
}

/// 用"合成一次点击"的方式把面板切到第 [index] 个页签，返回是否成功。
///
/// 为什么这么绕：PanelPage 的页签是它的私有 State，且是已完成、不可修改的
/// 文件，这里既拿不到它的 controller，也不能给它加参数。于是退一步，
/// 找到左侧 NavigationRail 的渲染框，按 4 等分算出目标页签的中心，
/// 直接向 GestureBinding 投递一对 down/up 指针事件 —— 效果和用户用鼠标点
/// 完全一致，走的是同一条命中测试路径。
///
/// CI 专用假设：导航栏没有 leading 项，4 个目的地均分整个高度。
/// 若将来 PanelPage 加了 leading，这里需要改 `_kNavDestinations`。
Future<bool> _selectNavRailTab(GlobalKey boundary, int index) async {
  const int _kNavDestinations = 4;
  try {
    final ctx = boundary.currentContext;
    if (ctx == null) return false;
    final rail = _findRailElement(ctx);
    if (rail == null) return false;
    final box = rail.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;

    final step = box.size.height / _kNavDestinations;
    final local = Offset(box.size.width / 2, step * (index + 0.5));
    final global = box.localToGlobal(local);

    final gestures = GestureBinding.instance;
    const kind = PointerDeviceKind.touch;
    gestures.handlePointerEvent(const PointerDownEvent(
      position: global,
      kind: kind,
    ));
    gestures.handlePointerEvent(const PointerUpEvent(
      position: global,
      kind: kind,
    ));
    return true;
  } catch (e) {
    debugPrint('[LightWall] 切换页签失败：$e');
    return false;
  }
}

/// 在 [ctx] 的子树里找出 NavigationRail 对应的 Element。
Element? _findRailElement(Element ctx) {
  Element? found;
  ctx.visitChildren((Element child) {
    if (found != null) return;
    if (child.widget.runtimeType.toString() == 'NavigationRail') {
      found = child;
      return;
    }
    found ??= _findRailElement(child);
  });
  return found;
}

/// `--shot` 专用的根组件：外面套一层 RepaintBoundary 供截图取用。
class _ShotApp extends StatelessWidget {
  const _ShotApp({
    required this.settings,
    required this.scheduler,
    required this.boundaryKey,
  });

  final AppSettings settings;
  final RenderScheduler scheduler;
  final GlobalKey boundaryKey;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: boundaryKey,
      child: PanelPage(
        settings: settings,
        scheduler: scheduler,
        // 截图模式下没有任何人点"关闭"，给个空实现即可。
        onExit: () {},
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 5) 默认路径：常驻窗口 + 托盘 + 定时渲染
// ─────────────────────────────────────────────────────────────

/// 常驻外壳：把设置、调度器、托盘和退出流程绑在一起。
///
/// 之所以单独抽一个类：托盘回调、窗口关闭回调、错误页按钮三处都要能触发
/// "保存 + 停表 + 销毁托盘 + 退出"，散着写必然漏掉一处。
class LightWallShell {
  LightWallShell({
    required this.settings,
    required this.scheduler,
    required this.tray,
  });

  final AppSettings settings;
  final RenderScheduler scheduler;
  final TrayHost tray;

  bool _quitting = false;

  /// 窗口/面板的"关闭"请求：按设置决定隐藏到托盘还是真退出。
  Future<void> handleCloseRequest() async {
    if (settings.hideToTray) {
      await _hide();
    } else {
      await quit();
    }
  }

  /// 从托盘把面板叫回来。
  Future<void> showPanel() async {
    await _guard(() async {
      await windowManager.show();
      await windowManager.focus();
      // 面板可见时不要占任务栏？占一个位置更符合"这是个应用"的直觉，
      // 这里保持显示，隐藏到托盘时 windowManager 会自动去掉。
      await windowManager.setSkipTaskbar(false);
    });
  }

  /// 隐藏到托盘（壁纸继续每 3 分钟更新）。
  Future<void> hideToTray() => _hide();

  /// 真正的退出：收尾干净，不留残余图标、不丢设置。
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    scheduler.stop();
    try {
      settings.save();
    } catch (_) {
      // 存不进去也不能挡住退出
    }
    await tray.dispose();
    await _guard(() async {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    });
    exit(0);
  }

  Future<void> _hide() => _guard(() => windowManager.hide());

  /// 窗口管理相关的调用都可能抛（无窗口/平台不支持），统一吞掉。
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('[LightWall] 窗口操作失败：$e');
    }
  }
}

/// 起窗口、起托盘、起调度器，最后挂上面板。
Future<void> _runInteractive() async {
  // ① 载入设置
  final settings = AppSettings.load();

  // ② 窗口管理器 + 资源桥
  await windowManager.ensureInitialized();
  await initAssets();

  // ③ 渲染调度器
  final scheduler = RenderScheduler(settings);

  // ④ 窗口：尺寸、居中、不占任务栏、关闭走我们的回调
  //
  // 这里不用 windowManager.waitUntilReadyToShow —— 各版本签名不兼容，
  // 直接顺序调用 setXxx 更稳，也更容易看出每一步在干什么。
  const size = Size(1120, 760);
  await windowManager.setPreventClose(true);
  await windowManager.setMinimumSize(const Size(920, 600));
  await windowManager.setSize(size);
  await windowManager.center();
  await windowManager.setSkipTaskbar(true);
  // hideToTray 为真时，启动就只留托盘（自启场景不该弹窗）
  if (!settings.hideToTray) {
    await windowManager.show();
  }

  // ⑤ 托盘：图标 + 三项菜单 + 左键单击唤回面板
  final tray = TrayHost(
    onShowPanel: () => _pendingShell?.showPanel() ?? Future<void>.value(),
    onRenderNow: () => scheduler.render(),
    onQuit: () => _pendingShell?.quit() ?? Future<void>.value(),
  );
  await tray.init();

  // ⑥ 组装外壳并接管窗口关闭事件
  final shell = LightWallShell(
    settings: settings,
    scheduler: scheduler,
    tray: tray,
  );
  _pendingShell = shell;
  windowManager.addListener(_WindowListener(shell: shell));

  // ⑦ 起调度器：是否立刻渲染一张由设置决定
  scheduler.start(renderNow: settings.renderOnStart);

  // ⑧ 挂面板
  runApp(_LightWallApp(
    settings: settings,
    scheduler: scheduler,
    shell: shell,
  ));
}

/// 托盘回调比外壳先建好，需要一个可空引用把两者接起来。
LightWallShell? _pendingShell;

/// 应用根：本身不含 MaterialApp（PanelPage 自带），这里只做状态转发。
class _LightWallApp extends StatelessWidget {
  const _LightWallApp({
    required this.settings,
    required this.scheduler,
    required this.shell,
  });

  final AppSettings settings;
  final RenderScheduler scheduler;
  final LightWallShell shell;

  @override
  Widget build(BuildContext context) => PanelPage(
        settings: settings,
        scheduler: scheduler,
        // 面板右上角的关闭按钮与窗口关闭行为保持一致
        onExit: () => unawaited(shell.handleCloseRequest()),
      );
}

/// 窗口事件监听：只关心"关闭"。
class _WindowListener extends WindowListener {
  _WindowListener({required this.shell});

  final LightWallShell shell;

  @override
  void onWindowClose() {
    unawaited(shell.handleCloseRequest());
  }
}

// ─────────────────────────────────────────────────────────────
// 6) 兜底错误页
// ─────────────────────────────────────────────────────────────

/// 初始化失败时显示的页面：说明原因 + 一个退出按钮。
///
/// 宁可给用户一个能看、能复制错误的窗口，也不要让进程静默消失。
class _FatalApp extends StatelessWidget {
  const _FatalApp({required this.error, required this.stack});

  final String error;
  final String stack;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF7A5B3A));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('LightWall 启动失败')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.error_outline,
                  size: 48, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text('LightWall 遇到问题，没能正常启动：',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    '$error\n\n$stack',
                    style:
                        const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => exit(1),
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('退出'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
