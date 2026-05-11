import 'dart:typed_data';

import 'package:face_ios_android/core/utils/template_meta_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaceTemplateMetaCodec round-trip', () {
    test('empty list encodes to 4-byte zero header and decodes back', () {
      final blob = FaceTemplateMetaCodec.encode(const <FaceTemplateMeta>[]);
      expect(blob.length, 4);
      expect(FaceTemplateMetaCodec.decode(blob), isEmpty);
    });

    test('single entry: glasses-on, fixed timestamp round-trips bit-exact',
        () {
      final stamp = DateTime.utc(2026, 5, 11, 15, 20, 51);
      final blob = FaceTemplateMetaCodec.encode(<FaceTemplateMeta>[
        FaceTemplateMeta(wearsGlasses: true, capturedAt: stamp),
      ]);
      expect(blob.length, 4 + 9);
      final decoded = FaceTemplateMetaCodec.decode(blob);
      expect(decoded, hasLength(1));
      expect(decoded.first.wearsGlasses, isTrue);
      expect(decoded.first.capturedAt.isAtSameMomentAs(stamp), isTrue);
    });

    test('mixed glasses-on / glasses-off list preserves index alignment',
        () {
      final t0 = DateTime.utc(2026, 5, 11, 10);
      final t1 = DateTime.utc(2026, 5, 11, 11);
      final t2 = DateTime.utc(2026, 5, 11, 12);
      final input = <FaceTemplateMeta>[
        FaceTemplateMeta(wearsGlasses: false, capturedAt: t0),
        FaceTemplateMeta(wearsGlasses: true, capturedAt: t1),
        FaceTemplateMeta(wearsGlasses: false, capturedAt: t2),
      ];
      final decoded = FaceTemplateMetaCodec.decode(
        FaceTemplateMetaCodec.encode(input),
      );
      expect(decoded, hasLength(3));
      expect(decoded[0].wearsGlasses, isFalse);
      expect(decoded[1].wearsGlasses, isTrue);
      expect(decoded[2].wearsGlasses, isFalse);
      expect(decoded[0].capturedAt.isAtSameMomentAs(t0), isTrue);
      expect(decoded[1].capturedAt.isAtSameMomentAs(t1), isTrue);
      expect(decoded[2].capturedAt.isAtSameMomentAs(t2), isTrue);
    });

    test('decode tolerates blob shorter than declared count (corrupt body)',
        () {
      // Craft a header claiming 3 entries but only carry payload for 1.
      final declared = ByteData(4 + 9);
      declared.setInt32(0, 3, Endian.little); // says 3 entries
      declared.setInt8(4, 1); // flags
      declared.setInt64(5, DateTime.utc(2026).millisecondsSinceEpoch,
          Endian.little);
      final decoded = FaceTemplateMetaCodec.decode(
        declared.buffer.asUint8List(),
      );
      // Only the 1 readable entry comes back. "Break on bad row" same
      // contract as FaceTemplatesCodec — never throws.
      expect(decoded, hasLength(1));
      expect(decoded.first.wearsGlasses, isTrue);
    });

    test('decode treats blobs smaller than the 4-byte header as empty', () {
      expect(
        FaceTemplateMetaCodec.decode(Uint8List(0)),
        isEmpty,
      );
      expect(
        FaceTemplateMetaCodec.decode(Uint8List.fromList(<int>[1, 2, 3])),
        isEmpty,
      );
    });

    test('decode rejects an absurd count without crashing', () {
      // Negative count → empty.
      final neg = ByteData(4)..setInt32(0, -1, Endian.little);
      expect(
        FaceTemplateMetaCodec.decode(neg.buffer.asUint8List()),
        isEmpty,
      );
      // Count above the per-user template cap → empty (protects against
      // a maliciously huge allocation).
      final huge = ByteData(4)..setInt32(0, 1 << 24, Endian.little);
      expect(
        FaceTemplateMetaCodec.decode(huge.buffer.asUint8List()),
        isEmpty,
      );
    });

    test('encode normalises capturedAt to UTC', () {
      // Local-zone DateTime should still come back as UTC bit-exact.
      final local = DateTime(2026, 5, 11, 12); // local
      final blob = FaceTemplateMetaCodec.encode(<FaceTemplateMeta>[
        FaceTemplateMeta(wearsGlasses: false, capturedAt: local),
      ]);
      final decoded = FaceTemplateMetaCodec.decode(blob);
      expect(decoded.first.capturedAt.isUtc, isTrue);
      expect(
        decoded.first.capturedAt.isAtSameMomentAs(local),
        isTrue,
        reason: 'Moment must survive the local→UTC normalisation.',
      );
    });
  });

  group('FaceTemplateMeta.copyWith', () {
    test('preserves fields when not overridden', () {
      final m = FaceTemplateMeta(
        wearsGlasses: true,
        capturedAt: DateTime.utc(2026, 5, 11),
      );
      final c = m.copyWith();
      expect(c.wearsGlasses, isTrue);
      expect(c.capturedAt, m.capturedAt);
    });

    test('overrides only the supplied fields', () {
      final m = FaceTemplateMeta(
        wearsGlasses: true,
        capturedAt: DateTime.utc(2026, 5, 11),
      );
      final flipped = m.copyWith(wearsGlasses: false);
      expect(flipped.wearsGlasses, isFalse);
      expect(flipped.capturedAt, m.capturedAt);
    });
  });
}
