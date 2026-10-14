// 业务变量层：把天文/时间/系统信息接进模板引擎
//
// 引擎（package:lightwall_core 的 template.dart）只提供通用能力，
// 这里负责"这个产品该有哪些变量"。
import 'dart:io';
import 'dart:math' as math;

import 'package:lightwall_core/lightwall_core.dart';

/// 变量表构建器。
class Variables {
  /// 组装一次渲染所需的全部变量与函数。
  static TemplateContext build({
    required DateTime now,
    required double lat,
    required double lon,
    required double windowAz,
    int seq = 0,
  }) {
    final sun = sunPosition(lat, lon, now);
    final moon = moonPosition(lat, lon, now);
    final riseSet = sunRiseSet(lat, lon, now.toLocal());
    final localRise = riseSet.rise?.toLocal();
    final localSet = riseSet.set?.toLocal();

    String hm(DateTime? d) => d == null
        ? '--:--'
        : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    final dayLen = dayLengthHours(lat, now);
    final isDay = sun.altitude > 0;

    final values = <String, Object?>{
      // ── 时间 ──
      'time': '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      'time_sec': '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}',
      'date': '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}',
      'date_cn': '${now.year}年${now.month}月${now.day}日',
      'date_slash': '${now.month}/${now.day}',
      'year': now.year,
      'month': now.month,
      'day': now.day,
      'hour': now.hour,
      'minute': now.minute,
      'second': now.second,
      'weekday': now.weekday,
      'weekday_cn': const <String>['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1],
      'week_cn': '星期${const <String>['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1]}',
      'month_cn': '${now.month}月',
      'yearday': _dayOfYear(now),
      'quarter': ((now.month - 1) ~/ 3) + 1,
      'timestamp': now.millisecondsSinceEpoch ~/ 1000,
      'iso': now.toIso8601String(),
      'utc_time': '${now.toUtc().hour.toString().padLeft(2, '0')}:'
          '${now.toUtc().minute.toString().padLeft(2, '0')}',
      'utc_date': '${now.toUtc().year}-${now.toUtc().month.toString().padLeft(2, '0')}-'
          '${now.toUtc().day.toString().padLeft(2, '0')}',

      // ── 节令 ──
      'season': _season(now.month),
      'greeting': _greeting(now.hour),

      // ── 太阳 ──
      'sun_alt': sun.altitude.toStringAsFixed(1),
      'sun_az': sun.azimuth.toStringAsFixed(0),
      'sunrise': hm(localRise),
      'sunset': hm(localSet),
      'day_length': dayLen.toStringAsFixed(1),
      'is_day': isDay,
      'time_to_sunset': _timeTo(now, localSet),
      'time_to_sunrise': _timeTo(now, localRise),
      'light_state': sun.altitude > 20
          ? '高照'
          : (sun.altitude > 0 ? '低斜' : (sun.altitude > -6 ? '暮色' : '夜')),

      // ── 月亮 ──
      'moon_alt': moon.altitude.toStringAsFixed(1),
      'moon_phase': (moonPhase(now) * 100).toStringAsFixed(0),
      'moon_phase_cn': _moonPhaseCn(moonPhase(now)),

      // ── 系统 / 运行时 ──
      'seq': seq,
      'hostname': Platform.localHostname,
      'user': Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '',
      'os': Platform.operatingSystem,

      // ── 名称 ──
      'window_dir': _dirName(windowAz),
      'city': '',
    };

    final functions = <String, TemplateFn>{
      /// 距目标日期还有多少天（负数表示已过）。
      'days_until': (args, ctx) {
        final target = _parseDate(args.isEmpty ? null : args[0]);
        if (target == null) return null;
        final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
        return target.difference(today).inDays;
      },
      /// 从目标日期起已过多少天。
      'days_since': (args, ctx) {
        final target = _parseDate(args.isEmpty ? null : args[0]);
        if (target == null) return null;
        final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
        return today.difference(target).inDays;
      },
      /// 倒计时文案：还有 N 天 / 就是今天 / 已过 N 天
      'countdown': (args, ctx) {
        final target = _parseDate(args.isEmpty ? null : args[0]);
        if (target == null) return null;
        final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
        final d = target.difference(today).inDays;
        if (d > 0) return '还有 $d 天';
        if (d == 0) return '就是今天';
        return '已过 ${-d} 天';
      },
      /// 倒计时天数（正数=还有，负数=已过）
      'cd_days': (args, ctx) {
        final target = _parseDate(args.isEmpty ? null : args[0]);
        if (target == null) return null;
        final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
        return target.difference(today).inDays;
      },
      /// 当天进度 0~1（可传小时表示"到某点为止"）
      'day_progress': (args, ctx) {
        final h = args.length > 1 ? _toDouble(args[1]) : 24.0;
        final passed = (ctx.now.hour + ctx.now.minute / 60.0) / (h <= 0 ? 24.0 : h);
        return passed.clamp(0.0, 1.0);
      },
      /// 两个日期之间的进度（0~1，start 起 end 止）
      'progress': (args, ctx) {
        if (args.length < 2) return null;
        final a = _parseDate(args[0]);
        final b = _parseDate(args[1]);
        if (a == null || b == null || b == a) return null;
        final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
        return (today.difference(a).inDays / b.difference(a).inDays).clamp(0.0, 1.0);
      },
      /// 某个日期是星期几（中文）
      'weekday_of': (args, ctx) {
        final d = _parseDate(args.isEmpty ? null : args[0]);
        if (d == null) return null;
        return const <String>['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1];
      },
      /// 日期加减
      'add_days': (args, ctx) {
        final d = _parseDate(args.isEmpty ? null : args[0]);
        final n = args.length > 1 ? _toDouble(args[1])?.toInt() : null;
        if (d == null || n == null) return null;
        final r = d.add(Duration(days: n));
        return '${r.year}-${r.month.toString().padLeft(2, '0')}-${r.day.toString().padLeft(2, '0')}';
      },
      /// 星期几的中文（与 weekday_of 等价，便于书写）
      'weekday_cn_of': (args, ctx) {
        final d = _parseDate(args.isEmpty ? null : args[0]);
        if (d == null) return null;
        return '星期${const <String>['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}';
      },
      /// 按序号轮流取值（每 3 分钟一次渲染 → 用来做轮播文案）
      'rotate': (args, ctx) {
        if (args.isEmpty) return null;
        final n = (ctx['seq'] as int? ?? 0);
        return args[n % args.length];
      },
      /// 判断是否在某个时间段内（含边界，小时）
      'in_hours': (args, ctx) {
        if (args.length < 2) return false;
        final a = _toDouble(args[0]) ?? 0;
        final b = _toDouble(args[1]) ?? 24;
        final h = ctx.now.hour + ctx.now.minute / 60.0;
        return h >= a && h <= b;
      },
      /// 取变量的值（用于变量名拼接）
      'var': (args, ctx) => args.isEmpty ? null : ctx['${args[0]}'],
      /// 中文星期
      'cn_week': (args, ctx) =>
          '星期${const <String>['一', '二', '三', '四', '五', '六', '日'][ctx.now.weekday - 1]}',
    };

    return TemplateContext(now: now, values: values, functions: functions);
  }

  static int _dayOfYear(DateTime d) =>
      d.difference(DateTime(d.year, 1, 1)).inDays + 1;

  static String _season(int month) {
    if (month <= 2 || month == 12) return '冬';
    if (month <= 5) return '春';
    if (month <= 8) return '夏';
    return '秋';
  }

  static String _greeting(int hour) {
    if (hour < 5) return '夜深';
    if (hour < 9) return '早安';
    if (hour < 12) return '上午好';
    if (hour < 14) return '午安';
    if (hour < 18) return '下午好';
    if (hour < 22) return '晚上好';
    return '夜深';
  }

  static String _moonPhaseCn(double phase) {
    final p = phase % 1.0;
    if (p < 0.03 || p > 0.97) return '新月';
    if (p < 0.22) return '娥眉月';
    if (p < 0.28) return '上弦月';
    if (p < 0.47) return '盈凸月';
    if (p < 0.53) return '满月';
    if (p < 0.72) return '亏凸月';
    if (p < 0.78) return '下弦月';
    return '残月';
  }

  static String _timeTo(DateTime now, DateTime? target) {
    if (target == null) return '--';
    var diff = target.difference(now);
    if (diff.isNegative) diff = diff + const Duration(days: 1);
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    if (h <= 0) return '${m}分';
    return '$h小时${m}分';
  }

  static String _dirName(double az) {
    const names = <String>['北', '东北', '东', '东南', '南', '西南', '西', '西北'];
    final idx = (((az % 360) + 22.5) ~/ 45).toInt() % 8;
    return names[idx];
  }

  static DateTime? _parseDate(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    try {
      final parts = s.split(RegExp(r'[-/.]'));
      if (parts.length == 1) {
        // 只给月-日 或 年份：用当前年/月补齐
        final n = int.tryParse(parts[0]);
        if (n == null) return null;
        return DateTime(n, 1, 1);
      }
      if (parts.length == 2) {
        final m = int.tryParse(parts[0]);
        final d = int.tryParse(parts[1]);
        if (m == null || d == null) return null;
        final now = DateTime.now();
        return DateTime(now.year, m, d);
      }
      final y = int.tryParse(parts[0]);
      final mo = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y == null || mo == null || d == null) return null;
      return DateTime(y, mo, d);
    } catch (_) {
      return null;
    }
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v == null) return null;
    return double.tryParse(v.toString());
  }

  /// 变量与函数的中文速查（UI 帮助面板用）。
  static String help() => '''
【时间】{time} {time_sec} {date} {date_cn} {date_slash} {year} {month} {day}
        {hour} {minute} {second} {weekday} {weekday_cn} {week_cn} {month_cn}
        {yearday} {quarter} {timestamp} {iso} {utc_time} {utc_date}
【节令】{season} {greeting} {light_state}
【太阳】{sun_alt} {sun_az} {sunrise} {sunset} {day_length} {is_day}
        {time_to_sunset} {time_to_sunrise}
【月亮】{moon_alt} {moon_phase} {moon_phase_cn}
【系统】{seq} {hostname} {user} {os} {window_dir}
【倒计时】{days_until("2026-01-01")} {days_since("2025-01-01")}
          {countdown("2026-01-01")} → "还有 79 天"
【其它函数】{progress("2025-01-01","2025-12-31")} {day_progress()}
            {rotate("甲","乙","丙")} {in_hours(9,18)} {add_days("2026-01-01",7)}
            {weekday_of("2026-01-01")} {cn_week()}
【通用】{cn(1234)} {pad(7,2)} {min(a,b)} {max(a,b)} {round(x)}
        {upper(s)} {lower(s)} {random(1,9)} {format_time(now,"yyyy年MM月dd日")}
【过滤器】{month|pad2} {x|cn} {ratio|percent} {v|default:"无"} {n|round0}
【条件】{if days_until("2026-01-01") > 0}还有 {days_until("2026-01-01")} 天
        {else}已经到啦{/if}
''';
}
