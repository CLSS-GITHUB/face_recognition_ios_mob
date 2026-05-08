import 'dart:typed_data';

import '../constants/thresholds.dart';

/// Byte-compatible port of Android's `Converters.kt`.
///
/// Layout (little-endian):
///   [int32 listSize]
///   for each FloatArray:
///     [int32 arraySize]
///     [float32 × arraySize]
///
/// On corruption, decoding returns whatever was successfully parsed up to the
/// first invalid record (matching the Kotlin "break on bad row" behavior).
class FaceTemplatesCodec {
  FaceTemplatesCodec._();

  static Uint8List encode(List<Float32List> templates) {
    var size = 4;
    for (final t in templates) {
      size += 4 + t.lengthInBytes;
    }
    final out = ByteData(size);
    var off = 0;
    out.setInt32(off, templates.length, Endian.little);
    off += 4;
    for (final t in templates) {
      out.setInt32(off, t.length, Endian.little);
      off += 4;
      for (var i = 0; i < t.length; i++, off += 4) {
        out.setFloat32(off, t[i], Endian.little);
      }
    }
    return out.buffer.asUint8List();
  }

  static List<Float32List> decode(Uint8List blob) {
    if (blob.length < 4) return const [];
    final data = ByteData.sublistView(blob);
    var off = 0;
    final n = data.getInt32(off, Endian.little);
    off += 4;
    if (n < 0 || n > FaceThresholds.maxTemplatesPerUser) return const [];
    final out = <Float32List>[];
    for (var i = 0; i < n; i++) {
      if (blob.length - off < 4) break;
      final m = data.getInt32(off, Endian.little);
      off += 4;
      if (m < 0 ||
          m > FaceThresholds.maxArrayLength ||
          blob.length - off < m * 4) {
        break;
      }
      final arr = Float32List(m);
      for (var j = 0; j < m; j++, off += 4) {
        arr[j] = data.getFloat32(off, Endian.little);
      }
      out.add(arr);
    }
    return out;
  }
}
