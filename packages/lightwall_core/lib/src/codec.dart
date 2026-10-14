// 图像编解码：PNG（自实现，含 zlib 压缩）与 BMP
//
// 为什么自己写：核心包必须是纯 Dart（不依赖 Flutter 的 dart:ui，
// 也不引入第三方图像库），这样才能在命令行与单元测试里独立跑通。
// zlib 直接用 dart:io 的 ZLibCodec（Deflate/Inflate 均为原生实现）。
import 'dart:io';
import 'dart:typed_data';

// ───────────────────────────── CRC32 ─────────────────────────────

final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}

int crc32(Uint8List data, [int start = 0, int? end]) {
  var c = 0xffffffff;
  final e = end ?? data.length;
  for (var i = start; i < e; i++) {
    c = _crcTable[(c ^ data[i]) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

// ───────────────────────────── PNG 编码 ─────────────────────────────

/// 编码 8 位 RGB PNG。[rgb] 长度必须为 w*h*3。
Uint8List encodePng(Uint8List rgb, int width, int height) {
  final raw = Uint8List(height * (1 + width * 3));
  var p = 0;
  for (var y = 0; y < height; y++) {
    raw[p++] = 0; // filter: none
    final rowStart = y * width * 3;
    raw.setRange(p, p + width * 3, rgb, rowStart);
    p += width * 3;
  }
  final idat = Uint8List.fromList(ZLibCodec(level: 6).encode(raw));

  final out = BytesBuilder();
  out.add(const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  void chunk(String type, Uint8List data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    final typeBytes = Uint8List.fromList(type.codeUnits);
    out.add(typeBytes);
    out.add(data);
    final crcData = Uint8List(typeBytes.length + data.length)
      ..setRange(0, typeBytes.length, typeBytes)
      ..setRange(typeBytes.length, typeBytes.length + data.length, data);
    final crc = ByteData(4)..setUint32(0, crc32(crcData));
    out.add(crc.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // color type: truecolor
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', idat);
  chunk('IEND', Uint8List(0));
  return out.toBytes();
}

// ───────────────────────────── PNG 解码 ─────────────────────────────

/// 解码 PNG → RGB 字节（w*h*3）。
///
/// 支持位深 8/16、颜色类型 0/2/3/4/6（调色板、灰度、灰度+alpha、
/// RGB、RGBA），足以覆盖大多数材质底图。
({Uint8List rgb, int width, int height}) decodePng(Uint8List bytes) {
  if (bytes.length < 8 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4e ||
      bytes[3] != 0x47) {
    throw const FormatException('不是合法的 PNG 文件');
  }
  var pos = 8;
  int width = 0, height = 0, bitDepth = 8, colorType = 6;
  Uint8List? palette;
  final idat = BytesBuilder();

  while (pos + 8 <= bytes.length) {
    final len = ByteData.sublistView(bytes, pos, pos + 4).getUint32(0);
    final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
    final dataStart = pos + 8;
    final dataEnd = dataStart + len;
    if (dataEnd > bytes.length) break;
    switch (type) {
      case 'IHDR':
        width =
            ByteData.sublistView(bytes, dataStart, dataStart + 4).getUint32(0);
        height = ByteData.sublistView(bytes, dataStart + 4, dataStart + 8)
            .getUint32(0);
        bitDepth = bytes[dataStart + 8];
        colorType = bytes[dataStart + 9];
        break;
      case 'PLTE':
        palette = Uint8List.fromList(bytes.sublist(dataStart, dataEnd));
        break;
      case 'tRNS':
        break;
      case 'IDAT':
        idat.add(bytes.sublist(dataStart, dataEnd));
        break;
      case 'IEND':
        pos = bytes.length;
        continue;
    }
    pos = dataEnd + 4; // 跳过 CRC
    if (type == 'IEND') break;
  }

  final raw = Uint8List.fromList(ZLibCodec().decode(idat.toBytes()));
  if (width <= 0 || height <= 0) {
    throw const FormatException('PNG 缺少 IHDR');
  }

  // 每像素字节数（按位深 8/16）
  int channels;
  switch (colorType) {
    case 0:
      channels = 1;
      break;
    case 2:
      channels = 3;
      break;
    case 3:
      channels = 1;
      break;
    case 4:
      channels = 2;
      break;
    default:
      channels = 4;
  }
  final bytesPerSample = bitDepth == 16 ? 2 : 1;
  final bpp = channels * bytesPerSample;
  final stride = width * bpp;

  // 反滤波
  final img = Uint8List(height * stride);
  var rp = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[rp++];
    final rowStart = y * stride;
    final prevStart = rowStart - stride;
    for (var i = 0; i < stride; i++) {
      final rawByte = rp + i < raw.length ? raw[rp + i] : 0;
      final a = i >= bpp ? img[rowStart + i - bpp] : 0;
      final b = y > 0 ? img[prevStart + i] : 0;
      final c = (i >= bpp && y > 0) ? img[prevStart + i - bpp] : 0;
      int v;
      switch (filter) {
        case 0:
          v = rawByte;
          break;
        case 1:
          v = rawByte + a;
          break;
        case 2:
          v = rawByte + b;
          break;
        case 3:
          v = rawByte + ((a + b) >> 1);
          break;
        case 4:
          final p = a + b - c;
          final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
          final pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          v = rawByte + pred;
          break;
        default:
          v = rawByte;
      }
      img[rowStart + i] = v & 0xff;
    }
    rp += stride;
  }

  // 转 RGB
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final si = y * stride + x * bpp;
      final di = (y * width + x) * 3;
      switch (colorType) {
        case 0:
        case 4:
          final g = bitDepth == 16 ? img[si] : img[si];
          rgb[di] = g;
          rgb[di + 1] = g;
          rgb[di + 2] = g;
          break;
        case 2:
        case 6:
          rgb[di] = img[si];
          rgb[di + 1] = img[si + bytesPerSample];
          rgb[di + 2] = img[si + 2 * bytesPerSample];
          break;
        case 3:
          final idx = img[si] * 3;
          if (palette != null && idx + 2 < palette.length) {
            rgb[di] = palette[idx];
            rgb[di + 1] = palette[idx + 1];
            rgb[di + 2] = palette[idx + 2];
          }
          break;
      }
    }
  }
  return (rgb: rgb, width: width, height: height);
}

// ───────────────────────────── BMP 编码 ─────────────────────────────

/// 编码 24 位 BMP（自下而上、BGR、行按 4 字节对齐）。
///
/// Windows 的 SystemParametersInfo 对 BMP/JPEG 支持最稳，
/// 因此设置壁纸时用 BMP，存档用 PNG。
Uint8List encodeBmp(Uint8List rgb, int width, int height) {
  final rowSize = ((width * 3 + 3) ~/ 4) * 4;
  final pixelDataSize = rowSize * height;
  final fileSize = 54 + pixelDataSize;
  final out = Uint8List(fileSize);
  final bd = ByteData.sublistView(out);

  out[0] = 0x42; // 'B'
  out[1] = 0x4d; // 'M'
  bd.setUint32(2, fileSize, Endian.little);
  bd.setUint32(10, 54, Endian.little); // 像素数据偏移
  bd.setUint32(14, 40, Endian.little); // BITMAPINFOHEADER
  bd.setInt32(18, width, Endian.little);
  bd.setInt32(22, height, Endian.little);
  bd.setUint16(26, 1, Endian.little); // planes
  bd.setUint16(28, 24, Endian.little); // bpp
  bd.setUint32(30, 0, Endian.little); // BI_RGB
  bd.setUint32(34, pixelDataSize, Endian.little);
  bd.setInt32(38, 2835, Endian.little); // 72 DPI
  bd.setInt32(42, 2835, Endian.little);

  for (var y = 0; y < height; y++) {
    final srcRow = (height - 1 - y) * width * 3;
    final dstRow = 54 + y * rowSize;
    for (var x = 0; x < width; x++) {
      final s = srcRow + x * 3;
      final d = dstRow + x * 3;
      out[d] = rgb[s + 2]; // B
      out[d + 1] = rgb[s + 1]; // G
      out[d + 2] = rgb[s]; // R
    }
  }
  return out;
}

/// 读取图片文件 → RGB 字节。PNG 走内置解码；其它格式抛异常。
({Uint8List rgb, int width, int height}) loadImageFile(String path) {
  final bytes = File(path).readAsBytesSync();
  return decodePng(bytes);
}
