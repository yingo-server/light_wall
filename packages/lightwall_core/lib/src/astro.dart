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
import 'spectrum.dart';
import 'tuning.dart';

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
  // 返回**视高度角**（几何高度 + 大气折射）—— airMass 的输入定义为视高度角，
  // 场景太阳方向也必须用它，否则低太阳角会系统性错位。
  return BodyPosition(azDeg, apparentAltitudeDeg(alt / kDeg));
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

/// 日出/日落，返回 **UTC** 时刻（旧实现文档写"当地钟表时间"却返回 UTC，
/// 而且拿本地日历日的年月日去构造 UTC 正午 —— 在经度与时区错配的站点会取到
/// 错误的赤纬、甚至整体错一天）。这里以给定时刻的 **UTC 日历日** 为基准，
/// 并用 Meeus 第 15 章的迭代法（用事件时刻的赤纬回代一步）提高精度。
/// 极昼/极夜时 rise/set 均为 null（由 |cosH| 判定，调用方需自行区分）。
({DateTime? rise, DateTime? set}) sunRiseSet(
    double lat, double lon, DateTime dayLocal) {
  final u = dayLocal.toUtc();
  final base = DateTime.utc(u.year, u.month, u.day);
  final phi = lat * kDeg;
  final sinAlt0 = math.sin(-0.833 * kDeg); // 上缘 + 折射的标准日出高度
  var decl = _solarDecl(base.add(const Duration(hours: 12))).declination;
  DateTime? rise;
  DateTime? set;
  for (var iter = 0; iter < 3; iter++) {
    final cosH = (sinAlt0 - math.sin(phi) * math.sin(decl)) /
        (math.cos(phi) * math.cos(decl));
    if (cosH > 1.0 || cosH < -1.0) {
      // 极夜/极昼。但注意：这是**迭代中途**的判定——decl 在回代中漂移，
      // 边界日期上第 1 轮可能已得到合理解，被这里的 return 丢弃。
      // 已有解则返回既有解；首轮即越界才是真极昼/极夜。
      if (rise != null && set != null) break;
      return (rise: null, set: null);
    }
    final hDeg = math.acos(cosH) / kDeg;
    final noon = _solarDecl(base.add(const Duration(hours: 12)));
    final noonH = 12.0 - lon / 15.0 - noon.eot;
    final riseH = noonH - hDeg / 15.0;
    final setH = noonH + hDeg / 15.0;
    rise = base.add(Duration(milliseconds: (riseH * 3600000).round()));
    set = base.add(Duration(milliseconds: (setH * 3600000).round()));
    decl = _solarDecl(rise.add(const Duration(hours: 6))).declination;
  }
  return (rise: rise, set: set);
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

/// 月亮位置 —— Meeus《Astronomical Algorithms》第 47 章的**主摄动项**级数。
///
/// 旧实现只解"无摄动开普勒方程"，漏掉出差(evection ±1.27°)、二均差
/// (variation 0.66°)、周年差、黄纬交角归算等周期项，误差可达 1~2°；
/// 经大气质量放大后月光亮度差近 2 倍、光斑方位偏 1~2°。这里改用黄经/黄纬/
/// 地心距离的周期改正级数（Meeus 表 47.A 主要项，精度 ~0.05°），并补上两件
/// 被漏掉的几何：
///   · **地平视差**（地心 → 站心，最大 0.95°，比月面直径还大）；
///   · 大气折射（返回视高度角）。
BodyPosition moonPosition(double lat, double lon, DateTime dt) {
  final utc = dt.toUtc();
  final jd = julianDay(utc);
  final T = (jd - 2451545.0) / 36525.0;

  // 基本角（度）：平黄经 l'、平距角 D、太阳平近点角 M、月亮平近点角 M'、纬度参数 F
  final lp = 218.3164477 + 481267.88123421 * T;
  final dAng = 297.8501921 + 445267.1114034 * T;
  final mAng = 357.5291092 + 35999.0502909 * T;
  final mpAng = 134.9633964 + 477198.8675055 * T;
  final fAng = 93.2720950 + 483202.0175233 * T;
  final d = dAng * kDeg, m = mAng * kDeg, mp = mpAng * kDeg, f = fAng * kDeg;

  // 黄经改正 Σl（度）—— Meeus 表 47.A 主要项
  final sumL = 6.288774 * math.sin(mp) +
      1.274027 * math.sin(2 * d - mp) +
      0.658314 * math.sin(2 * d) +
      0.213618 * math.sin(2 * mp) -
      0.185116 * math.sin(m) -
      0.114332 * math.sin(2 * f) +
      0.058793 * math.sin(2 * d - 2 * mp) +
      0.057066 * math.sin(2 * d - m - mp) +
      0.053322 * math.sin(2 * d + mp) +
      0.045758 * math.sin(2 * d - m) -
      0.040923 * math.sin(m - mp) -
      0.034720 * math.sin(d) -
      0.030383 * math.sin(m + mp) +
      0.015327 * math.sin(2 * d - 2 * f) -
      0.012528 * math.sin(mp + 2 * f) +
      0.010980 * math.sin(mp - 2 * f);
  // 黄纬改正 Σb（度）
  final sumB = 5.128122 * math.sin(f) +
      0.280602 * math.sin(mp + f) +
      0.277693 * math.sin(mp - f) +
      0.173237 * math.sin(2 * d - f) +
      0.055413 * math.sin(2 * d - mp + f) +
      0.046271 * math.sin(2 * d - mp - f) +
      0.032573 * math.sin(2 * d + f) +
      0.017198 * math.sin(2 * mp + f) +
      0.009266 * math.sin(2 * d + mp - f) +
      0.008822 * math.sin(2 * mp - f) +
      0.008216 * math.sin(2 * d - m - f) +
      0.004324 * math.sin(2 * d - 2 * mp - f) +
      0.004200 * math.sin(2 * d - m + f);
  // 地心距离（km）—— Meeus 表 47.A 主要项
  final rKm = 385000.56 -
      20905.355 * math.cos(mp) -
      3699.111 * math.cos(2 * d - mp) -
      2955.968 * math.cos(2 * d) -
      569.925 * math.cos(2 * mp) +
      246.158 * math.cos(2 * d - 2 * mp) -
      170.733 * math.cos(2 * d + mp) -
      204.586 * math.cos(2 * d - m) -
      152.138 * math.cos(2 * d - m - mp) -
      129.620 * math.cos(m) +
      108.743 * math.cos(d) +
      104.755 * math.cos(m + mp);

  final lonEcl = (lp + sumL) * kDeg;
  final latEcl = sumB * kDeg;

  // 黄道 → 赤道
  const obliq = 23.4392911 * kDeg;
  final xe = math.cos(latEcl) * math.cos(lonEcl);
  final ye = math.cos(obliq) * math.cos(latEcl) * math.sin(lonEcl) -
      math.sin(obliq) * math.sin(latEcl);
  final ze = math.sin(obliq) * math.cos(latEcl) * math.sin(lonEcl) +
      math.cos(obliq) * math.sin(latEcl);
  final ra = math.atan2(ye, xe);
  final dec = math.atan2(ze, math.sqrt(xe * xe + ye * ye));

  // 时角
  final n = jd - 2451545.0;
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

  // 地平视差（地心 → 站心）：sin π = R_earth/r，最大 0.95°。
  final rEarth = rKm / 6378.14; // 以地球赤道半径为单位
  final par = math.asin((1.0 / rEarth).clamp(0.0, 1.0));
  final altTopo = alt - par * math.cos(alt);
  return BodyPosition(azDeg, apparentAltitudeDeg(altTopo / kDeg));
}

/// 月相（0=新月，0.5=满月）—— 由**日月黄经差**（真实几何）给出，
/// 而不是用平朔望月近似推（受摄动影响可达 ±0.3~0.6 天）。
double moonPhase(DateTime dtUtc) {
  final utc = dtUtc.toUtc();
  final jd = julianDay(utc);
  final T = (jd - 2451545.0) / 36525.0;
  // 月亮黄经（[moonPosition] 级数的主要项）
  final lp = 218.3164477 + 481267.88123421 * T;
  final dAng = 297.8501921 + 445267.1114034 * T;
  final mpAng = 134.9633964 + 477198.8675055 * T;
  final d = dAng * kDeg, mp = mpAng * kDeg;
  final sumL = 6.288774 * math.sin(mp) +
      1.274027 * math.sin(2 * d - mp) +
      0.658314 * math.sin(2 * d) +
      0.213618 * math.sin(2 * mp);
  final lonMoon = lp + sumL;
  // 太阳黄经（与 sunPosition 同一低精度式）
  final l = (280.460 + 0.9856474 * (jd - 2451545.0)) % 360.0;
  final g = ((357.528 + 0.9856003 * (jd - 2451545.0)) % 360.0) * kDeg;
  final lonSun = l + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g);
  var elong = (lonMoon - lonSun) % 360.0;
  if (elong < 0) elong += 360.0;
  return elong / 360.0;
}

/// 月相亮度因子（0=新月不可见，1=满月）。
///
/// 用**光照几何 + 月面相位函数**，而不是把相位线性当亮度：月面亮度随相角
/// 的下降比照亮面积更快（冲日效应）。相角 α 的星等亏损用 Allen 的经验式
/// Δm = 0.026·|α| + 4×10⁻⁹·α⁴（α 单位度），再乘照亮面积比 (1+cosα)/2。
double moonBrightnessFactor(double phase) {
  final alpha = (1.0 - 2.0 * phase).abs() * 180.0; // 相角（度）
  final frac = (1.0 + math.cos(alpha * kDeg)) / 2.0; // 照亮面积比
  final dm = 0.026 * alpha + 4e-9 * alpha * alpha * alpha * alpha;
  return (frac * math.pow(10.0, -0.4 * dm).toDouble()).clamp(0.0, 1.0);
}

// ─────────────────────────── 大气物理 ───────────────────────────

/// 相对大气质量 m(h)：Young (1994) 的解析式。
///
/// Young, A. T. (1994), Applied Optics 33(6)：该有理式在天顶归一为 1、
/// 在地平线附近保持有限值，且**在地平线上下连续**。旧实现用 Kasten-Young
/// 并在 h≤0 处硬返回 40.0、h 较大处再钳到 40：地平线两侧的光学厚度从
/// 37.9 跳到 40，且钳制使地平线以下任何高度角的透过率都相同（直射亮度被
/// "冻结"，在暮光/日出处叠加一个人为台阶）。
///
/// 自检：m(90°)=1.0000、m(30°)=1.9917、m(0°)=31.7、m(−1°)=58.6。
double airMassKastenYoung(double altDeg) {
  final a = altDeg > 90.0 ? 90.0 : altDeg;
  final s = math.sin(a * kDeg);
  final s2 = s * s;
  final num = 1.002432 * s2 + 0.148386 * s + 0.0096467;
  final den = s2 * s + 0.149864 * s2 + 0.0102963 * s + 0.000303978;
  return num / math.max(den, 1e-9);
}

/// 大气折射抬升（度）—— Saemundsson (1986)：
///   R(弧分) = 1 / tan( h + 7.31/(h + 4.4) )，h 为几何高度角（度）。
/// 标准大气（1010 hPa / 10 °C）下：地平线 34.5′（0.575°）、5° 处 0.165°、
/// 10° 处 0.090°、45° 处 0.017°。地平线的 0.575° 比日轮本身（0.53°）还大，
/// 即忽略折射时低太阳角的位置与时刻都会明显错位（光斑偏几厘米、光斑进出
/// 观察墙的时刻偏数分钟）。
double atmosphericRefractionDeg(double geoAltDeg) {
  if (geoAltDeg > 89.0) return 0.0;
  final h = geoAltDeg < -1.5 ? -1.5 : geoAltDeg;
  final arg = (h + 7.31 / (h + 4.4)) * kDeg;
  final arcMin = 1.0 / math.tan(arg);
  return (arcMin / 60.0).clamp(0.0, 0.7);
}

/// 几何高度角 → **视高度角**（含大气折射）。
///
/// 地平线以下 2° 之外不再施加（折射式在那里失去物理意义，且此时直射光束
/// 本就不存在）。airMass 的输入定义为视高度角，场景太阳方向也必须用它。
double apparentAltitudeDeg(double geoAltDeg) {
  if (geoAltDeg < -2.0) return geoAltDeg;
  return geoAltDeg + atmosphericRefractionDeg(geoAltDeg);
}

/// 气溶胶光学厚度（550 nm）—— 由能见度经 Koschmieder 关系反解。
///
///   τ_ext(550) = 3.912 / V(km)
///   AOD550 = τ_ext − τ_R(550) − τ_O₃(550)
///
/// 这样"能见度"这个物理量真正进入计算，而不是像早期实现那样
/// 给一个写死的灰 τ=0.05（且那条能见度分支永远不生效 = 死代码）。
///
/// AOD550 的**季节因子**（北半球中纬度经验，据 AERONET 多站月均值的
/// 代表形状）。气溶胶负荷春夏高（沙尘输送+吸湿增长）、秋冬低：
/// 余弦拟合 1 + 0.225·cos(2π(doy−200)/365)，峰值约 7 月中（doy≈200）。
/// [doy] 为一年中的日序（1~366）。南半球取 doy+182.5（季节翻转）。
double aodSeasonFactor(int doy, {bool southernHemisphere = false}) {
  final d = southernHemisphere ? (doy + 182.5) % 365.25 : doy.toDouble();
  return 1.0 + 0.225 * math.cos(2 * math.pi * (d - 200.0) / 365.0);
}

double aod550FromVisibility(double visM, {int? dayOfYear}) {
  final vis = visM < 200 ? 200.0 : visM;
  final tauExt = 3.912 / (vis / 1000.0);
  final tauR = rayleighTau(550.0);
  final tauO3 = ozoneTau(550.0);
  final aod = math.max(0.001, tauExt - tauR - tauO3);
  // 季节调制（甲类⑪，默认启用）：给定日序则乘季节因子，未给定视为年均。
  // 季节峰值差 ±22%，对 aureole 权重与直射衰减都是同量级的可感差。
  return dayOfYear == null ? aod : aod * aodSeasonFactor(dayOfYear);
}

/// 分波长太阳辐照度（线性 sRGB，天顶辐亮度归一化为 1）。
///
/// 由**真实光谱积分**得到：普朗克光谱 × 分波长大气透过率 × CIE 1931 CMF。
/// 详见 spectrum.dart 的说明 —— 早期实现用"高度角→色温→黑体→RGB"的
/// 拟合旁路，既丢掉了本文件算出的分波长透过率，又把 gamma 编码的显示值
/// 当作线性光使用。
List<double> solarIrradianceRgb(double altDeg, [double visM = 20000.0]) {
  if (altDeg < 0) {
    // 地平线以下：直射为 0（暮光散射光由 skyIrradiance / twilight 分支负责）
    return <double>[0, 0, 0];
  }
  return solarSpectrum(altDeg, aod550: aod550FromVisibility(visM)).rgb;
}

/// 太阳直射的相对亮度（天顶 = 1）。
double solarIrradiance(double altDeg, [double visM = 20000.0]) {
  if (altDeg < 0) return 0.0;
  return solarSpectrum(altDeg, aod550: aod550FromVisibility(visM)).luminance;
}

/// 太阳直射的**色度**（线性 RGB，亮度归一化为 1）。
///
/// 与 [solarIrradiance] 相乘即还原出绝对光谱辐照度：
///     E_rgb = luminance × chroma
/// 日落偏红完全来自大气透过率，不再有色温表。
///
/// 极低太阳角（alt ≲ 2°）时色度会**超出 sRGB 色域**（线性 B 分量变负）——
/// 这是真实的：sRGB 原色三角形装不下日出/日落那样的高饱和红橙。
/// 这里裁到 0（丢失一点色相精度，但 sRGB 本来就表达不了）；
/// 若将来换用宽色域输出，应改为色域映射而不是裁剪。
List<double> sunColorFromAltitude(double altDeg) {
  if (altDeg < 0) return <double>[1, 1, 1];
  final s = solarSpectrum(altDeg);
  if (s.luminance <= 1e-12) return <double>[1, 1, 1];
  return <double>[
    math.max(0.0, s.rgb[0] / s.luminance),
    math.max(0.0, s.rgb[1] / s.luminance),
    math.max(0.0, s.rgb[2] / s.luminance),
  ];
}

/// 天光（天空漫射）水平照度，晴天。量纲：天顶直射法向照度 = 1。
///
/// 物理：晴天漫射水平照度与直射水平照度之比随太阳高度下降而升高（太阳越低、
/// 直射光程越长，散射占比越大），晴天实测在 0.10（高日）~0.16（近地平）
/// 之间（Iqbal 1983 一类晴天散射比量级）。用这条**有界的物理比值**取代旧的
/// "0.22·sin^0.6"经验幂律 —— 后者在 h→0 处把漫射强行压到 0，与暮光分支
/// 之间留下一帧级跳变（日落前一秒几乎全黑、下一秒环境光凭空出现）。
/// 天光（天空漫射）水平照度，晴天。量纲：晴天正午全局照度 ≈ 1。
///
/// 晴天漫射水平照度对太阳高度角的依赖很弱：地平线处仍约为天顶的一半
/// （日落时整个天空穹顶仍被照亮，全球照度主要由漫射贡献），因此**不能**写成
/// `0.22·sin^0.6` 这种在 h→0 处趋于 0 的幂律 —— 那会在日落瞬间把漫射压到 0，
/// 与暮光分支之间留下一帧级跳变。取晴天实测值：天顶 ≈ 0.11、地平线 ≈ 0.05
/// （相对正午全局照度，Iqbal 1983 一类晴天散射量级）。
double skyIrradiance(double sunAlt) {
  if (sunAlt <= 0) return 0.0;
  return 0.05 + 0.06 * math.sin(sunAlt * kDeg).clamp(0.0, 1.0);
}

/// 暮光漫射水平照度（相对正午全局 ≈ 1）。
///
/// 太阳落到地平线下时，天空漫射由仍被照亮的高层大气提供，随下沉角近似指数
/// 衰减（实测民用暮光 0~6° 约下降两个数量级，即每 ~3° 约一个数量级），且必须
/// 在 h=0 处与 [skyIrradiance] **连续**。深夜自然夜空（气辉+星光）比民用暮光
/// 尽头还暗约 4 个数量级，属观察者/相机模型范畴（见待决策）。
double twilightDiffuse(double sunAlt) {
  if (sunAlt > 0) return skyIrradiance(sunAlt);
  return 0.05 * math.pow(10.0, sunAlt / 3.0).toDouble();
}

/// 满月天顶的相对月光照度（工程夜间量纲；见 [moonIrradiance]）。
const double kMoonZenithRel = 0.20;

/// 月光法向照度。量纲同太阳。
///
/// 月光就是被同一层大气衰减、被月面反射的太阳光，因此角依赖必须用与太阳
/// **同一套**分波长光学厚度（直接复用 [solarIrradiance]，它已含 airmass
/// 消光并归一化到天顶 = 1），而不是换一个灰度消光系数 0.20；低月角处也不再
/// 硬切（旧实现 moonAlt < 5° 直接返回 0 → 月光斑"啪"地出现）。
///
/// 月亮角直径（度）。月面为朗伯散射面，**无临边昏暗**（与太阳相反：
/// 满月时月盘边缘反而略亮）。角径随地月距离变化 ±5%（Meeus：
/// 近地点 0.2617° 远地点 0.2470° 之间视差修正后的几何角径），
/// 但对 3 m 墙上半影的差别 <0.5 px，取平均几何值即可。
const double kMoonAngularDiameterDeg = 0.2556;

/// 绝对量级：月光与太阳的真实照度比约 2.5×10⁻⁶（满月 0.25 lx / 太阳
/// 1×10⁵ lx）；本管线的绝对量级由自动曝光负责，故此处保留"满月天顶 ≈ 0.20"
/// 的夜间相对标定，真实绝对比值需相机模型才能落地（见待决策）。
double moonIrradiance(double moonAlt, double phase) {
  if (moonAlt <= 0) return 0.0;
  final trans = solarIrradiance(moonAlt); // 与太阳相同的空气消光，天顶 = 1
  return kMoonZenithRel * moonBrightnessFactor(phase) * trans;
}

/// 夜空照明（无月自然夜空：气辉 + 星光；可选城市人工辉光）＋ 月光散射。
///
/// 无月部分的**亮度底**取民用暮光尽头（h = −6°）的漫射照度，从而与
/// [twilightDiffuse] 在 −6° 处连续（不出现"暮光结束瞬间跳暗"的台阶）；
/// 城市人工辉光（Walker 定律的亮度增量）作为**站点参数** [cityGlow] 暴露，
/// 默认 0（自然夜空）。月光的散射分量按其漫射比（晴天 ≈ 0.10）从
/// [moonIrradiance] 推出，而不是再给一个独立常数。
double nightSkyIrradiance(double moonAlt, double phase,
    {double cityGlow = 0.0}) {
  final natural = twilightDiffuse(-6.0);
  var moonAmb = 0.0;
  if (moonAlt > 0) {
    moonAmb = moonIrradiance(moonAlt, phase) * 0.10;
  }
  // 【白名单 kCityGlowScale】输入缩放（默认 0.5）：城市辉光参数本意是
  // "夜空相对自然底的倍增"，但直接作倍数时市区（2.0）会把夜空抬到
  // "像开灯"——夜里整面墙变亮的主因。缩到不夸张区间，见 tuning.dart。
  return natural * (1.0 + math.max(0.0, cityGlow) * kCityGlowScale) + moonAmb;
}

/// 散射天空（或暮光）的颜色：Rayleigh 散射光的光谱经 CIE 积分，最大分量
/// 归一化为 1。
///
/// **光程必须封顶**：若用"太阳到地面"的全光程，低日时蓝光被吃尽，天空色会
/// 变成饱和橙红 —— 但真实的天空并不是这样。天光来自**高层大气**的散射，
/// 那束光走完剩余大气之前就已经进到观察者眼里；被严重红化的是**直射光束**，
/// 不是天空本身。故此处对光学厚度取上限（[maxAirMass]）：
///   · 正午：天蓝；
///   · 黄昏：天顶仍是蓝灰（真实民用暮光即深蓝），暖色只出现在**地平线亮带**，
///     而室内环境光由大面积蓝天主导，故整体偏蓝；
///   · 夜间：蓝灰。
/// 暖色由**直射光**（[sunColorFromAltitude]）承担，不从天光里伪造。
List<double> skyColor(double sunAlt) => _scatterColor(sunAlt);

List<double> _scatterColor(double sunAltDeg, {double maxAirMass = 6.0}) {
  final a = sunAltDeg < -8.0 ? -8.0 : (sunAltDeg > 90.0 ? 90.0 : sunAltDeg);
  final am = math.min(airMassKastenYoung(a), maxAirMass);
  var x = 0.0, y = 0.0, z = 0.0;
  for (var l = 380.0; l <= 780.0; l += 2.0) {
    final e = planckRel(l) * atmosphericTransmittance(l, am) * rayleighTau(l);
    x += e * cieX(l);
    y += e * cieY(l);
    z += e * cieZ(l);
  }
  final rgb = xyzToLinearSrgb(x, y, z);
  var m = rgb[0];
  if (rgb[1] > m) m = rgb[1];
  if (rgb[2] > m) m = rgb[2];
  if (m <= 1e-12) return <double>[1, 1, 1];
  return <double>[
    math.max(0.0, rgb[0] / m),
    math.max(0.0, rgb[1] / m),
    math.max(0.0, rgb[2] / m),
  ];
}

/// 月光颜色（线性 RGB）。
///
/// 月光 = 太阳光谱 × 月面反照率谱（月壤在可见光近似中性、略偏暖）× 月球
/// 高度角上的大气透过率，因此它的颜色就是**太阳在同一高度角的颜色**
/// （同一个 [sunColorFromAltitude]）。不要再写一张"月光＝蓝"的表：肉眼觉得
/// "月夜偏蓝"是**暗视觉珀金杰位移**造成的观察者效应，属于观察者模型
/// （CIE 191:2010 中间视觉），不属于光源。
List<double> moonColorRgb(double moonAlt) {
  if (moonAlt <= 0) return <double>[1, 1, 1];
  return sunColorFromAltitude(moonAlt);
}

/// 太阳有效角半径（度）—— [sunAngularDiameterDeg] 的一半，供几何层使用。
double sunAngularRadiusDeg(double altDeg) => sunAngularDiameterDeg(altDeg) * 0.5;

/// 太阳**几何**角直径（度）—— 只随日地距离变化（±1.7%），与高度角无关，
/// 平均 0.5331°（近地点 0.5422°、远地点 0.5244°）。
///
/// 旧实现给了一个 `0.53·AM^0.6`（封顶 3°）的幂律，并把它说成"低太阳角时
/// 米氏前向散射把日轮糊成 2~3° 的扩展源"。这是错的：**日面几何角径与太阳
/// 高度角无关**，而大气前向散射产生的是**环日散射（aureole）**——一条低辐
/// 亮度的幂律尾部（环日/CSR 只有直射光束的百分之几），不是把一个均匀亮盘
/// 放大到 3°。把两者混成一个幂律会同时把环日能量与半影宽度算错。
///
/// 半影的物理来源是"日面（几何角径）⊗ 大气 PSF"的卷积；本工程按几何日面
/// 处理（PSF 额外加宽极小）。aureole 若要显式建模，应由大气模块给出其角
/// 分布（幂律尾部），不能塞进这个"等效圆盘直径"。
///
/// [altDeg] 仅为兼容既有调用方的签名保留。
double sunAngularDiameterDeg(double altDeg) {
  return 0.5331;
}

/// 暮光天光环境色（线性 RGB）：太阳在地平线下 0~6° 时散射进入室内的色。
/// 与 [skyColor] 同一物理（Rayleigh 散射光的天空光谱），只是太阳高度角更低、
/// 光程更长，故自然从暖橙过渡到灰蓝，不再需要 8 档手调色表。
List<double> twilightAmbientColor(double sunAlt) => _scatterColor(sunAlt);

/// 暮光颜色（线性 RGB）。太阳在地平线以上时即太阳直射色。
List<double> twilightColor(double altDeg) {
  if (altDeg >= 0) return sunColorFromAltitude(altDeg);
  return _scatterColor(altDeg);
}
