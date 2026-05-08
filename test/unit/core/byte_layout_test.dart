import 'dart:typed_data';

import 'package:face_ios_android/core/utils/byte_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaceTemplatesCodec', () {
    test('round-trip empty list', () {
      final bytes = FaceTemplatesCodec.encode(const []);
      expect(bytes.length, 4);
      expect(FaceTemplatesCodec.decode(bytes), isEmpty);
    });

    test('round-trip single 192-D template', () {
      final t = Float32List.fromList(List.generate(192, (i) => i / 192));
      final bytes = FaceTemplatesCodec.encode([t]);
      // 4 (list size) + 4 (array size) + 192*4 (floats)
      expect(bytes.length, 4 + 4 + 192 * 4);
      final decoded = FaceTemplatesCodec.decode(bytes);
      expect(decoded, hasLength(1));
      expect(decoded.first, hasLength(192));
      for (var i = 0; i < 192; i++) {
        expect(decoded.first[i], closeTo(t[i], 1e-6));
      }
    });

    test('round-trip multiple templates of different sizes', () {
      final templates = [
        Float32List.fromList([1, 2, 3]),
        Float32List.fromList([0.5, -0.5]),
        Float32List(0),
      ];
      final decoded = FaceTemplatesCodec.decode(
        FaceTemplatesCodec.encode(templates),
      );
      expect(decoded, hasLength(3));
      expect(decoded[0], orderedEquals([1.0, 2.0, 3.0]));
      expect(decoded[1], orderedEquals([0.5, -0.5]));
      expect(decoded[2], isEmpty);
    });

    test('endianness is little-endian', () {
      final bytes = FaceTemplatesCodec.encode([
        Float32List.fromList([1.0]),
      ]);
      // listSize = 1 → 0x01,0x00,0x00,0x00
      expect(bytes.sublist(0, 4), orderedEquals([1, 0, 0, 0]));
      // arraySize = 1 → same
      expect(bytes.sublist(4, 8), orderedEquals([1, 0, 0, 0]));
      // 1.0f little-endian → 0x00 0x00 0x80 0x3F
      expect(bytes.sublist(8, 12), orderedEquals([0x00, 0x00, 0x80, 0x3F]));
    });

    test('decode rejects oversized list size', () {
      final blob = ByteData(4)..setInt32(0, 99999, Endian.little);
      expect(
        FaceTemplatesCodec.decode(blob.buffer.asUint8List()),
        isEmpty,
      );
    });

    test('decode stops at first malformed record (parity with Kotlin break)', () {
      // Encode 2 templates, then corrupt the second array size
      final ok = FaceTemplatesCodec.encode([
        Float32List.fromList([1, 2]),
        Float32List.fromList([3, 4]),
      ]);
      final bytes = Uint8List.fromList(ok);
      // bytes layout: [listSize=2][arr0Size=2][f0][f1][arr1Size=2][f2][f3]
      // overwrite arr1Size with a huge value
      ByteData.sublistView(bytes).setInt32(4 + 4 + 8, 999999, Endian.little);
      final decoded = FaceTemplatesCodec.decode(bytes);
      expect(decoded, hasLength(1));
      expect(decoded.first, orderedEquals([1.0, 2.0]));
    });

    test('decode of < 4 byte blob returns empty', () {
      expect(FaceTemplatesCodec.decode(Uint8List.fromList([1, 2])), isEmpty);
    });

    test('decode of negative list size returns empty', () {
      final blob = ByteData(4)..setInt32(0, -1, Endian.little);
      expect(FaceTemplatesCodec.decode(blob.buffer.asUint8List()), isEmpty);
    });
  });
}
