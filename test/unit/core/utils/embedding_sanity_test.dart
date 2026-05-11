import 'dart:typed_data';

import 'package:face_ios_android/core/utils/embedding_sanity.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _vec(List<double> xs) => Float32List.fromList(xs);

void main() {
  group('EmbeddingSanity.sanitizeAndNormalize', () {
    test('normal vector → L2-normalised (||out|| ≈ 1)', () {
      final out = EmbeddingSanity.sanitizeAndNormalize(_vec([3, 4]));
      // 3-4-5 right triangle: (3,4) has magnitude 5, normalised to
      // (0.6, 0.8). Tight tolerance — this is the math contract.
      expect(out[0], closeTo(0.6, 1e-6));
      expect(out[1], closeTo(0.8, 1e-6));
    });

    test('returns a fresh buffer (input is not mutated)', () {
      final input = _vec([3, 4]);
      final out = EmbeddingSanity.sanitizeAndNormalize(input);
      expect(identical(input, out), isFalse);
      expect(input[0], 3.0, reason: 'Input must not be modified.');
      expect(input[1], 4.0);
    });

    test('NaN anywhere → throws', () {
      // A NaN in the raw output would silently propagate to a NaN
      // cosine downstream and yield a misleading "no match". Throwing
      // makes the verify-log record this as `extractionFailed`, which
      // is what telemetry needs to find the underlying root cause
      // (model glitch, bad input frame).
      expect(
        () => EmbeddingSanity.sanitizeAndNormalize(_vec([1, double.nan, 2])),
        throwsStateError,
      );
    });

    test('positive infinity → throws', () {
      expect(
        () => EmbeddingSanity.sanitizeAndNormalize(
            _vec([1, double.infinity, 2])),
        throwsStateError,
      );
    });

    test('negative infinity → throws', () {
      expect(
        () => EmbeddingSanity.sanitizeAndNormalize(
            _vec([1, double.negativeInfinity, 2])),
        throwsStateError,
      );
    });

    test('all-zero vector → throws (degenerate norm)', () {
      // Norm = 0 < 1e-6 floor. Silently returning the zero vector
      // would let the matcher score zero cosine against every template
      // and emit a deceptive `noMatch`. We deny extraction instead.
      expect(
        () => EmbeddingSanity.sanitizeAndNormalize(_vec([0, 0, 0])),
        throwsStateError,
      );
    });

    test('near-zero norm (below 1e-6) → throws', () {
      // 5e-8 → magnitude < 1e-6 even after the squaring/sqrt.
      expect(
        () => EmbeddingSanity.sanitizeAndNormalize(_vec([5e-8, 0, 0])),
        throwsStateError,
      );
    });

    test('single-axis unit vector round-trips to itself', () {
      // [1, 0, ...] is already unit-length; sanitise should preserve
      // it bit-exactly so downstream cosine math is deterministic.
      final out = EmbeddingSanity.sanitizeAndNormalize(_vec([1, 0, 0]));
      expect(out[0], 1.0);
      expect(out[1], 0.0);
      expect(out[2], 0.0);
    });
  });
}
