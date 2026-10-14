// 设置模型与持久化（%APPDATA%\LightWall\settings.json）
//
// 设计原则（对齐产品要求）：**只暴露必要的几项**
//   文字（模板/字体/年代感）· 底图 · 开机自启 · 隐藏到托盘
// 其余参数（窗户几何、渲染物理常量）都取工程默认值，不交给用户调。
import 'dart:convert';
import 'dart:io';

import 'package:lightwall_core/lightwall_core.dart';

import 'win32.dart';

/// 城市预设（用于太阳位置）。
class CityPreset {
  const CityPreset(this.name, this.lat, this.lon);

  final String name;
  final double lat;
  final double lon;
}

const List<CityPreset> kCities = <CityPreset>[
  CityPreset('北京', 39.9042, 116.4074),
  CityPreset('上海', 31.2304, 121.4737),
  CityPreset('广州', 23.1291, 113.2644),
  CityPreset('深圳', 22.5431, 114.0579),
  CityPreset('成都', 30.5728, 104.0668),
  CityPreset('西安', 34.3416, 108.9398),
  CityPreset('武汉', 30.5928, 114.3055),
  CityPreset('哈尔滨', 45.8038, 126.534),
  CityPreset('乌鲁木齐', 43.8256, 87.6168),
  CityPreset('拉萨', 29.652, 91.1721),
  CityPreset('香港', 22.3193, 114.1694),
  CityPreset('东京', 35.6762, 139.6503),
  CityPreset('新加坡', 1.3521, 103.8198),
  CityPreset('伦敦', 51.5074, -0.1278),
  CityPreset('纽约', 40.7128, -74.006),
  CityPreset('悉尼', -33.8688, 151.2093),
];

/// 窗户朝向预设（罗盘）。
class WindowPreset {
  const WindowPreset(this.label, this.azimuth);

  final String label;
  final double azimuth;
}

const List<WindowPreset> kWindowPresets = <WindowPreset>[
  WindowPreset('东 · 上午有直射', 90),
  WindowPreset('西 · 下午有直射', 270),
  WindowPreset('南 · 冬季全天有直射', 180),
  WindowPreset('北 · 无直射，漫射为主', 0),
  WindowPreset('东南', 135),
  WindowPreset('西南', 225),
  WindowPreset('东北', 45),
  WindowPreset('西北', 315),
];

/// 年代感风格预设。
enum AgedStyle { clean, normal, aged }

/// 应用设置。
class AppSettings {
  AppSettings();

  /// 文字模板（支持变量与条件块）。
  String template = '朝闻道';

  /// 字体（系统字体名）。
  String fontFamily = 'KaiTi';

  /// 字号占画面高度比例。
  double fontRatio = 0.18;

  /// 文字位置（百分比）。
  double posX = 50.0;
  double posY = 50.0;

  /// 底图路径列表（空 = 使用内置底图）。
  List<String> backgrounds = <String>[];

  /// 多张底图时轮换到的下标。
  int backgroundCursor = 0;

  /// 内置底图索引。
  int builtinIndex = 0;

  /// 窗户朝向（罗盘方位角）。
  double windowAz = 90.0;

  /// 窗格行列与窗框占比（工程默认）。
  int gridRows = 3;
  int gridCols = 2;
  double gridFrameRatio = 0.10;

  /// 画面微调（工程默认）。
  double exposure = 1.0;
  double saturation = 1.0;

  /// 年代感风格。
  AgedStyle agedStyle = AgedStyle.normal;

  /// 材质耦合（0 = 关闭）。
  double materialCoupling = 0.0;

  /// 位置（用于太阳位置）。
  int cityIndex = 0;

  /// 开机自启 / 隐藏到托盘。
  bool autostart = false;
  bool hideToTray = true;

  /// 启动时立即渲染一次。
  bool renderOnStart = true;

  double get lat => kCities[cityIndex.clamp(0, kCities.length - 1)].lat;
  double get lon => kCities[cityIndex.clamp(0, kCities.length - 1)].lon;

  AgedParams get agedParams => switch (agedStyle) {
        AgedStyle.clean => AgedParams.clean,
        AgedStyle.aged => AgedParams.aged,
        AgedStyle.normal => const AgedParams(),
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'template': template,
        'fontFamily': fontFamily,
        'fontRatio': fontRatio,
        'posX': posX,
        'posY': posY,
        'backgrounds': backgrounds,
        'backgroundCursor': backgroundCursor,
        'builtinIndex': builtinIndex,
        'windowAz': windowAz,
        'agedStyle': agedStyle.name,
        'materialCoupling': materialCoupling,
        'cityIndex': cityIndex,
        'autostart': autostart,
        'hideToTray': hideToTray,
        'renderOnStart': renderOnStart,
      };

  static AppSettings fromJson(Map<String, Object?> j) {
    final s = AppSettings();
    try {
      s.template = (j['template'] as String?) ?? s.template;
      s.fontFamily = (j['fontFamily'] as String?) ?? s.fontFamily;
      s.fontRatio = (j['fontRatio'] as num?)?.toDouble() ?? s.fontRatio;
      s.posX = (j['posX'] as num?)?.toDouble() ?? s.posX;
      s.posY = (j['posY'] as num?)?.toDouble() ?? s.posY;
      s.backgrounds = ((j['backgrounds'] as List?) ?? const <Object?>[])
          .map((e) => '$e')
          .toList();
      s.backgroundCursor = (j['backgroundCursor'] as num?)?.toInt() ?? 0;
      s.builtinIndex = (j['builtinIndex'] as num?)?.toInt() ?? 0;
      s.windowAz = (j['windowAz'] as num?)?.toDouble() ?? s.windowAz;
      final style = (j['agedStyle'] as String?) ?? 'normal';
      s.agedStyle = AgedStyle.values.firstWhere(
        (e) => e.name == style,
        orElse: () => AgedStyle.normal,
      );
      s.materialCoupling =
          (j['materialCoupling'] as num?)?.toDouble() ?? s.materialCoupling;
      s.cityIndex = (j['cityIndex'] as num?)?.toInt() ?? 0;
      s.autostart = (j['autostart'] as bool?) ?? false;
      s.hideToTray = (j['hideToTray'] as bool?) ?? true;
      s.renderOnStart = (j['renderOnStart'] as bool?) ?? true;
    } catch (_) {
      // 配置损坏 → 用默认值，不阻塞启动
    }
    return s;
  }

  static File get _file => File('${Win32.dataDir().path}\\settings.json');

  void save() {
    try {
      _file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(toJson()),
        flush: true,
      );
    } catch (_) {}
  }

  static AppSettings load() {
    try {
      final f = File('${Win32.dataDir().path}\\settings.json');
      if (!f.existsSync()) return AppSettings();
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map) return fromJson(j.cast<String, Object?>());
    } catch (_) {}
    return AppSettings();
  }
}
