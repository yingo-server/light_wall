// Windows 平台能力（dart:ffi，不依赖任何插件）
//
// · 设置壁纸：SystemParametersInfoW(SPI_SETDESKWALLPAPER)
// · 开机自启：HKCU\Software\Microsoft\Windows\CurrentVersion\Run
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int _spiSetDeskWallpaper = 0x0014;
const int _spifUpdateIniFile = 0x01;
const int _spifSendChange = 0x02;

const int _hkeyCurrentUser = 0x80000001;
const int _keySetValue = 0x0002;
const int _keyQueryValue = 0x0001;
const int _regSz = 1;

const String _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
const String _appValueName = 'LightWall';

/// Windows 平台操作的薄封装；非 Windows 平台全部返回失败而不抛异常。
class Win32 {
  static final bool isWindows = Platform.isWindows;

  static DynamicLibrary? _user32;
  static DynamicLibrary? _advapi32;

  static DynamicLibrary get _u32 =>
      _user32 ??= DynamicLibrary.open('user32.dll');
  static DynamicLibrary get _api32 =>
      _advapi32 ??= DynamicLibrary.open('advapi32.dll');

  /// 把 [path] 设为桌面壁纸（BMP 最稳）。
  static bool setWallpaper(String path) {
    if (!isWindows) return false;
    try {
      final fn = _u32.lookupFunction<
          Int32 Function(Uint32 uiAction, Uint32 uiParam, Pointer<Utf16> pvParam,
              Uint32 fWinIni),
          int Function(
              int uiAction, int uiParam, Pointer<Utf16> pvParam, int fWinIni)>(
          'SystemParametersInfoW');
      final ptr = path.toNativeUtf16();
      try {
        final ok = fn(_spiSetDeskWallpaper, 0, ptr,
            _spifUpdateIniFile | _spifSendChange);
        return ok != 0;
      } finally {
        calloc.free(ptr);
      }
    } catch (_) {
      return false;
    }
  }

  /// 写入/删除开机自启项。
  static bool setAutostart(bool enable, String exePath) {
    if (!isWindows) return false;
    try {
      final regOpen = _api32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32,
              Pointer<IntPtr>),
          int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
          'RegOpenKeyExW');
      final regSet = _api32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>,
              Uint32),
          int Function(
              int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)>(
          'RegSetValueExW');
      final regDel = _api32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>),
          int Function(int, Pointer<Utf16>)>('RegDeleteValueW');
      final regClose = _api32.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('RegCloseKey');

      final keyPtr = calloc<IntPtr>();
      final subKey = _runKey.toNativeUtf16();
      final valueName = _appValueName.toNativeUtf16();
      try {
        final rc = regOpen(_hkeyCurrentUser, subKey, 0, _keySetValue, keyPtr);
        if (rc != 0) return false;
        final hKey = keyPtr.value;
        try {
          if (enable) {
            final quoted = '"$exePath"';
            // UTF-16 需要连结尾的 NUL 一起写入
            final units = <int>[];
            for (final unit in quoted.codeUnits) {
              units..add(unit & 0xff)..add((unit >> 8) & 0xff);
            }
            units..add(0)..add(0);
            final data = calloc<Uint8>(units.length);
            try {
              data.asTypedList(units.length).setAll(0, units);
              final r = regSet(hKey, valueName, 0, _regSz, data, units.length);
              return r == 0;
            } finally {
              calloc.free(data);
            }
          } else {
            final r = regDel(hKey, valueName);
            return r == 0;
          }
        } finally {
          regClose(hKey);
        }
      } finally {
        calloc.free(keyPtr);
        calloc.free(subKey);
        calloc.free(valueName);
      }
    } catch (_) {
      return false;
    }
  }

  /// 查询当前是否已设置开机自启。
  static bool isAutostartEnabled() {
    if (!isWindows) return false;
    try {
      final regOpen = _api32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32,
              Pointer<IntPtr>),
          int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
          'RegOpenKeyExW');
      final regQuery = _api32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>,
              Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
          int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');
      final regClose = _api32.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('RegCloseKey');

      final keyPtr = calloc<IntPtr>();
      final subKey = _runKey.toNativeUtf16();
      final valueName = _appValueName.toNativeUtf16();
      final type = calloc<Uint32>();
      final size = calloc<Uint32>()..value = 1024;
      final buf = calloc<Uint8>(1024);
      try {
        final rc = regOpen(_hkeyCurrentUser, subKey, 0, _keyQueryValue, keyPtr);
        if (rc != 0) return false;
        final hKey = keyPtr.value;
        try {
          final r = regQuery(hKey, valueName, nullptr, type, buf, size);
          return r == 0;
        } finally {
          regClose(hKey);
        }
      } finally {
        calloc
          ..free(keyPtr)
          ..free(subKey)
          ..free(valueName)
          ..free(type)
          ..free(size)
          ..free(buf);
      }
    } catch (_) {
      return false;
    }
  }

  /// 当前可执行文件路径（打包后是 exe，开发时是 dart/flutter 的运行时）。
  static String executablePath() => Platform.resolvedExecutable;

  /// 用户数据目录：%APPDATA%\LightWall
  static Directory dataDir() {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.current.path;
    final dir = Directory('$base\\LightWall');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 主显示器尺寸（逻辑像素）；取不到时回落到 1920×1080。
  static (int, int) screenSize() {
    try {
      final fn = _u32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Int32>),
          int Function(int, Pointer<Int32>)>('GetSystemMetrics');
      final w = calloc<Int32>();
      final h = calloc<Int32>();
      try {
        final ok = fn(0, w); // SM_CXSCREEN
        if (ok == 0) ok;
        fn(1, h); // SM_CYSCREEN
        if (w.value > 0 && h.value > 0) return (w.value, h.value);
      } finally {
        calloc
          ..free(w)
          ..free(h);
      }
    } catch (_) {}
    return (1920, 1080);
  }

  /// 用系统默认程序打开一个路径（用于"打开输出目录"）。
  static void openPath(String path) {
    if (!isWindows) return;
    Process.run('explorer', <String>[path]);
  }
}

/// 便于测试与日志：字节序无关的小工具。
Uint8List utf16Le(String s) {
  final out = <int>[];
  for (final unit in s.codeUnits) {
    out..add(unit & 0xff)..add((unit >> 8) & 0xff);
  }
  return Uint8List.fromList(out);
}
