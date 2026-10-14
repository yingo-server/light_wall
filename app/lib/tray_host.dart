// 托盘宿主：常驻系统托盘，壁纸每 3 分钟一跳，面板随时能叫回来
//
// 职责边界（刻意收窄，避免和 main.dart 纠缠）：
//   · 建图标 + "打开面板 / 立即渲染 / 退出" 三项菜单
//   · 左键单击图标显示面板
//   · 销毁时 trayManager.destroy()
//
// 它不认识 AppSettings，也不管 RenderScheduler 的实现细节，
// 只接三个回调进来 —— 怎么接线是 main.dart 的事。
//
// 平台细节（照 tray_manager 0.5.x 的实际实现确认过）：
//   · setIcon 的路径参数会被拼成 `<exe目录>/data/flutter_assets/<iconPath>`，
//     所以这里必须传相对 asset 路径，传绝对路径会拼出四不像。
//   · 左键/右键事件通过 TrayListener 的无参回调给出，没有事件参数；
//     setIsRightClick(true) 之后右键才弹菜单，左键可由我们接管。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'assets_bridge.dart';

/// 托盘菜单项的键（MenuItem.key，便于日志与调试）。
class TrayKeys {
  const TrayKeys._();

  static const String show = 'lw_show';
  static const String render = 'lw_render';
  static const String quit = 'lw_quit';
}

/// 托盘宿主句柄。
class TrayHost {
  TrayHost({
    required this.onShowPanel,
    required this.onRenderNow,
    required this.onQuit,
  });

  /// 左键单击 / 点击"打开面板"时回调（应把窗口 show + focus）。
  final Future<void> Function() onShowPanel;

  /// 点击"立即渲染"时回调。
  final Future<void> Function() onRenderNow;

  /// 点击"退出"时回调（main.dart 负责保存设置 + 销毁托盘 + 退出进程）。
  final Future<void> Function() onQuit;

  /// 实现 TrayListener，才能收到托盘的鼠标事件（mixin，无构造参数）。
  ///
  /// 用 late final：onShowPanel 在构造期还没注入（它最终指向外壳），
  /// 所以放到 [init] 里再实例化，保证 [dispose] 时一定非空。
  _TrayListenerImpl? _listener;

  bool _ready = false;
  bool _disposed = false;

  /// 托盘是否已就绪（可用于设置页提示"托盘不可用"）。
  bool get isReady => _ready;

  /// 建托盘。任何失败都只记日志、不抛出 —— 托盘挂不上不该让应用起不来。
  Future<void> init() async {
    if (_ready || _disposed) return;
    try {
      // 相对路径即可，tray_manager 会自己拼上 data/flutter_assets 前缀
      await trayManager.setIcon(kAppIconAsset);

      await trayManager.setContextMenu(Menu(items: <MenuItem>[
        MenuItem(
          key: TrayKeys.show,
          label: '打开面板',
          onClick: (MenuItem item) => unawaited(onShowPanel()),
        ),
        MenuItem(
          key: TrayKeys.render,
          label: '立即渲染',
          onClick: (MenuItem item) => unawaited(onRenderNow()),
        ),
        MenuItem.separator(),
        MenuItem(
          key: TrayKeys.quit,
          label: '退出',
          onClick: (MenuItem item) => unawaited(onQuit()),
        ),
      ]));

      // 注：tray_manager 0.5.x 已移除 setIsRightClick —— 右键弹菜单
      // 是原生默认行为，左键事件走 _TrayListenerImpl 接管成"显示面板"。

      // 悬停提示（必须在 setIcon 之后调用）
      await trayManager.setToolTip('LightWall 光墙 · 壁纸每 3 分钟更新');

      _listener = _TrayListenerImpl(onLeftTap: onShowPanel);
      trayManager.addListener(_listener!);
      _ready = true;
    } catch (e) {
      _ready = false;
      debugPrint('托盘初始化失败（应用继续运行）：$e');
    }
  }

  /// 刷新托盘悬停提示（例如显示"下次更新 12:30"）。
  Future<void> setTooltip(String text) async {
    if (!_ready || _disposed) return;
    try {
      await trayManager.setToolTip(text);
    } catch (_) {
      // tooltip 是锦上添花，失败无所谓
    }
  }

  /// 销毁托盘（进程退出前必须调用，否则图标会残留在通知区域）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    try {
      final l = _listener;
      if (l != null) {
        trayManager.removeListener(l);
        _listener = null;
      }
    } catch (_) {
      // 忽略：监听可能从未注册成功
    }
    try {
      await trayManager.destroy();
    } catch (_) {
      // 已经销毁过了
    }
  }
}

/// 托盘事件桥：左键单击 → 显示面板；右键交给系统菜单。
class _TrayListenerImpl with TrayListener {
  _TrayListenerImpl({required this.onLeftTap});

  final Future<void> Function() onLeftTap;

  @override
  void onTrayIconMouseUp() {
    unawaited(onLeftTap());
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键弹菜单由原生侧处理，这里不需要动作。
  }

  @override
  void onTrayIconRightMouseUp() {
    // 同上；显式覆写是为了表明"我们确实看过这个事件"。
  }
}
