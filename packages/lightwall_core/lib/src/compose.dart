// 合成（线性光 → sRGB 成品）
//
// 物理成像链（CO-13：每一步都有明确的物理位置，而不是把物理量当后处理滤镜）：
//
//   场景辐亮度 L(x,λ)                       ← 渲染方程（tracer 直射 + 环境光）
//   → 一次弹射（室内互反射，**线性域**）      ← CO-6（强度 ∝ 光斑辐照度本身）
//   → 曝光 H = E·t（**线性域**、单一增益）    ← CO-1 / CO-12
//   → 色调映射 ODT（**唯一一次**非线性压缩）  ← CO-7（ACES RRT+ODT，AP0 联立）
//   → 显示编码（sRGB 传递函数 + TPDF 抖动）   ← CO-11
//
// "相机风格"只允许在光谱/传感器那一层进入（QE、色彩矩阵、噪声）；本文件的
// **默认配置不含任何显示域魔数**，下面几个非物理旋钮一律默认关闭并在各自
// 的注释里写明"无物理依据"，只作显式 opt-in 用。
//
// 【CO-2 / CO-10 待决策】镜头渐晕（[LookConfig.vignetteStrength]）按产品要求
// 保留现状：物理正确形式是自然渐晕 cos⁴θ（θ = atan(r/f)，由焦距与画幅决定；
// 24mm 全画幅角落 cos⁴θ ≈ 0.32，即 −68%），机械/口径渐晕另计，而且必须作用在
// 传感器之前的**线性场景域**。对"平面墙 + 近正交投影"的壁纸场景 θ≈0，物理上
// 根本不该有渐晕。删掉它还是按镜头参数物理化属于产品决策，见
// /var/minis/workspace/lw_fix_A.md「待决策」。
import 'dart:math' as math;
import 'dart:typed_data';

import 'mathx.dart';
import 'tuning.dart';

/// 相机效果与画面参数。
///
/// 除 [exposure]/[acesGain]（曝光，物理量）与 [saturation]/[contrast]
/// 除 [bloomStrength]（镜头散射，有物理依据，默认 0.15 启用）外，其余
/// 调味字段都**没有物理依据**，默认值一律取"不生效"。
class LookConfig {
  const LookConfig({
    this.acesGain = 1.0,
    this.vignetteStrength = 0.0,
    this.shadowBlueTint = 0.0,
    this.sensorCurveStrength = 0.0,
    this.materialStrength = 0.0,
    this.patchBounceStrength = 1.0,
    this.exposure = 1.0,
    this.saturation = 1.0,
    this.contrast = 1.0,
    this.bloomStrength = 0.15,
  });

  /// 【CO-1】色调映射前的曝光增益。
  ///
  /// 旧值 1.25 是一个**烘焙的 +0.32 EV 固定过曝**（既不是物理常数，也不由
  /// 场景推导；实测平均 |Δ| = 4.6 码、最大 17 码、7.9% 像素差 >10 码）。
  /// 曝光必须由**测光**推出（场景辐亮度 + 相机参数：H = E·t），而测光在
  /// pipeline 里完成并已在线性域施加；本字段因此只剩"用户显式指定的相机
  /// 曝光补偿"这一层含义，默认 1.0 = 无补偿。
  final double acesGain;

  /// 【CO-2 / CO-10 待决策】渐晕强度（保留现状，见文件头说明）。
  final double vignetteStrength;

  /// 【CO-3】暗部加蓝（显示域手调偏色）。**无物理依据**，默认关闭。
  ///
  /// 渲染方程里不存在"暗部偏蓝"这一项：颜色只能来自光谱 —— 天空 SPD
  /// （Rayleigh ∝λ⁻⁴，天光天然偏蓝）、光源 SPD、白平衡。旧值 0.06 在夜景
  /// 暗部实测把 B 通道抬高 **+17.7 码**、G +10 码（全图平均 |Δ| = 5.0，
  /// 16% 像素 >10 码），是肉眼一眼可见的蓝色蒙版。
  final double shadowBlueTint;

  /// 【CO-4】"CMOS 响应曲线"（随显示值线性变化的乘子）。**无物理依据**，
  /// 默认关闭。真正的传感器行为是线性光电转换 + 暗电流 + 光子散粒噪声
  /// （泊松）+ 读出噪声 + ADC 量化 + 相机色彩矩阵，不是乘一个 1.05 的斜坡。
  final double sensorCurveStrength;

  /// 【CO-5】色调映射后把底图结构再乘一遍（与 BRDF 里的反射率 ρ **双重
  /// 计入**）。**无物理依据**，默认关闭：反射率只应出现在 BRDF 里
  /// （L_o = (ρ/π)∫L_i·cosθ dω + 镜面项）。
  final double materialStrength;

  /// 【CO-6】一次弹射（室内互反射）的显式倍率，1.0 = 物理计算值。
  ///
  /// 旧值 0.12 是一个"强度"常数，配合固定暖色 (1.00,0.92,0.80) 与
  /// 用**显示尺度**驱动的源，等于伪造的 GI；现在强度就是场量本身
  /// （唯一的常数 1/π 来自朗伯 BRDF），本字段只作显式缩放用。
  final double patchBounceStrength;

  /// 用户曝光倍率（线性域，色调映射**之前**；见
  /// [synthesize] 第 3 步）。物理上曝光是场景线性域的乘性增益。
  final double exposure;

  /// 饱和度（显示域色度缩放，亮度轴用 Rec.709 亮度权重）。
  final double saturation;

  /// 对比度（等价于改变显影 γ / 显示 EOTF 的 γ，单调幂律，0→0、1→1）。
  final double contrast;

  /// 镜头 bloom（乙类①，默认 0.15 启用）：强光源（>1.0 线性）向周围泄漏
  /// 的柔光晕。物理来源：镜头内多组镜面的散射（veiling glare）与人眼晶状
  /// 体散射；真实照片里没有"纯白死光斑"。
  final double bloomStrength;

  LookConfig copyWith({
    double? exposure,
    double? saturation,
    double? materialStrength,
    double? contrast,
    double? vignetteStrength,
  }) =>
      LookConfig(
        acesGain: acesGain,
        vignetteStrength: vignetteStrength ?? this.vignetteStrength,
        shadowBlueTint: shadowBlueTint,
        sensorCurveStrength: sensorCurveStrength,
        materialStrength: materialStrength ?? this.materialStrength,
        patchBounceStrength: patchBounceStrength,
        exposure: exposure ?? this.exposure,
        saturation: saturation ?? this.saturation,
        contrast: contrast ?? this.contrast,
      );
}

// ───────────────────────── ACES 色调映射（RRT + sRGB ODT）─────────────────────────
//
// 【CO-7】旧实现用 Narkowicz 单曲线逐通道冒充 ACES：缺 AP1/AP0 工作空间、
// 缺色度压缩与色域映射（高饱和色被各通道不同斜率洗白、色域外颜色被硬切），
// 而且拟合的渐近值 2.51/2.43 = 1.0329 > 1 —— 输出根本不是合法显示信号，
// 只能靠后面硬限幅兜底。
//
// 这里改用 ACES RRT+ODT 的解析拟合（Stephen Hill 对 aces-dev RRT+ODT 的
// 公开拟合式）在 **AP0(ACES2065-1)** 工作空间里**三通道联立**施加：
//   · ACESInputMat  : 线性 sRGB(Rec.709, D65) → AP0 —— 规范矩阵；
//   · RRTAndODTFit  : ACES RRT + sRGB ODT 的解析拟合（含 ACES 的色调曲线）；
//   · ACESOutputMat : AP1(ACEScg) → 线性 Rec.709 —— 规范矩阵。
// 这些系数是**标准定义**的变换常数（SMPTE ST 2065-1 / ACEScg 规范），不是
// 为画面好看挑的参数。

/// 拟合式 `RRTAndODTFit` 的分母二次项系数（ACES 拟合的公开系数）。
///
/// 它同时就是拟合的渐近值倒数：f(∞) = 1/0.983729 = 1.0165 > 1。为让输出
/// 成为**合法显示信号**（f(∞) = 1），在曲线输出上乘回该系数 —— 归一化因子
/// 取自拟合式自身，不引入新常数。
const double _acesFitDen0 = 0.983729;

/// 线性 sRGB(Rec.709, D65) → ACES2065-1 (AP0)，行主序（每行和 = 1，灰轴不变）。
const List<double> _acesInputMat = <double>[
  0.59719, 0.35458, 0.04823, //
  0.07600, 0.90834, 0.01566, //
  0.02840, 0.13383, 0.83777, //
];

/// AP1(ACEScg) → 线性 Rec.709，行主序（每行和 = 1，灰轴不变）。
const List<double> _acesOutputMat = <double>[
  1.60475, -0.53108, -0.07367, //
  -0.10208, 1.10813, -0.07276, //
  -0.00327, -0.00605, 1.07602, //
];

/// 参考中灰反射率（ISO 2720 反射式测光的**中灰约定** / Kodak 18% 灰卡）。
///
/// 任何"场景线性 → 显示"的输出变换（ODT）都必须带一条**参考曝光**：没有它，
/// 亮度就落在变换曲线上的任意一点，同一个场景换个 ODT 就整体漂移。这里的约定
/// 是摄影/显示的标准约定 —— 场景 18% 中灰映到显示 18%（线性）。该常数就是
/// 约定本身（ISO 2720 / Kodak 灰卡），不是调色参数。
const double kReferenceMidGray = 0.18;

/// ODT 参考曝光（线性域增益）。
///
/// 由 [_rrtOdtFit] 与中灰约定**解出来**（二分求根），不是挑出来的数：
/// 换任何别的输出变换都会自动得到它自己的参考曝光。
/// 它属于 ODT（显示变换的锚点），测光给出的绝对曝光由 pipeline 施加。
final double kAcesReferenceExposure = _solveAcesReferenceExposure();

double _solveAcesReferenceExposure() {
  var lo = 0.01, hi = 100.0;
  for (var i = 0; i < 80; i++) {
    final mid = 0.5 * (lo + hi);
    if (_rrtOdtFit(mid * kReferenceMidGray) < kReferenceMidGray) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return 0.5 * (lo + hi);
}

/// 三通道联立 ACES RRT+ODT（就地）。
///
/// 注：中性灰轴上两个矩阵都退化为恒等（行和 = 1），所以灰轴响应就等于
/// [_rrtOdtFit]；`mathx.acesToneMap` 仍是旧的 Narkowicz 逐通道拟合，只被
/// `bin/check.dart` 用于打印自检值（不参与渲染链，非本文件范围）。
///
/// 逐通道独立施加是**错的**：色调映射在 AP0/AP1 工作空间里做，含色度压缩
/// 与到 Rec.709 的色域映射，必须三通道一起才会保持色相。
void toneMapInPlace(Float32List rgb, int n) {
  for (var i = 0; i < n; i++) {
    final j = i * 3;
    // ODT 参考曝光（见 [kAcesReferenceExposure]）：把场景中灰锚到显示中灰
    final r = rgb[j] * kAcesReferenceExposure;
    final g = rgb[j + 1] * kAcesReferenceExposure;
    final b = rgb[j + 2] * kAcesReferenceExposure;
    // 线性 sRGB → AP0
    var a0 = _acesInputMat[0] * r + _acesInputMat[1] * g + _acesInputMat[2] * b;
    var a1 = _acesInputMat[3] * r + _acesInputMat[4] * g + _acesInputMat[5] * b;
    var a2 = _acesInputMat[6] * r + _acesInputMat[7] * g + _acesInputMat[8] * b;

    a0 = _rrtOdtFit(a0);
    a1 = _rrtOdtFit(a1);
    a2 = _rrtOdtFit(a2);

    // AP1 → 线性 Rec.709
    final o0 = _acesOutputMat[0] * a0 +
        _acesOutputMat[1] * a1 +
        _acesOutputMat[2] * a2;
    final o1 = _acesOutputMat[3] * a0 +
        _acesOutputMat[4] * a1 +
        _acesOutputMat[5] * a2;
    final o2 = _acesOutputMat[6] * a0 +
        _acesOutputMat[7] * a1 +
        _acesOutputMat[8] * a2;
    rgb[j] = clampd(o0);
    rgb[j + 1] = clampd(o1);
    rgb[j + 2] = clampd(o2);
  }
}

/// 单通道 RRT+ODT 拟合（已按渐近值归一化，f(∞) = 1）。
double _rrtOdtFit(double x) {
  final v = x < 0 ? 0.0 : x;
  final a = v * (v + 0.0245786) - 0.000090537;
  final b = v * (_acesFitDen0 * v + 0.4329510) + 0.238081;
  return a / b * _acesFitDen0;
}

/// 兼容旧的逐通道入口（ACES 之前乘一个增益）。gain = 1.0 时为恒等曝光。
void acesInPlace(Float32List rgb, double gain) {
  final n = rgb.length ~/ 3;
  if ((gain - 1.0).abs() > 1e-9) {
    for (var i = 0; i < rgb.length; i++) {
      rgb[i] *= gain;
    }
  }
  toneMapInPlace(rgb, n);
}

// ───────────────────────────────── 合成 ─────────────────────────────────

/// 合成：直射 + 环境（线性域求和） → 一次弹射 → 曝光 → 色调映射 → 显示。
///
/// [direct] 与 [ambient] 均为线性 RGB（w*h*3），并且**已含测光曝光**
/// （曝光由 pipeline 的测光给出，见 [LookConfig.acesGain] 说明）。
Float32List synthesize({
  required Float32List direct,
  required Float32List ambient,
  required int width,
  required int height,
  required LookConfig look,
  Float32List? materialVariation,
  Float32List? patchMask,
}) {
  final n = width * height;
  final out = Float32List(n * 3);

  // 1. **线性域**先把所有辐射求和：直射 + 环境
  //
  // 物理上必须先在线性域求和，再对整个辐射场**统一**做一次色调映射
  // （直射与环境各自过不同的响应曲线会让光斑边界出现色调断裂）。
  for (var i = 0; i < n * 3; i++) {
    out[i] = direct[i] + ambient[i];
  }

  // 2. 一次弹射（室内互反射），线性域，由光斑辐照度本身驱动 —— CO-6
  if (patchMask != null && look.patchBounceStrength != 0) {
    _addFirstBounce(out, patchMask, width, height, look.patchBounceStrength);
  }

  // 3. 曝光：线性域的乘性增益，必须在色调映射**之前** —— CO-12 / CO-1
  //
  // 旧实现把 exposure 乘在色调映射之后，那在摄影术语里是"显影/levels 提亮"，
  // 不是曝光：它不会让高光沿曲线滚降，只会把高光推出去再被限幅削平。
  final gain = look.exposure * look.acesGain;
  if ((gain - 1.0).abs() > 1e-9) {
    for (var i = 0; i < n * 3; i++) {
      out[i] *= gain;
    }
  }

  // 4. 材质结构调制（**线性域**；物理上默认**不该存在**，见 CO-5）
  //
  // 反射率 ρ 已经作为 BRDF 的漫反射基色进入渲染方程，这里再按底图结构乘一遍
  // 等于把同一份 ρ 计两次。默认 materialStrength = 0（关闭）。若显式打开，
  // 它至少必须作用在**线性辐射**上（旧实现在色调映射之后，等于一个显示域蒙版）。
  if (materialVariation != null && look.materialStrength > 0) {
    for (var i = 0; i < n; i++) {
      final f = 1.0 + (materialVariation[i] - 1.0) * look.materialStrength;
      out[i * 3] *= f;
      out[i * 3 + 1] *= f;
      out[i * 3 + 2] *= f;
    }
  }

  // 4.5 镜头渐晕（物理位置：传感器之前的**线性场景域**）—— CO-2 / CO-10
  //
  // 默认 0：被成像的是一面**平面墙**，近正交投影下像场角 θ≈0，物理上根本
  // 不应有渐晕。若显式开启，按自然渐晕 cos⁴θ 的形状施加在**线性域**
  // （v = 1 − s·(1 − cos⁴θ)）。精确的 θ 需镜头焦距/画幅（见待决策）。
  // 旧实现在色调映射**之后**施加二次径向暗角（v = 1 − 0.15·r²），等于给
  // 画面贴一层没有光学来源的蒙版，且高光不会沿曲线滚降。
  if (look.vignetteStrength > 0) {
    final cx = width / 2.0, cy = height / 2.0;
    final maxDist = math.sqrt(cx * cx + cy * cy);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x - cx, dy = y - cy;
        final r = math.sqrt(dx * dx + dy * dy) / maxDist; // 0..1
        final cosT = 1.0 / math.sqrt(1.0 + r * r); // 近轴近似 cosθ
        final c4 = cosT * cosT * cosT * cosT;
        final v = 1.0 - look.vignetteStrength * (1.0 - c4);
        final i = (y * width + x) * 3;
        out[i] *= v;
        out[i + 1] *= v;
        out[i + 2] *= v;
      }
    }
  }

  // 5. 统一色调映射：所有辐射共用同一条响应曲线（ACES RRT+ODT）
  toneMapInPlace(out, n);

  // 5.5 胶片响应补足（成像层）：趾部抬升 + 肩部滚降 + 冷阴影。
  //
  // 这**不是**调色滤镜，是补上"负片/相机/人眼"这一段的响应：
  //   · 趾部：暗部不压到 0（参考照片里暗部是可读的深灰蓝，而非死黑）
  //   · 肩部：光斑不顶成死白（参考图光斑内仍看得见窗格与纹理）
  //   · 冷阴影：阴影唯一光源是天光（~10000 K），直射是暖的 → 暖斑冷影
  // 三者都有物理来源，量级由 tuning.dart 的白名单常数控制。
  {
    final lift = kFilmicShadowLift;
    final roll = kHighlightRolloff;
    for (var i = 0; i < n; i++) {
      final j = i * 3;
      final lum = 0.2126 * out[j] + 0.7152 * out[j + 1] + 0.0722 * out[j + 2];
      // 趾部：把暗部整体抬起一个量（lum 越低抬得越多），保持端点 0 附近连续
      final toe = lift * (1.0 - lum).clamp(0.0, 1.0);
      // 肩部：**轻微**压缩（ACES 已做主要滚降，这里只补一点胶片肩部的
      // 平缓感）。旧写法 roll·lum² 在 lum=1 处直接减 0.55，把光斑砍死在
      // 194/255（实测），光斑永远亮不起来。
      final shoulder = roll * 0.2 * (lum * lum * lum);
      final adj = toe - shoulder;
      out[j] = (out[j] + adj).clamp(0.0, 1.0);
      out[j + 1] = (out[j + 1] + adj).clamp(0.0, 1.0);
      out[j + 2] = (out[j + 2] + adj).clamp(0.0, 1.0);
      // 冷阴影：暗部向蓝偏移（天光照亮的阴影），高光保持暖
      final wgt = (1.0 - lum).clamp(0.0, 1.0) * kShadowCoolShift;
      if (wgt > 0) {
        out[j] = (out[j] - wgt * 0.05).clamp(0.0, 1.0);
        out[j + 2] = (out[j + 2] + wgt * 0.07).clamp(0.0, 1.0);
      }
    }
  }

  // 6. 暗部偏色（显示域、无物理依据，默认关闭）—— CO-3
  if (look.shadowBlueTint > 0) {
    for (var i = 0; i < n; i++) {
      final lum = (out[i * 3] + out[i * 3 + 1] + out[i * 3 + 2]) / 3.0;
      final wgt = (1.0 - lum * 2.0).clamp(0.0, 1.0) * look.shadowBlueTint;
      out[i * 3 + 1] = out[i * 3 + 1] + wgt * 0.05;
      out[i * 3 + 2] = out[i * 3 + 2] + wgt * 0.10;
    }
  }

  // 7. 对比度 = 显影 γ / 显示 EOTF 的 γ 改变 —— CO-8
  //
  // 物理上"对比度"只能等价于传递曲线的 γ（Hurter–Driffield 的 γ 段 / 显示
  // EOTF）。旧实现用 smoothstep 在 sRGB 感知域外推（k=2 等价 2·curve−s）：
  // 既不是任何传递曲线，又会在两端双向截断（亮部死白平台 + 暗部压到负值），
  // 画面出现硬切的油画感。这里用单调幂律：f(0)=0、f(1)=1、单调、不溢出。
  if ((look.contrast - 1.0).abs() > 1e-3) {
    final k = look.contrast;
    for (var i = 0; i < n * 3; i++) {
      out[i] = math.pow(clampd(out[i]), k).toDouble();
    }
  }

  // 8. 饱和度（保持亮度的色度缩放）—— CO-9
  //
  // 亮度轴必须是**亮度权重** Y = 0.2126R + 0.7152G + 0.0722B（Rec.709 /
  // IEC 61966-2-1 的原始基色权重），不是三通道算术平均：用算术平均当轴会
  // 把"绿最亮"的视觉权重抹平，改变饱和度会同时改变感知亮度，并在纯色上
  // 产生负通道（例如纯绿 (0,1,0) 在 s=1.5 时得到 (−0.166,1.166,−0.166)）。
  if ((look.saturation - 1.0).abs() > 1e-4) {
    for (var i = 0; i < n; i++) {
      final j = i * 3;
      final y = 0.2126 * out[j] + 0.7152 * out[j + 1] + 0.0722 * out[j + 2];
      out[j] = y + (out[j] - y) * look.saturation;
      out[j + 1] = y + (out[j + 1] - y) * look.saturation;
      out[j + 2] = y + (out[j + 2] - y) * look.saturation;
    }
  }

  // 9. 镜头 bloom（乙类①，默认 0.15 启用）—— 在 ACES 之前的线性域做：
  //    对超过 1.0 的亮度提取两层高斯模糊（8/32 px）按 bloomStrength 叠回。
  //    物理对应镜头内镜面散射（veiling glare）与人眼晶状体散射——真实
  //    照片里强光源周围必有柔光晕，没有"边缘刀切的白斑"。在线性域施加
  //    保证能量守恒（不是显示域的提亮）。
  if (look.bloomStrength > 0) {
    final bright = Float32List(n);
    for (var i = 0; i < n; i++) {
      final j = i * 3;
      final lum = 0.2126 * out[j] + 0.7152 * out[j + 1] + 0.0722 * out[j + 2];
      final b = lum > 1.0 ? lum - 1.0 : 0.0;
      bright[i] = b;
    }
    final b1 = blurGray(bright, width, height, 8.0);
    final b2 = blurGray(bright, width, height, 32.0);
    final k = look.bloomStrength;
    for (var i = 0; i < n; i++) {
      final j = i * 3;
      final add = (b1[i] * 0.6 + b2[i] * 0.4) * k;
      out[j] += add;
      out[j + 1] += add;
      out[j + 2] += add;
    }
  }

  // 10. （镜头渐晕已上移到线性域，见第 4.5 步 —— CO-2 / CO-10）

  // 10. "CMOS 响应曲线"（无物理依据，默认关闭）—— CO-4
  if (look.sensorCurveStrength > 0) {
    for (var i = 0; i < n * 3; i++) {
      final v = out[i].clamp(0.0, 1.0);
      out[i] = out[i] * (1.0 + look.sensorCurveStrength * (1.0 - v));
    }
  }

  // 11. 限幅：色调映射已保证 f(∞)=1，这里的 clamp 只为兜住上面几个显示域
  //     旋钮（饱和度可产生负通道）。物理链本身不再需要它 —— CO-7 / CO-11。
  for (var i = 0; i < n * 3; i++) {
    out[i] = out[i].clamp(0.0, 1.0);
  }
  return out;
}

/// 一次弹射（室内互反射）的屏空间实现 —— CO-6。
///
/// 物理形式：`L_ind(x) = (ρ/π)·E_ind(x)`，E_ind 是在 x 处看到的所有**被照亮的
/// 墙面**的辐亮度按几何（形式因子）加权后的积分。本项负责**直射光斑**在室内
/// 的第一次弹射 —— 光斑辐亮度通常比环境照明区高 1~2 个数量级，因此它在室内
/// 的间接光里占支配地位；天光/房间的**平均**互反射底由
/// `atmosphere.illuminationField` 的互反射项（`interreflectionFloor`）负责，
/// 两者按光源分离，不是同一个物理量的两次相加。
///
/// 与旧实现的差异（旧值 0.12 + (1.00,0.92,0.80) + 3%/8% 两个写死半径）：
///   · 驱动量是**线性辐射本身**（光斑辐照度场），不含任何"强度"常数，因此它
///     与曝光成线性关系、不会随曝光漂移（旧实现 ∝ 曝光²，见 PI-9 的耦合）；
///   · 唯一的常数 1/π 来自朗伯 BRDF 的归一化 ρ/π，不是调色参数；
///   · **无色偏**：反射光的颜色应由反射面的光谱反射率决定，该信息在本模块
///     不可得（材质图只给结构、不给绝对反射率谱），按中性灰处理才是不引入
///     伪影的选择；固定暖色等于把伪影说成物理；
///   · 核尺度由**光斑自身的尺度**给出（掩膜的二阶矩 / RMS 半径）：室内互反射
///     的自由程与产生它的光斑尺度同量级。旧实现的两个半径（短边 3% / 8%）
///     既无依据、又与分辨率耦合；
///   · 用"环带"（两个归一化模糊之差）近似"除自身以外"的邻域：一个面元不能
///     照亮它自己，纯模糊会把自身辐亮度算进入射里，在大片光斑内部高估反弹。
void _addFirstBounce(
    Float32List out, Float32List patchMask, int w, int h, double scale) {
  final n = w * h;
  final src = Float32List(n);
  var wSum = 0.0;
  var cx = 0.0;
  var cy = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final m = patchMask[i].clamp(0.0, 1.0);
      src[i] =
          m * (out[i * 3] + out[i * 3 + 1] + out[i * 3 + 2]) / 3.0;
      if (m > 0) {
        wSum += m;
        cx += m * x;
        cy += m * y;
      }
    }
  }
  if (wSum <= 1e-9) return; // 没有任何光斑 ⇒ 没有一次弹射
  cx /= wSum;
  cy /= wSum;

  // 光斑的 RMS 半径（掩膜的加权二阶矩）
  var r2 = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final m = patchMask[i].clamp(0.0, 1.0);
      if (m <= 0) continue;
      final dx = x - cx, dy = y - cy;
      r2 += m * (dx * dx + dy * dy);
    }
  }
  // 1 px 是离散化下限（不是物理量）
  final radius = math.max(math.sqrt(r2 / wSum), 1.0);

  final inner = blurGray(src, w, h, radius);
  final outer = blurGray(src, w, h, radius * 2.0);
  final k = scale / math.pi;
  // ── 二阶弹射（甲类⑦，默认启用）──
  // 一阶 = 光斑 → 墙（暖晕）。二阶 = "光斑→墙"的漫反射场再从整面墙反弹
  // 一次：能量按 ρ/π 再衰减（ρ 取墙平均反照率的代表值），模糊半径加倍
  // （再走一跳，空间频率再降一个倍频程）。量级 ~ 一阶 × ρ ≈ 0.2，
  // 对直射暗部（影子最深处）贡献一个可感的底亮，消除"影子里绝对死黑"。
  final outer2 = blurGray(outer, w, h, radius * 4.0);
  final k2 = k * 0.2; // ρ_wall/π ≈ 0.75/π 的一阶已含 1/π，二阶再乘 ρ
  for (var i = 0; i < n; i++) {
    final v = math.max(outer[i] - inner[i], 0.0) * k +
        math.max(outer2[i] - outer[i], 0.0) * k2;
    if (v <= 0) continue;
    out[i * 3] += v;
    out[i * 3 + 1] += v;
    out[i * 3 + 2] += v;
  }
}

// ─────────────────────────────── 编码 / 解码 ───────────────────────────────

/// 线性 RGB → sRGB 字节流（RGB，长度 w*h*3）。
///
/// 传递函数用 IEC 61966-2-1 的分段定义（见 [linearToSrgb]），并在量化前加
/// 两层噪声（均为确定性哈希，不破坏可复现性）：
///
/// 1. **TPDF 抖动**（±1 LSB 三角分布）—— CO-11：8bit 量化在暗部/渐变上
///    产生肉眼可见的阶梯色带（本工程实测夜景 26.7% 像素纯 0、暮光 98%
///    挤在 0~31 区间，正是色带高发区）。
/// 2. **散粒噪声**（甲类⑧，默认启用）—— 光子到达的泊松涨落，σ=√N。
///    真实相机（与人眼锥细胞）在低照度下都有可感的颗粒：夜景 σ_photon
///    按**线性信号平方根**给出，暗部相对涨落大（1/√N 大）、亮部趋于
///    平滑——这正是夜景照片"颗粒感"的物理来源。强度由 [shotGain] 控制
///    （1.0 = 全幅传感器在 100 ISO 的典型值；暗部像素 σ≈4 LSB）。
///    实现：Box-Muller 把两个均匀哈希变成高斯，乘 √signal。
Uint8List encodeSrgbBytes(Float32List linear, {double shotGain = 1.0}) {
  final out = Uint8List(linear.length);
  const lsb = 1.0 / 255.0;
  for (var i = 0; i < linear.length; i++) {
    final v = linear[i];
    final s = linearToSrgb(v);
    // 散粒：线性域 σ ∝ √signal（再经 sRGB 提亮暗部 → 颗粒均匀可见）。
    // 只在信号明显大于量化底时施加（极暗部由 TPDF 主导，避免双重颗粒）。
    var shot = 0.0;
    if (shotGain > 0 && v > 1e-5) {
      final u1 = hashNoise(i, 2, 0x2545f491);
      final u2 = hashNoise(i, 3, 0x2545f491);
      // Box-Muller（u1 避 0）
      final r = math.sqrt(-2.0 * math.log(math.max(u1, 1e-12)));
      shot = r * math.cos(2 * math.pi * u2) *
          shotGain * 0.004 * math.sqrt(v); // 0.004: 满幅≈10000 lux 下 σ~8 LSB
    }
    final u1 = hashNoise(i, 0, 0x5f3759df);
    final u2 = hashNoise(i, 1, 0x5f3759df);
    final d = (u1 + u2 - 1.0) * lsb; // TPDF，[-1,+1] LSB，无直流偏置
    out[i] = ((s + shot + d) * 255.0 + 0.5).clamp(0, 255).toInt();
  }
  return out;
}

/// sRGB 字节 → 线性浮点。
Float32List decodeSrgbToLinear(Uint8List bytes) {
  final out = Float32List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    out[i] = srgbToLinear(bytes[i] / 255.0);
  }
  return out;
}
