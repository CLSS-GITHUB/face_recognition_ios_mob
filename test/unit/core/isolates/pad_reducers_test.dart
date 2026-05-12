@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/isolates/pad_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart coverage for the spawn-time decision points the F-10
/// activation layer adds: output reducers, pixel normalisation, and
/// bilinear resize. These run without spawning an isolate and without
/// the bundled .tflite — they pin the behaviour the live PAD pipeline
/// depends on once a real checkpoint lands.
void main() {
  group('reduceToSpoofScore', () {
    test('singleSigmoidScalar passes the scalar through (clamped)', () {
      expect(
        reduceToSpoofScore([
          [0.0]
        ], PadModelKind.singleSigmoidScalar),
        0.0,
      );
      expect(
        reduceToSpoofScore([
          [0.42]
        ], PadModelKind.singleSigmoidScalar),
        closeTo(0.42, 1e-9),
      );
      // Out-of-range scalar (e.g. raw logit leaked through without a
      // final sigmoid) must clamp, not blow past 1.0.
      expect(
        reduceToSpoofScore([
          [12.5]
        ], PadModelKind.singleSigmoidScalar),
        1.0,
      );
      expect(
        reduceToSpoofScore([
          [-3.0]
        ], PadModelKind.singleSigmoidScalar),
        0.0,
      );
    });

    test('binarySoftmax returns softmax(real, spoof)[1]', () {
      // Equal logits → uniform 0.5.
      expect(
        reduceToSpoofScore([
          [0.0, 0.0]
        ], PadModelKind.binarySoftmax),
        closeTo(0.5, 1e-9),
      );
      // Spoof logit dominates → score near 1.
      final highSpoof = reduceToSpoofScore([
        [-5.0, 5.0]
      ], PadModelKind.binarySoftmax);
      expect(highSpoof, greaterThan(0.999));
      // Real logit dominates → score near 0.
      final lowSpoof = reduceToSpoofScore([
        [5.0, -5.0]
      ], PadModelKind.binarySoftmax);
      expect(lowSpoof, lessThan(0.001));
    });

    test(
        'silentFaceThree applies Silent-Face MiniFASNet convention '
        '(class 1 = real)', () {
      // Silent-Face logits: [spoof_print, real, spoof_replay].
      // Real dominates → spoof score near 0.
      final realDominant = reduceToSpoofScore([
        [0.0, 10.0, 0.0]
      ], PadModelKind.silentFaceThree);
      expect(realDominant, lessThan(0.001));

      // Either spoof class dominates → spoof score near 1.
      final printSpoof = reduceToSpoofScore([
        [10.0, 0.0, 0.0]
      ], PadModelKind.silentFaceThree);
      expect(printSpoof, greaterThan(0.999));
      final replaySpoof = reduceToSpoofScore([
        [0.0, 0.0, 10.0]
      ], PadModelKind.silentFaceThree);
      expect(replaySpoof, greaterThan(0.999));

      // Uniform logits → 1 - 1/3 ≈ 0.667.
      final uniform = reduceToSpoofScore([
        [1.0, 1.0, 1.0]
      ], PadModelKind.silentFaceThree);
      expect(uniform, closeTo(2.0 / 3.0, 1e-9));
    });

    test('softmax stays stable against large logits (no overflow)', () {
      // exp(700) overflows to +inf. Naive softmax would produce NaN
      // for both reducers below; the numerically-stable form must
      // still hand us a finite, in-range result.
      final binary = reduceToSpoofScore([
        [700.0, 701.0]
      ], PadModelKind.binarySoftmax);
      expect(binary.isFinite, isTrue);
      expect(binary, greaterThanOrEqualTo(0.0));
      expect(binary, lessThanOrEqualTo(1.0));

      final three = reduceToSpoofScore([
        [800.0, 0.0, -800.0]
      ], PadModelKind.silentFaceThree);
      expect(three.isFinite, isTrue);
      expect(three, greaterThanOrEqualTo(0.0));
      expect(three, lessThanOrEqualTo(1.0));
    });
  });

  group('resizeAndNormalize', () {
    test('same-size signedHalf preserves the existing scaffold preprocess',
        () {
      // The pre-activation isolate used (px - 127.5) / 127.5 at 112×112.
      // The new code path must reproduce that exactly when called with
      // size=112 + signedHalf — otherwise activating the kind/norm
      // wiring silently regresses the calibration of any stub-mode
      // model that was tuned against the old preprocess.
      const n = FaceThresholds.inputSize;
      final src = Uint8List(n * n * 3);
      for (var i = 0; i < src.length; i++) {
        src[i] = i & 0xff;
      }
      final dst = _allocInput(n);
      resizeAndNormalize(src, n, dst, n, PadNormalization.signedHalf);

      // Spot-check a few pixels.
      // Top-left pixel: rgb = (0, 1, 2) → normalised
      // ((0  - 127.5)/127.5, (1  - 127.5)/127.5, (2  - 127.5)/127.5).
      expect(dst[0][0][0][0], closeTo(-1.0, 1e-9));
      expect(dst[0][0][0][1], closeTo((1 - 127.5) / 127.5, 1e-9));
      expect(dst[0][0][0][2], closeTo((2 - 127.5) / 127.5, 1e-9));
    });

    test('unitZeroOne maps 0/255 to 0.0 and 1.0 respectively', () {
      const n = 4;
      final src = Uint8List.fromList(<int>[
        for (var i = 0; i < n * n * 3; i++) (i % 2 == 0) ? 0 : 255,
      ]);
      final dst = _allocInput(n);
      resizeAndNormalize(src, n, dst, n, PadNormalization.unitZeroOne);
      // Even-indexed source bytes were 0 → 0.0; odd → 1.0.
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          for (var c = 0; c < 3; c++) {
            final flat = (y * n + x) * 3 + c;
            final expected = (flat % 2 == 0) ? 0.0 : 1.0;
            expect(dst[0][y][x][c], expected,
                reason: 'pixel ($x,$y,c=$c) flat=$flat');
          }
        }
      }
    });

    test('imagenet applies per-channel mean/std', () {
      const n = 2;
      // All channels = 128.
      final src = Uint8List(n * n * 3)..fillRange(0, n * n * 3, 128);
      final dst = _allocInput(n);
      resizeAndNormalize(src, n, dst, n, PadNormalization.imagenet);
      // Each channel: ((128/255) - mean_c) / std_c.
      const meanR = 0.485, meanG = 0.456, meanB = 0.406;
      const stdR = 0.229, stdG = 0.224, stdB = 0.225;
      final v = 128 / 255.0;
      expect(dst[0][0][0][0], closeTo((v - meanR) / stdR, 1e-9));
      expect(dst[0][0][0][1], closeTo((v - meanG) / stdG, 1e-9));
      expect(dst[0][0][0][2], closeTo((v - meanB) / stdB, 1e-9));
    });

    test('bilinear downscale preserves a uniform field exactly', () {
      // A constant-color image must stay constant after bilinear
      // resize regardless of target size — a nearest-neighbour bug
      // would still pass this; the next test catches NN.
      const srcN = FaceThresholds.inputSize;
      const dstN = 80; // Silent-Face native input.
      final src = Uint8List(srcN * srcN * 3);
      for (var i = 0; i < src.length; i += 3) {
        src[i] = 200;
        src[i + 1] = 150;
        src[i + 2] = 50;
      }
      final dst = _allocInput(dstN);
      resizeAndNormalize(src, srcN, dst, dstN, PadNormalization.unitZeroOne);
      for (var y = 0; y < dstN; y++) {
        for (var x = 0; x < dstN; x++) {
          expect(dst[0][y][x][0], closeTo(200 / 255.0, 1e-9));
          expect(dst[0][y][x][1], closeTo(150 / 255.0, 1e-9));
          expect(dst[0][y][x][2], closeTo(50 / 255.0, 1e-9));
        }
      }
    });

    test('bilinear (not nearest) blends a sharp source step', () {
      // 4×1-style gradient encoded as 4×4: left half = 0, right half = 255.
      // Downscaling 4→3 with NN would land each output pixel on the
      // nearer source column (0, 0/255 split, 255) — no blended
      // value. Bilinear should produce at least one intermediate
      // value strictly between 0 and 255 in the middle column.
      const srcN = 4;
      const dstN = 3;
      final src = Uint8List(srcN * srcN * 3);
      for (var y = 0; y < srcN; y++) {
        for (var x = 0; x < srcN; x++) {
          final v = x < srcN / 2 ? 0 : 255;
          final i = (y * srcN + x) * 3;
          src[i] = v;
          src[i + 1] = v;
          src[i + 2] = v;
        }
      }
      final dst = _allocInput(dstN);
      resizeAndNormalize(src, srcN, dst, dstN, PadNormalization.unitZeroOne);
      // Centre column at dstX=1 should not be exactly 0.0 or 1.0 —
      // it samples across the step.
      final centre = dst[0][1][1][0];
      expect(centre, greaterThan(0.0));
      expect(centre, lessThan(1.0));
    });
  });
}

List<List<List<List<double>>>> _allocInput(int n) {
  return List<List<List<List<double>>>>.generate(
    1,
    (_) => List<List<List<double>>>.generate(
      n,
      (_) => List<List<double>>.generate(
        n,
        (_) => List<double>.filled(3, 0),
      ),
    ),
  );
}
