import 'dart:typed_data';

/// Baseline (sequential, Huffman) JPEG encoder, YCbCr 4:4:4, JFIF.
///
/// Used to re-encode every clinical photo on the device so only JPEG ever
/// reaches the attachment flow, without adding a package. Input is RGBA
/// with premultiplied alpha (what `ui.ImageByteFormat.rawRgba` returns);
/// transparent areas are flattened onto white.
class JpegEncoder {
  JpegEncoder({int quality = 85}) : quality = quality.clamp(1, 100) {
    _initQuantTables();
  }

  final int quality;

  final Uint8List _yTable = Uint8List(64);
  final Uint8List _uvTable = Uint8List(64);
  final Float64List _fdtblY = Float64List(64);
  final Float64List _fdtblUV = Float64List(64);

  static const List<int> _zigZag = [
    0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, //
    3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
    10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
    21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63,
  ];

  static const List<int> _stdYQt = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, //
    14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
  ];

  static const List<int> _stdUvQt = [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, //
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  ];

  // Standard Huffman tables (ITU T.81 Annex K.3). Index 0 is unused so
  // index k holds the number of codes of length k.
  static const List<int> _dcLumCounts = [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
  static const List<int> _dcLumValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  static const List<int> _acLumCounts = [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
  static const List<int> _acLumValues = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, //
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ];
  static const List<int> _dcChrCounts = [0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
  static const List<int> _dcChrValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  static const List<int> _acChrCounts = [0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
  static const List<int> _acChrValues = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, //
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ];

  static final List<_Code> _ydcHt = _buildHuffman(_dcLumCounts, _dcLumValues);
  static final List<_Code> _yacHt = _buildHuffman(_acLumCounts, _acLumValues);
  static final List<_Code> _uvdcHt = _buildHuffman(_dcChrCounts, _dcChrValues);
  static final List<_Code> _uvacHt = _buildHuffman(_acChrCounts, _acChrValues);

  static List<_Code> _buildHuffman(List<int> counts, List<int> values) {
    final table = List<_Code>.filled(256, const _Code(0, 0));
    var code = 0;
    var pos = 0;
    for (var len = 1; len <= 16; len++) {
      for (var j = 0; j < counts[len]; j++) {
        table[values[pos++]] = _Code(code, len);
        code++;
      }
      code <<= 1;
    }
    return table;
  }

  void _initQuantTables() {
    final q = quality;
    final scale = q < 50 ? (5000 / q).floor() : 200 - q * 2;
    for (var i = 0; i < 64; i++) {
      _yTable[_zigZag[i]] = ((_stdYQt[i] * scale + 50) ~/ 100).clamp(1, 255);
      _uvTable[_zigZag[i]] = ((_stdUvQt[i] * scale + 50) ~/ 100).clamp(1, 255);
    }
    const aasf = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379];
    var k = 0;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        _fdtblY[k] = 1.0 / (_yTable[_zigZag[k]] * aasf[row] * aasf[col] * 8.0);
        _fdtblUV[k] = 1.0 / (_uvTable[_zigZag[k]] * aasf[row] * aasf[col] * 8.0);
        k++;
      }
    }
  }

  // ---- bit writer -------------------------------------------------------
  late BytesBuilder _out;
  int _byteNew = 0;
  int _bytePos = 7;

  void _writeByte(int b) => _out.addByte(b & 0xFF);
  void _writeWord(int w) {
    _writeByte(w >> 8);
    _writeByte(w);
  }

  void _writeBits(int value, int length) {
    var posVal = length - 1;
    while (posVal >= 0) {
      if ((value & (1 << posVal)) != 0) _byteNew |= 1 << _bytePos;
      posVal--;
      _bytePos--;
      if (_bytePos < 0) {
        if (_byteNew == 0xFF) {
          _writeByte(0xFF);
          _writeByte(0x00);
        } else {
          _writeByte(_byteNew);
        }
        _bytePos = 7;
        _byteNew = 0;
      }
    }
  }

  void _writeCode(_Code c) => _writeBits(c.code, c.length);

  static int _category(int v) {
    var a = v < 0 ? -v : v;
    var n = 0;
    while (a > 0) {
      n++;
      a >>= 1;
    }
    return n;
  }

  static int _bitsFor(int v, int cat) => v >= 0 ? v : v + (1 << cat) - 1;

  // ---- DCT + entropy coding -------------------------------------------
  final Int32List _quant = Int32List(64);

  void _fdctQuant(Float64List data, Float64List fdtbl) {
    for (var off = 0; off < 64; off += 8) {
      final d0 = data[off], d1 = data[off + 1], d2 = data[off + 2], d3 = data[off + 3];
      final d4 = data[off + 4], d5 = data[off + 5], d6 = data[off + 6], d7 = data[off + 7];
      final t0 = d0 + d7, t7 = d0 - d7, t1 = d1 + d6, t6 = d1 - d6;
      final t2 = d2 + d5, t5 = d2 - d5, t3 = d3 + d4, t4 = d3 - d4;
      var t10 = t0 + t3;
      final t13 = t0 - t3;
      var t11 = t1 + t2;
      var t12 = t1 - t2;
      data[off] = t10 + t11;
      data[off + 4] = t10 - t11;
      final z1 = (t12 + t13) * 0.707106781;
      data[off + 2] = t13 + z1;
      data[off + 6] = t13 - z1;
      t10 = t4 + t5;
      t11 = t5 + t6;
      t12 = t6 + t7;
      final z5 = (t10 - t12) * 0.382683433;
      final z2 = 0.541196100 * t10 + z5;
      final z4 = 1.306562965 * t12 + z5;
      final z3 = t11 * 0.707106781;
      final z11 = t7 + z3;
      final z13 = t7 - z3;
      data[off + 5] = z13 + z2;
      data[off + 3] = z13 - z2;
      data[off + 1] = z11 + z4;
      data[off + 7] = z11 - z4;
    }
    for (var c = 0; c < 8; c++) {
      final d0 = data[c], d1 = data[c + 8], d2 = data[c + 16], d3 = data[c + 24];
      final d4 = data[c + 32], d5 = data[c + 40], d6 = data[c + 48], d7 = data[c + 56];
      final t0 = d0 + d7, t7 = d0 - d7, t1 = d1 + d6, t6 = d1 - d6;
      final t2 = d2 + d5, t5 = d2 - d5, t3 = d3 + d4, t4 = d3 - d4;
      var t10 = t0 + t3;
      final t13 = t0 - t3;
      var t11 = t1 + t2;
      var t12 = t1 - t2;
      data[c] = t10 + t11;
      data[c + 32] = t10 - t11;
      final z1 = (t12 + t13) * 0.707106781;
      data[c + 16] = t13 + z1;
      data[c + 48] = t13 - z1;
      t10 = t4 + t5;
      t11 = t5 + t6;
      t12 = t6 + t7;
      final z5 = (t10 - t12) * 0.382683433;
      final z2 = 0.541196100 * t10 + z5;
      final z4 = 1.306562965 * t12 + z5;
      final z3 = t11 * 0.707106781;
      final z11 = t7 + z3;
      final z13 = t7 - z3;
      data[c + 40] = z13 + z2;
      data[c + 24] = z13 - z2;
      data[c + 8] = z11 + z4;
      data[c + 56] = z11 - z4;
    }
    for (var i = 0; i < 64; i++) {
      final v = data[i] * fdtbl[i];
      _quant[_zigZag[i]] = v > 0 ? (v + 0.5).floor() : (v - 0.5).ceil();
    }
  }

  int _processDu(Float64List data, Float64List fdtbl, int dc, List<_Code> htdc, List<_Code> htac) {
    _fdctQuant(data, fdtbl);
    final du = _quant;
    final diff = du[0] - dc;
    if (diff == 0) {
      _writeCode(htdc[0]);
    } else {
      final cat = _category(diff);
      _writeCode(htdc[cat]);
      _writeBits(_bitsFor(diff, cat), cat);
    }
    var end0 = 63;
    while (end0 > 0 && du[end0] == 0) {
      end0--;
    }
    if (end0 == 0) {
      _writeCode(htac[0x00]);
      return du[0];
    }
    var i = 1;
    while (i <= end0) {
      final start = i;
      while (du[i] == 0 && i <= end0) {
        i++;
      }
      var zeros = i - start;
      if (zeros >= 16) {
        for (var n = 0; n < zeros >> 4; n++) {
          _writeCode(htac[0xF0]);
        }
        zeros &= 0xF;
      }
      final cat = _category(du[i]);
      _writeCode(htac[(zeros << 4) + cat]);
      _writeBits(_bitsFor(du[i], cat), cat);
      i++;
    }
    if (end0 != 63) _writeCode(htac[0x00]);
    return du[0];
  }

  // ---- headers ----------------------------------------------------------
  void _writeHeaders(int width, int height) {
    _writeWord(0xFFD8); // SOI
    _writeWord(0xFFE0); // APP0 JFIF
    _writeWord(16);
    for (final c in 'JFIF'.codeUnits) {
      _writeByte(c);
    }
    _writeByte(0);
    _writeByte(1);
    _writeByte(1);
    _writeByte(0);
    _writeWord(1);
    _writeWord(1);
    _writeByte(0);
    _writeByte(0);

    _writeWord(0xFFDB); // DQT
    _writeWord(132);
    _writeByte(0);
    for (var i = 0; i < 64; i++) {
      _writeByte(_yTable[i]);
    }
    _writeByte(1);
    for (var i = 0; i < 64; i++) {
      _writeByte(_uvTable[i]);
    }

    _writeWord(0xFFC0); // SOF0
    _writeWord(17);
    _writeByte(8);
    _writeWord(height);
    _writeWord(width);
    _writeByte(3);
    _writeByte(1);
    _writeByte(0x11);
    _writeByte(0);
    _writeByte(2);
    _writeByte(0x11);
    _writeByte(1);
    _writeByte(3);
    _writeByte(0x11);
    _writeByte(1);

    _writeWord(0xFFC4); // DHT
    _writeWord(0x01A2);
    void table(int classId, List<int> counts, List<int> values) {
      _writeByte(classId);
      for (var k = 1; k <= 16; k++) {
        _writeByte(counts[k]);
      }
      for (final v in values) {
        _writeByte(v);
      }
    }

    table(0x00, _dcLumCounts, _dcLumValues);
    table(0x10, _acLumCounts, _acLumValues);
    table(0x01, _dcChrCounts, _dcChrValues);
    table(0x11, _acChrCounts, _acChrValues);

    _writeWord(0xFFDA); // SOS
    _writeWord(12);
    _writeByte(3);
    _writeByte(1);
    _writeByte(0x00);
    _writeByte(2);
    _writeByte(0x11);
    _writeByte(3);
    _writeByte(0x11);
    _writeByte(0);
    _writeByte(0x3f);
    _writeByte(0);
  }

  /// Encodes [rgba] (premultiplied, 4 bytes per pixel, row-major) to JPEG.
  Uint8List encode(Uint8List rgba, int width, int height) {
    if (width <= 0 || height <= 0 || width > 65535 || height > 65535) {
      throw ArgumentError('Invalid image size ${width}x$height');
    }
    if (rgba.length < width * height * 4) {
      throw ArgumentError('Pixel buffer is too small for ${width}x$height');
    }
    _out = BytesBuilder(copy: false);
    _byteNew = 0;
    _bytePos = 7;
    _writeHeaders(width, height);

    final ydu = Float64List(64), udu = Float64List(64), vdu = Float64List(64);
    var dcY = 0, dcU = 0, dcV = 0;
    for (var by = 0; by < height; by += 8) {
      for (var bx = 0; bx < width; bx += 8) {
        for (var p = 0; p < 64; p++) {
          final y = by + (p >> 3);
          final x = bx + (p & 7);
          final yy = y < height ? y : height - 1;
          final xx = x < width ? x : width - 1;
          final o = (yy * width + xx) * 4;
          final a = rgba[o + 3];
          // Premultiplied over white: c + (255 - a).
          final r = rgba[o] + 255 - a;
          final g = rgba[o + 1] + 255 - a;
          final b = rgba[o + 2] + 255 - a;
          ydu[p] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
          udu[p] = -0.16874 * r - 0.33126 * g + 0.5 * b;
          vdu[p] = 0.5 * r - 0.41869 * g - 0.08131 * b;
        }
        dcY = _processDu(ydu, _fdtblY, dcY, _ydcHt, _yacHt);
        dcU = _processDu(udu, _fdtblUV, dcU, _uvdcHt, _uvacHt);
        dcV = _processDu(vdu, _fdtblUV, dcV, _uvdcHt, _uvacHt);
      }
    }
    if (_bytePos < 7) _writeBits((1 << (_bytePos + 1)) - 1, _bytePos + 1);
    _writeWord(0xFFD9); // EOI
    return _out.takeBytes();
  }
}

class _Code {
  final int code;
  final int length;
  const _Code(this.code, this.length);
}
