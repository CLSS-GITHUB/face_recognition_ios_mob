import 'dart:math';
import 'dart:typed_data';

import 'package:face_ios_android/core/utils/camera_image_converter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Byte-exact reference: the original scalar implementation of NV21 →
/// RGB. F-9 (lite) rewrote `Nv21Decoder.nv21ToRgb` with loop unrolling
/// and UV-contribution hoisting; this reference is preserved inside
/// the test so we can prove the optimisation is a pure speedup,
/// pixel-for-pixel identical to what the camera-image pipeline used to
/// produce. If `nv21ToRgb` ever needs to change semantically (e.g. a
/// different YUV → RGB matrix), update this reference in the same PR.
Uint8List _referenceNv21ToRgb(Uint8List nv21, int width, int height) {
  final out = Uint8List(width * height * 3);
  final frameSize = width * height;
  var rgbIndex = 0;
  for (var y = 0; y < height; y++) {
    var uvp = frameSize + (y >> 1) * width;
    var u = 0, v = 0;
    for (var x = 0; x < width; x++) {
      final yp = y * width + x;
      var yv = (nv21[yp] & 0xFF) - 16;
      if (yv < 0) yv = 0;
      if ((x & 1) == 0) {
        v = (nv21[uvp++] & 0xFF) - 128;
        u = (nv21[uvp++] & 0xFF) - 128;
      }
      final y1192 = 1192 * yv;
      var r = y1192 + 1634 * v;
      var g = y1192 - 833 * v - 400 * u;
      var b = y1192 + 2066 * u;
      r = r.clamp(0, 262143);
      g = g.clamp(0, 262143);
      b = b.clamp(0, 262143);
      out[rgbIndex++] = (r >> 10) & 0xFF;
      out[rgbIndex++] = (g >> 10) & 0xFF;
      out[rgbIndex++] = (b >> 10) & 0xFF;
    }
  }
  return out;
}

Uint8List _synthNv21(int width, int height, {int seed = 0}) {
  // NV21 layout: width*height Y bytes, then (width*height/2) interleaved
  // VU bytes. Use a deterministic PRNG so test failures are
  // reproducible across runs and machines.
  final rng = Random(seed);
  final size = width * height + (width * height) ~/ 2;
  final out = Uint8List(size);
  for (var i = 0; i < size; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void main() {
  group('Nv21Decoder.nv21ToRgb byte-exact equivalence', () {
    test('matches reference impl on a 16x16 deterministic frame', () {
      final nv21 = _synthNv21(16, 16, seed: 1);
      final reference = _referenceNv21ToRgb(nv21, 16, 16);
      final optimised = Nv21Decoder.nv21ToRgb(nv21, 16, 16);
      expect(optimised, equals(reference));
    });

    test('matches reference impl on a 240x320 portrait frame', () {
      // Representative of the front-camera resolution after the camera
      // plugin rotates to portrait (ResolutionPreset.medium ≈ 480x640
      // native; ML Kit rotates to 480x640 portrait; downstream NV21
      // dimensions match the native sensor though).
      const w = 240;
      const h = 320;
      final nv21 = _synthNv21(w, h, seed: 7);
      final reference = _referenceNv21ToRgb(nv21, w, h);
      final optimised = Nv21Decoder.nv21ToRgb(nv21, w, h);
      expect(optimised, equals(reference));
    });

    test('handles all-black input (Y=0, UV=128) → black RGB', () {
      const w = 8;
      const h = 8;
      final nv21 = Uint8List(w * h + (w * h) ~/ 2);
      // Y plane: zero. UV plane: 128 (neutral chroma).
      for (var i = w * h; i < nv21.length; i++) {
        nv21[i] = 128;
      }
      final out = Nv21Decoder.nv21ToRgb(nv21, w, h);
      // Every pixel should clamp to 0 (Y<16 → yv=0 → contribution = 0).
      expect(out.every((b) => b == 0), isTrue);
    });

    test('handles saturated white input (Y=235, UV=128) → near-white RGB',
        () {
      const w = 8;
      const h = 8;
      final nv21 = Uint8List(w * h + (w * h) ~/ 2);
      // Y plane: 235 (broadcast-range white). UV plane: 128 (neutral).
      for (var i = 0; i < w * h; i++) {
        nv21[i] = 235;
      }
      for (var i = w * h; i < nv21.length; i++) {
        nv21[i] = 128;
      }
      final out = Nv21Decoder.nv21ToRgb(nv21, w, h);
      // 235→r = 255 (per the broadcast-range scaling baked into the
      // 1192 coefficient). Confirm we agree with the reference on
      // every pixel.
      final reference = _referenceNv21ToRgb(nv21, w, h);
      expect(out, equals(reference));
    });

    test('handles odd width without crashing (defensive)', () {
      // Camera output is always even-width in practice, but the
      // optimised decoder explicitly handles odd widths via the
      // trailing-pixel branch so synthetic inputs don't crash the
      // pipeline. The reference implementation would over-read here —
      // we deliberately don't byte-compare; we just assert that the
      // optimised decoder produces a sanely-sized output and doesn't
      // throw a RangeError.
      const w = 7;
      const h = 4;
      // Pad the input by 1 byte so even the reference's potential
      // over-read by 1 (which we don't test) would be safe.
      final padded = Uint8List(w * h + (w * h + 1) ~/ 2 + 1);
      final synth = _synthNv21(w, h, seed: 42);
      padded.setRange(0, synth.length, synth);
      final optimised = Nv21Decoder.nv21ToRgb(padded, w, h);
      expect(optimised.length, w * h * 3);
    });

    test('output length is always width * height * 3', () {
      // Defensive: any future change that grows / shrinks the output
      // buffer would break the BitmapUtils.rgbBytesToImage contract.
      const cases = <(int, int)>[
        (8, 8),
        (16, 16),
        (240, 320),
      ];
      for (final (w, h) in cases) {
        final nv21 = _synthNv21(w, h);
        final out = Nv21Decoder.nv21ToRgb(nv21, w, h);
        expect(out.length, w * h * 3, reason: 'wrong length for ${w}x$h');
      }
    });
  });
}
