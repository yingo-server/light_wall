// 天文与大气物理（向阳面窗光的物理内核）
//
// 从 Python 参考实现忠实移植并修正：
//   · 太阳/月亮位置（低精度天文算法）
//   · 分波长大气透过率（Rayleigh + Mie，Kasten-Young 大气质量）
//   · 黑体色温 → 太阳颜色
//   · 日出日落 / 太阳时角 / 昼长
//   · 天光漫射、暮光、月光与夜空辉光
//
// 本项目**禁用天气系统**：只有晴天一种状态，故云量恒为 0、能见度取 20km。
// 这样云/降水/雾霾相关的分支全部退化为常量，代码路径更短、更可预测。
import 'dart:math' as math;

const double kDeg = math.pi / 180.0;

/// 太阳/月亮位置结果。
class BodyPosition {
  const BodyPosition(this.azimuth, this.altitude);

  /// 方位角（度，正北为 0，顺时针）。
  final double azimuth;

  /// 高度角（度，地平线以上为正）。
  final double altitude;
}

/// 儒略日（UTC）。
double julianDay(DateTime dtUtc) {
  final utc = dtUtc.toUtc();
  var y = utc.year;
  var m = utc.month;
  final d = utc.day;
  final hh = utc.hour +
      utc.minute / 60.0 +
      utc.second / 3600.0 +
      utc.millisecond / 3600000.0;
  if (m <= 2) {
    y -= 1;
    m += 12;
  }
  final a = (y / 100).floor();
  final b = 2 - a + (a / 4).floor();
  return (365.25 * (y + 4716)).floor() +
      (30.6001 * (m + 1)).floor() +
      d +
      b -
      1524.5 +
      hh / 24.0;
}

/// 太阳位置。
BodyPosition sunPosition(double lat, double lon, DateTime dt) {
  final utc = dt.toUtc();
  final jd = julianDay(utc);
  final n = jd - 2451545.0;
  final l = (280.460 + 0.9856474 * n) % 360.0;
  final g = ((357.528 + 0.9856003 * n) % 360.0) * kDeg;
  final lambda =
      ((l + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) % 360.0) * kDeg;
  final eps = (23.439 - 0.0000004 * n) * kDeg;
  final alpha = math.atan2(math.cos(eps) * math.sin(lambda), math.cos(lambda));
  final delta = math.asin(math.sin(eps) * math.sin(lambda));
  final hh = utc.hour + utc.minute / 60.0 + utc.second / 3600.0;
  final gmst = (6.697375 + 0.0657098242 * n + hh) % 24.0;
  final lmst = (gmst * 15.0 + lon) % 360.0;
  final h = (lmst - alpha / kDeg) * kDeg;
  final phi = lat * kDeg;
  final alt = math.asin(math.sin(phi) * math.sin(delta) +
      math.cos(phi) * math.cos(delta) * math.cos(h));
  final az = math.atan2(
      -math.cos(delta) * math.sin(h),
      math.sin(delta) * math.cos(phi) -
          math.cos(delta) * math.sin(phi) * math.cos(h));
  var azDeg = az / kDeg % 360.0;
  if (azDeg < 0) azDeg += 360.0;
  return BodyPosition(azDeg, alt / kDeg);
}

/// 太阳赤纬与时角（用于日出日落计算）。
class _SolarDecl {
  const _SolarDecl(this.declination, this.eot);

  final double declination; // 弧度
  final double eot; // 均时差（小时）
}

_SolarDecl _solarDecl(DateTime dtUtc) {
  final jd = julianDay(dtUtc);
  final n = jd - 2451545.0;
  final l = (280.460 + 0.9856474 * n) % 360.0;
  final g = ((357.528 + 0.9856003 * n) % 360.0) * kDeg;
  final lambda =
      ((l + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) % 360.0) * kDeg;
  final eps = (23.439 - 0.0000004 * n) * kDeg;
  final delta = math.asin(math.sin(eps) * math.sin(lambda));
  // 均时差（分钟 → 小时）
  final eotMin = 4.0 * (l - 0.0057183 - alphaDeg(lambda, eps, delta));
  return _SolarDecl(delta, eotMin / 60.0);
}

/// 真太阳时的赤经（度）。
double alphaDeg(double lambda, double eps, double delta) {
  final ra = math.atan2(math.cos(eps) * math.sin(lambda), math.cos(lambda));
  var deg = ra / kDeg % 360.0;
  if (deg < 0) deg += 360.0;
  return deg;
}

/// 日出/日落（当地钟表时间，简单由经度与均时差推出）。
///
/// 返回 (rise, set)，极昼/极夜时对应值为 null。
({DateTime? rise, DateTime? set}) sunRiseSet(
    double lat, double lon, DateTime dayLocal) {
  final utcNoon = DateTime.utc(dayLocal.year, dayLocal.month, dayLocal.day, 12);
  final decl = _solarDecl(utcNoon);
  final phi = lat * kDeg;
  final cosH =
      (math.sin(-0.833 * kDeg) - math.sin(phi) * math.sin(decl.declination)) /
          (math.cos(phi) * math.cos(decl.declination));
  if (cosH > 1.0) return (rise: null, set: null); // 极夜
  if (cosH < -1.0) return (rise: null, set: null); // 极昼
  final hDeg = math.acos(cosH) / kDeg;
  final solarNoonUtcHours = 12.0 - lon / 15.0 - decl.eot;
  final riseUtc = solarNoonUtcHours - hDeg / 15.0;
  final setUtc = solarNoonUtcHours + hDeg / 15.0;
  final base = DateTime.utc(dayLocal.year, dayLocal.month, dayLocal.day);
  return (
    rise: base.add(Duration(milliseconds: (riseUtc * 3600000).round())),
    set: base.add(Duration(milliseconds: (setUtc * 3600000).round())),
  );
}

/// 太阳正午（UTC）。
DateTime? solarNoon(double lon, DateTime dayLocal) {
  final decl =
      _solarDecl(DateTime.utc(dayLocal.year, dayLocal.month, dayLocal.day, 12));
  final h = 12.0 - lon / 15.0 - decl.eot;
  return DateTime.utc(dayLocal.year, dayLocal.month, dayLocal.day)
      .add(Duration(milliseconds: (h * 3600000).round()));
}

/// 昼长（小时）。极昼 24 / 极夜 0。
double dayLengthHours(double lat, DateTime dayLocal) {
  final utcNoon = DateTime.utc(dayLocal.year, dayLocal.month, dayLocal.day, 12);
  final decl = _solarDecl(utcNoon);
  final phi = lat * kDeg;
  final cosH =
      (math.sin(-0.833 * kDeg) - math.sin(phi) * math.sin(decl.declination)) /
          (math.cos(phi) * math.cos(decl.declination));
  if (cosH > 1.0) return 0.0;
  if (cosH < -1.0) return 24.0;
  return 2.0 * math.acos(cosH) / kDeg / 15.0;
}

// ───────────────────────────── 月亮 ─────────────────────────────

/// 月亮位置（低精度简化模型）。
BodyPosition moonPosition(double lat, double lon, DateTime dt) {
  final utc = dt.toUtc();
  final jd = julianDay(utc);
  final n = jd - 2451545.0;

  final nNode = (125.1228 - 0.0529538083 * n) * kDeg;
  const inc = 5.1454 * kDeg;
  final per = (318.0634 + 0.1643573223 * n) * kDeg;
  final maj = 60.2666; // 地球半径
  final ecc = 0.054900;
  final mAnom = ((115.3654 + 13.0649929509 * n) % 360.0) * kDeg;

  // 求解偏近点角
  var e = mAnom;
  for (var i = 0; i < 5; i++) {
    e = e - (e - ecc * math.sin(e) - mAnom) / (1 - ecc * math.cos(e));
  }
  final xv = maj * (math.cos(e) - ecc);
  final yv = maj * math.sqrt(1 - ecc * ecc) * math.sin(e);
  final v = math.atan2(yv, xv);
  final r = math.sqrt(xv * xv + yv * yv);

  // 黄道坐标
  final xh = r *
      (math.cos(nNode) * math.cos(v + per) -
          math.sin(nNode) * math.sin(v + per) * math.cos(inc));
  final yh = r *
      (math.sin(nNode) * math.cos(v + per) +
          math.cos(nNode) * math.sin(v + per) * math.cos(inc));
  final zh = r * (math.sin(v + per) * math.sin(inc));

  final lonEcl = math.atan2(yh, xh);
  final latEcl = math.atan2(zh, math.sqrt(xh * xh + yh * yh));

  // 黄道 → 赤道
  const obliq = 23.4393 * kDeg;
  final xe = math.cos(latEcl) * math.cos(lonEcl);
  final ye = math.cos(obliq) * math.cos(latEcl) * math.sin(lonEcl) -
      math.sin(obliq) * math.sin(latEcl);
  final ze = math.sin(obliq) * math.cos(latEcl) * math.sin(lonEcl) +
      math.cos(obliq) * math.sin(latEcl);

  final ra = math.atan2(ye, xe);
  final dec = math.atan2(ze, math.sqrt(xe * xe + ye * ye));

  // 时角
  final hh = utc.hour + utc.minute / 60.0 + utc.second / 3600.0;
  final gmst = (6.697375 + 0.0657098242 * n + hh) % 24.0;
  final lmst = (gmst * 15.0 + lon) * kDeg;
  final h = lmst - ra;

  final phi = lat * kDeg;
  final alt = math.asin(math.sin(phi) * math.sin(dec) +
      math.cos(phi) * math.cos(dec) * math.cos(h));
  final az = math.atan2(
      -math.cos(dec) * math.sin(h),
      math.sin(dec) * math.cos(phi) -
          math.cos(dec) * math.sin(phi) * math.cos(h));
  var azDeg = az / kDeg % 360.0;
  if (azDeg < 0) azDeg += 360.0;
  return BodyPosition(azDeg, alt / kDeg);
}

/// 月相（0=新月，0.5=满月）。
double moonPhase(DateTime dtUtc) {
  const synodic = 29.530588853;
  // 参考新月：2000-01-06 18:14 UTC
  final ref = DateTime.utc(2000, 1, 6, 18, 14);
  final days = dtUtc.toUtc().difference(ref).inMilliseconds / 86400000.0;
  var phase = (days / synodic) % 1.0;
  if (phase < 0) phase += 1.0;
  return phase;
}

/// 月相亮度因子（0=新月不可见，1=满月最亮）。
double moonBrightnessFactor(double phase) =>
    (1.0 - math.cos(2 * math.pi * phase)) / 2.0;

// ─────────────────────────── 大气物理 ───────────────────────────

/// Kasten-Young 大气质量。
double airMassKastenYoung(double altDeg) {
  if (altDeg <= 0) return 40.0;
  final a = altDeg > 90 ? 90.0 : altDeg;
  final s = math.sin(a * kDeg);
  final am = 1.0 / (s + 0.50572 * math.pow(a + 6.07995, -1.6364).toDouble());
  return am > 40.0 ? 40.0 : am;
}

/// Mie 光学厚度（仅气溶胶，晴天取 0.05）。
double mieTau([double visM = 20000.0]) {
  var tau = 0.05;
  final vis = visM < 200.0 ? 200.0 : visM;
  final ratio = (vis / 20000.0).clamp(0.02, 1.0);
  tau += -math.log(ratio) * 0.15;
  return tau;
}

/// 分波长太阳辐照度（RGB，天顶归一化为 1）。
List<double> solarIrradianceRgb(double altDeg, [double visM = 20000.0]) {
  if (altDeg < -18) return <double>[0, 0, 0];
  if (altDeg < 0) {
    double base;
    if (altDeg > -6) {
      base = 0.018 * (1 + altDeg / 6);
    } else if (altDeg > -12) {
      base = 0.004 * (1 + (altDeg + 6) / 6);
    } else {
      base = 0.0008 * (1 + (altDeg + 12) / 6);
    }
    return <double>[base, base * 0.45, base * 0.20];
  }

  final am = airMassKastenYoung(altDeg);
  const tauR550 = 0.098;
  double rayleigh(double wl) =>
      tauR550 * math.pow(wl / 550.0, -4.08).toDouble();

  final tauM = mieTau(visM);
  // 臭氧 Chappuis 带吸收（500~700 nm，峰值 ~600 nm）：低太阳角（am 大）
  // 时臭氧路径拉长，直射进一步偏暖 —— 这是"夕阳红"在 Rayleigh 之外的
  // 第二个物理来源，参考实现也没有，低角度渲染的暖度会系统性不足。
  const tauO3 = 0.03; // 垂直大气臭氧光学厚度 @600nm（教科书常数）
  var tr = math.exp(-(rayleigh(650.0) + tauM + tauO3 * 0.95) * am);
  var tg = math.exp(-(rayleigh(550.0) + tauM + tauO3 * 0.65) * am);
  var tb = math.exp(-(rayleigh(450.0) + tauM) * am);

  if (altDeg < 8.0) {
    final extra = (8.0 - altDeg) / 8.0 * 0.5;
    tb *= math.exp(-extra * am * 0.7);
    tg *= math.exp(-extra * am * 0.4);
  }
  return <double>[
    tr.clamp(0.0, 1.0),
    tg.clamp(0.0, 1.0),
    tb.clamp(0.0, 1.0),
  ];
}

/// 太阳辐照度标量（取 G 通道）。
double solarIrradiance(double altDeg, [double visM = 20000.0]) =>
    solarIrradianceRgb(altDeg, visM)[1];

/// 天光（天空漫射）辐照度，晴天。
double skyIrradiance(double sunAlt) {
  if (sunAlt <= 0) return 0.0;
  const skyMax = 0.22;
  return skyMax * math.pow(math.sin(sunAlt * kDeg), 0.60).toDouble();
}

/// 夜空照明：城市辉光/星光 + 月光散射。
double nightSkyIrradiance(double moonAlt, double phase) {
  const c = 0.0; // 晴空无云
  final skyglow = 0.008 * (1.0 - 0.55 * c);
  var moonAmb = 0.0;
  if (moonAlt > 0) {
    final m = moonBrightnessFactor(phase);
    final altN = math.pow((moonAlt / 60.0).clamp(0.0, 1.0), 0.7).toDouble();
    moonAmb = 0.035 * m * altN * (1.0 - 0.60 * c);
  }
  return skyglow + moonAmb;
}

/// 月光辐照度（视觉校正）。
double moonIrradiance(double moonAlt, double phase) {
  if (moonAlt < 5) return 0.0;
  final altN = math.pow((moonAlt / 60.0).clamp(0.0, 1.0), 0.7).toDouble();
  final am = airMassKastenYoung(moonAlt < 0.1 ? 0.1 : moonAlt);
  final trans = math.exp(-0.20 * am);
  return 0.20 * altN * trans * moonBrightnessFactor(phase);
}

/// 天光颜色（线性 RGB）。
List<double> skyColor(double sunAlt) {
  const zenith = <double>[0.42, 0.50, 0.70];
  const horizon = <double>[0.60, 0.52, 0.52];
  final t = ((sunAlt - 3.0) / 27.0).clamp(0.0, 1.0);
  return <double>[
    horizon[0] * (1 - t) + zenith[0] * t,
    horizon[1] * (1 - t) + zenith[1] * t,
    horizon[2] * (1 - t) + zenith[2] * t,
  ];
}

/// 月光颜色（线性 RGB）。
List<double> moonColorRgb(double moonAlt) {
  var base = <double>[0.34, 0.48, 0.90];
  if (moonAlt < 20) {
    final warm = (20 - moonAlt) / 20.0 * 0.3;
    const warmColor = <double>[0.63, 0.38, 0.14];
    base = <double>[
      base[0] * (1 - warm) + warmColor[0] * warm,
      base[1] * (1 - warm) + warmColor[1] * warm,
      base[2] * (1 - warm) + warmColor[2] * warm,
    ];
  }
  return base;
}

/// 黑体辐射温度 → sRGB。
List<double> blackbodyToRgb(double tempK) {
  final t = tempK.clamp(1000.0, 40000.0);
  final t100 = t / 100.0;
  double r, g, b;
  if (t100 <= 66) {
    r = 255.0;
    g = 99.4708025861 * math.log(t100) - 161.1195681661;
    b = t100 <= 19
        ? 0.0
        : 138.5177312231 * math.log(t100 - 10) - 305.0447927307;
  } else {
    r = 329.698727446 * math.pow(t100 - 60, -0.1332047592).toDouble();
    g = 288.1221695283 * math.pow(t100 - 60, -0.0755148492).toDouble();
    b = 255.0;
  }
  return <double>[
    (r.clamp(0.0, 255.0)) / 255.0,
    (g.clamp(0.0, 255.0)) / 255.0,
    (b.clamp(0.0, 255.0)) / 255.0,
  ];
}

/// 太阳颜色（由高度角算色温）。
List<double> sunColorFromAltitude(double altDeg) {
  double t;
  if (altDeg >= 60) {
    t = 6500.0;
  } else if (altDeg >= 20) {
    t = 4500 + (altDeg - 20) / 40.0 * 2000;
  } else if (altDeg >= 5) {
    t = 2800 + (altDeg - 5) / 15.0 * 1700;
  } else if (altDeg >= 0) {
    t = 1800 + altDeg / 5.0 * 1000;
  } else {
    t = 1500.0;
  }
  return blackbodyToRgb(t);
}

/// 暮光天光环境色（线性 RGB）：暮光的天顶已暗，环境光来自
/// 地平线亮带 —— 比天光更暖更暗。随 |sunAlt| 从暖橙过渡到灰蓝。
List<double> twilightAmbientColor(double sunAlt) {
  // sunAlt ∈ (-6, 0]：t=0 → 日没瞬间（暖橙），t=1 → 民用暮光尽头（灰蓝）
  final t = ((0.0 - sunAlt) / 6.0).clamp(0.0, 1.0);
  const warm = <double>[0.62, 0.38, 0.22];
  const cool = <double>[0.22, 0.26, 0.42];
  return <double>[
    warm[0] * (1 - t) + cool[0] * t,
    warm[1] * (1 - t) + cool[1] * t,
    warm[2] * (1 - t) + cool[2] * t,
  ];
}

/// 暮光颜色（线性 RGB）。
List<double> twilightColor(double altDeg) {
  if (altDeg >= 0) return sunColorFromAltitude(altDeg);
  const stopsV = <double>[0, -2, -4, -6, -9, -12, -15, -18];
  const stopsC = <List<double>>[
    <double>[1.00, 0.46, 0.20],
    <double>[0.85, 0.32, 0.20],
    <double>[0.62, 0.26, 0.32],
    <double>[0.42, 0.22, 0.45],
    <double>[0.28, 0.20, 0.55],
    <double>[0.18, 0.18, 0.58],
    <double>[0.10, 0.14, 0.48],
    <double>[0.05, 0.08, 0.32],
  ];
  if (altDeg <= -18) return List<double>.from(stopsC.last);
  for (var i = 0; i < stopsV.length - 1; i++) {
    final v0 = stopsV[i];
    final v1 = stopsV[i + 1];
    if (altDeg <= v0 && altDeg >= v1) {
      final t = (altDeg - v0) / (v1 - v0);
      return <double>[
        stopsC[i][0] + (stopsC[i + 1][0] - stopsC[i][0]) * t,
        stopsC[i][1] + (stopsC[i + 1][1] - stopsC[i][1]) * t,
        stopsC[i][2] + (stopsC[i + 1][2] - stopsC[i][2]) * t,
      ];
    }
  }
  return List<double>.from(stopsC.last);
}
