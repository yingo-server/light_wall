// 资源桥：把 Flutter 的 rootBundle 接到 scheduler 的资源加载钩子上
//
// scheduler.dart 是纯 Dart/无 Flutter 依赖的渲染侧代码，它只认
// `Uint8List? Function(String path)` 这个函数指针。本文件用
// rootBundle 把它实现出来，并在 isolate 不可用时给出可读的降级路径，
// 保证"加载不到就退化成程序生成的灰墙"，而不是让进程崩掉。
//
// 注意：这里**再导出一份** `kBuiltinBackgrounds`，供 panel.dart 使用。
// scheduler.dart 里也有一份同名的（渲染侧要用，不能依赖 Flutter）。
// 两处必须保持一致——panel 里要显示缩略图，所以路径字符串要完全相同。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'scheduler.dart' show setAssetLoader;
import 'win32.dart' show Win32;

/// 内置底图清单（与 scheduler.dart 中的同名常量保持一致）。
///
/// 第一条 import 用 `show` 只取 setAssetLoader，避免本文件的
/// `kBuiltinBackgrounds` 与 scheduler 的同名常量互相污染。
const List<String> kBuiltinBackgrounds = <String>[
  'assets/backgrounds/microcement.png',
  'assets/backgrounds/bluebrick.png',
  'assets/backgrounds/concrete.png',
];

/// 托盘 / 窗口图标（打包在 assets/icon/ 下）。
const String kAppIconAsset = 'assets/icon/lw.png';

/// 把 rootBundle 接进 scheduler，并顺便把内存缓存填满。
///
/// 必须在 `WidgetsFlutterBinding.ensureInitialized()` **之后**、任何一次
/// 渲染**之前**调用。返回值是加载失败的资源路径，正常情况下为空列表。
Future<List<String>> initAssets() async {
  // 1) 先注册同步加载器：scheduler 的渲染流程是同步的，不能返回 Future。
  setAssetLoader(loadAssetBytesSync);

  // 2) 再后台预热：把内置底图一次性读进内存，避免每 3 分钟的渲染
  //    首次访问时卡一下 asset bundle。
  final failed = <String>[];
  for (final path in kBuiltinBackgrounds) {
    final bytes = await _rootBundleBytes(path);
    if (bytes == null) {
      failed.add(path);
    } else {
      _cache[path] = bytes;
    }
  }
  try {
    final icon = await _rootBundleBytes(kAppIconAsset);
    if (icon != null) _cache[kAppIconAsset] = icon;
  } catch (_) {
    // 图标不是关键路径，缺了顶多托盘是默认图标
  }
  return failed;
}

/// 读取资源字节；失败返回 null（**不抛异常**）。
Future<Uint8List?> loadAssetBytes(String path) => _rootBundleBytes(path);

/// scheduler 使用的同步加载器：只查内存缓存，命中不了就返回 null。
///
/// 为什么不用 rootBundle 的同步接口：bundle 的 PlatformChannel 往返是
/// Future 的，硬同步会抛。这里选择"预热 + 只读缓存"，行为确定。
Uint8List? loadAssetBytesSync(String path) => _cache[path];

/// 调试/CI 用：把资源字节从磁盘读出来（不走 bundle）。
///
/// 供 `--shot` 这类无头路径复用 —— CI 里跑的是已构建的 exe，
/// 资源在 `data/flutter_assets/` 下，可以直接按文件读，比 bundle 更稳。
Uint8List? loadAssetBytesFromDisk(String path, {String? assetsRoot}) {
  final root = assetsRoot ?? _defaultAssetsRoot();
  if (root == null) return null;
  final f = File('$root${_toWinPath(path)}');
  try {
    if (!f.existsSync()) return null;
    return f.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

/// 资源根目录：`<exe同级>/data/flutter_assets`。
String? _defaultAssetsRoot() {
  try {
    final exe = File(Win32.executablePath());
    final data = exe.parent.path;
    final root = '$data${_toWinPath("data/flutter_assets")}';
    return Directory(root).existsSync() ? root : null;
  } catch (_) {
    return null;
  }
}

String _toWinPath(String p) => p.replaceAll('/', '\\');

Future<Uint8List?> _rootBundleBytes(String path) async {
  final hit = _cache[path];
  if (hit != null) return hit;
  try {
    final data = await rootBundle.load(path);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    _cache[path] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// 资源字节缓存（进程内有效；3 张图 + 1 个图标，几十 MB 上限）。
final Map<String, Uint8List> _cache = <String, Uint8List>{};

/// 清空缓存（测试用）。
void clearAssetCache() => _cache.clear();
