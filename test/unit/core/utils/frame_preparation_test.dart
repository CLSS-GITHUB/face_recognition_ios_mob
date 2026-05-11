import 'dart:typed_data';
import 'dart:ui';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/utils/frame_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

const int _payloadBytes =
    FaceThresholds.inputSize * FaceThresholds.inputSize * 3;

/// Builds a synthetic NV21 frame of the requested dimensions. The bytes are
/// a deterministic ramp so the test is reproducible and the prepare pipeline
/// has something non-trivial to decode.
Uint8List _syntheticNv21(int w, int h, {int seed = 0}) {
  final size = w * h + (w * h) ~/ 2;
  final out = Uint8List(size);
  for (var i = 0; i < out.length; i++) {
    out[i] = (i + seed) & 0xff;
  }
  return out;
}

Uint8List _syntheticBgra(int w, int h, {int seed = 0}) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = (i + seed) & 0xff;
  }
  return out;
}

void main() {
  group('FramePreparation.prepare', () {
    test('NV21 → 112×112×3 payload', () {
      const w = 240;
      const h = 320;
      final raw = _syntheticNv21(w, h);
      final out = FramePreparation.prepare(
        rawBytes: raw,
        width: w,
        height: h,
        format: RawFrameFormat.nv21,
        // Centered crop ~half the frame — bbox interpreted in the decoded
        // image's coord space, which is what the host pipeline also uses.
        bbox: const Rect.fromLTWH(60, 90, 120, 140),
      );
      expect(out, isNotNull);
      expect(out!.length, _payloadBytes);
    });

    test('BGRA → 112×112×3 payload', () {
      const w = 200;
      const h = 200;
      final raw = _syntheticBgra(w, h);
      final out = FramePreparation.prepare(
        rawBytes: raw,
        width: w,
        height: h,
        format: RawFrameFormat.bgra8888,
        bbox: const Rect.fromLTWH(40, 40, 120, 120),
      );
      expect(out, isNotNull);
      expect(out!.length, _payloadBytes);
    });

    test('rejects truncated NV21 buffer rather than reading past end', () {
      // Declare a 240×320 frame but supply only 100 bytes — must not crash.
      final tiny = Uint8List(100);
      final out = FramePreparation.prepare(
        rawBytes: tiny,
        width: 240,
        height: 320,
        format: RawFrameFormat.nv21,
        bbox: const Rect.fromLTWH(0, 0, 64, 64),
      );
      expect(out, isNull);
    });

    test('rejects truncated BGRA buffer', () {
      // 200×200 BGRA needs 160 000 bytes; supply far less.
      final tiny = Uint8List(50);
      final out = FramePreparation.prepare(
        rawBytes: tiny,
        width: 200,
        height: 200,
        format: RawFrameFormat.bgra8888,
        bbox: const Rect.fromLTWH(0, 0, 64, 64),
      );
      expect(out, isNull);
    });

    test('missing eye landmarks → still produces a valid payload', () {
      // The host pipeline already tolerates absent landmarks (no rotation,
      // just the un-rotated crop). Prepare must match — never throws.
      final raw = _syntheticNv21(240, 320);
      final out = FramePreparation.prepare(
        rawBytes: raw,
        width: 240,
        height: 320,
        format: RawFrameFormat.nv21,
        bbox: const Rect.fromLTWH(60, 90, 120, 140),
        // landmarks omitted
      );
      expect(out, isNotNull);
      expect(out!.length, _payloadBytes);
    });

    test('with eye coords → rotation applied, payload still 112×112×3', () {
      // Slight inter-eye tilt → rotation kicks in. We can't easily assert
      // pixel-exact correctness without a reference image, but we *can*
      // assert it doesn't blow up and produces the right byte count.
      final raw = _syntheticNv21(240, 320);
      final out = FramePreparation.prepare(
        rawBytes: raw,
        width: 240,
        height: 320,
        format: RawFrameFormat.nv21,
        bbox: const Rect.fromLTWH(60, 90, 120, 140),
        leftEyeX: 100,
        leftEyeY: 130,
        rightEyeX: 160,
        rightEyeY: 135,
      );
      expect(out, isNotNull);
      expect(out!.length, _payloadBytes);
    });
  });

  group('RawFrameFormat wire-stable indices', () {
    // The isolate decodes the format by index. Re-ordering would silently
    // break in-flight messages — pin the layout to catch refactors.
    test('nv21 is index 0, bgra8888 is index 1', () {
      expect(RawFrameFormat.nv21.index, 0);
      expect(RawFrameFormat.bgra8888.index, 1);
    });
  });
}
