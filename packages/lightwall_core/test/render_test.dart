// 编解码与渲染管线测试
import 'dart:typed_data';

import 'package:lightwall_core/lightwall_core.dart';
import 'package:test/test.dart';

Float32List flatRgb(int w, int h, double r, double g, double b) {
  final out = Float32List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    out[i * 3] = r;
    out[i * 3 + 1] = g;
    out[i * 3 + 2] = b;
  }
  return out;
}

Uint8List syntheticWall(int w, int h) {
  // 一张带轻微纹理的"平光墙"
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final n = valueNoise(x / 13.0, y / 13.0, 7);
      final v = (150 + 28 * n).round().clamp(0, 255);
      final i = (y * w + x) * 3;
      out[i] = v;
      out[i + 1] = (v * 0.98).round();
      out[i + 2] = (v * 0.94).round();
    }
  }
  return out;
}

void main() {
  group('PNG 编解码', () {
    test('往返一致', () {
      const w = 37, h = 19;
      final src = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        src[i * 3] = (i * 7) % 256;
        src[i * 3 + 1] = (i * 13) % 256;
        src[i * 3 + 2] = (i * 29) % 256;
      }
      final png = encodePng(src, w, h);
      expect(png.sublist(0, 4), <int>[0x89, 0x50, 0x4e, 0x47]);
      final back = decodePng(png);
      expect(back.width, w);
      expect(back.height, h);
      expect(back.rgb, src);
    });

    test('非 PNG 输入抛异常', () {
      expect(() => decodePng(Uint8List.fromList(<int>[1, 2, 3, 4])),
          throwsA(isA<FormatException>()));
    });
  });

  group('BMP 编码', () {
    test('文件头合法且尺寸正确', () {
      const w = 20, h = 10;
      final bmp = encodeBmp(Uint8List(w * h * 3), w, h);
      expect(bmp[0], 0x42); // 'B'
      expect(bmp[1], 0x4d); // 'M'
      final bd = ByteData.sublistView(bmp);
      expect(bd.getUint32(2, Endian.little), bmp.length);
      expect(bd.getInt32(18, Endian.little), w);
      expect(bd.getInt32(22, Endian.little), h);
      expect(bd.getUint16(28, Endian.little), 24);
      // 行按 4 字节对齐：20*3 = 60 → 60 已是 4 的倍数
      expect(bmp.length, 54 + 60 * 10);
    });
  });

  group('渲染管线', () {
    test('小尺寸渲染可跑通且不是全黑', () {
      const w = 160, h = 90;
      final result = render(
        baseRgb: syntheticWall(w, h),
        width: w,
        height: h,
        spec: RenderSpec(
          time: DateTime.parse('2025-12-21T08:30:00+08:00'),
          lat: 39.9042,
          lon: 116.4074,
          windowAz: 90,
        ),
      );
      expect(result.width, w);
      expect(result.height, h);
      expect(result.rgb.length, w * h * 3);
      var sum = 0;
      for (final v in result.rgb) {
        sum += v;
      }
      final mean = sum / result.rgb.length;
      expect(mean, greaterThan(20)); // 不是全黑
      expect(mean, lessThan(240)); // 也不是全白
      expect(result.light.source, LightSource.sun);
      expect(result.light.sunAlt, greaterThan(0));
    });

    test('低太阳角时确实出现直射光斑（可见比例 > 0）', () {
      const w = 240, h = 135;
      final result = render(
        baseRgb: syntheticWall(w, h),
        width: w,
        height: h,
        spec: RenderSpec(
          time: DateTime.parse('2025-12-21T08:30:00+08:00'),
          lat: 39.9042,
          lon: 116.4074,
          windowAz: 90,
        ),
      );
      expect(result.albedoStats['visible_ratio'], greaterThan(0.02));
    });

    test('高太阳角时墙上没有直射光斑（物理正确）', () {
      const w = 160, h = 90;
      final result = render(
        baseRgb: syntheticWall(w, h),
        width: w,
        height: h,
        spec: RenderSpec(
          time: DateTime.parse('2025-06-21T12:00:00+08:00'),
          lat: 39.9042,
          lon: 116.4074,
          windowAz: 90,
        ),
      );
      expect(result.albedoStats['visible_ratio'], lessThan(0.005));
    });

    test('同样参数渲染结果一致（确定性）', () {
      const w = 96, h = 54;
      final base = syntheticWall(w, h);
      List<int> run() => render(
            baseRgb: base,
            width: w,
            height: h,
            spec: RenderSpec(
              time: DateTime.parse('2025-12-21T09:00:00+08:00'),
              lat: 39.9042,
              lon: 116.4074,
              windowAz: 90,
              seed: 42,
            ),
          ).rgb;
      expect(run(), run());
    });

    test('夜间渲染偏暗但仍可辨识', () {
      const w = 96, h = 54;
      final result = render(
        baseRgb: syntheticWall(w, h),
        width: w,
        height: h,
        spec: RenderSpec(
          time: DateTime.parse('2025-12-21T23:30:00+08:00'),
          lat: 39.9042,
          lon: 116.4074,
          windowAz: 90,
        ),
      );
      var sum = 0;
      for (final v in result.rgb) {
        sum += v;
      }
      expect(sum / result.rgb.length, lessThan(90));
    });
  });

  group('叠字', () {
    test('乘性反射：字在暗处变暗、在光斑处变亮', () {
      const w = 8, h = 2;
      final base = Uint8List(w * h * 3)..fillRange(0, w * h * 3, 200);
      // 左半暗、右半亮
      for (var i = 0; i < w * h ~/ 2 * 3; i++) {
        base[i] = 40;
      }
      final alpha = Float32List(w * h);
      alpha.fillRange(0, w * h, 1.0);
      final out = fuseText(
        baseSrgb: base,
        width: w,
        height: h,
        alpha: alpha,
        occlusion: Float32List(w * h),
      );
      final leftR = out[0];
      final rightR = out[(w * h - 1) * 3];
      expect(rightR, greaterThan(leftR)); // 亮处字更亮 → 是颜料不是贴纸
      expect(out[1], lessThan(out[3])); // 朱红：G 通道被压得很低
    });

    test('年代感参数越强，alpha 越低（更斑驳）', () {
      const w = 64, h = 64;
      final alpha = Float32List(w * h);
      alpha.fillRange(0, w * h, 1.0);
      double mean(Float32List a) {
        var s = 0.0;
        for (final v in a) {
          s += v;
        }
        return s / a.length;
      }

      final clean = generateAgedAlpha(alpha, w, h,
          params: AgedParams.clean, seed: 7);
      final aged = generateAgedAlpha(alpha, w, h,
          params: AgedParams.aged, seed: 7);
      expect(mean(aged), lessThan(mean(clean)));
    });
  });
}
