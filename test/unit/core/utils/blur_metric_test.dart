import 'dart:math';
import 'dart:typed_data';

import 'package:face_ios_android/core/utils/blur_metric.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a flat-grey RGB buffer of size [w]·[h]·3.
Uint8List _flat(int w, int h, int luma) {
  final out = Uint8List(w * h * 3);
  for (var i = 0; i < out.length; i++) {
    out[i] = luma;
  }
  return out;
}

/// Builds an RGB buffer where each row is filled with a step value drawn
/// from [pattern]. Used to construct a high-Laplacian (sharp-edge) image.
Uint8List _stripes(int w, int h, List<int> pattern) {
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    final v = pattern[y % pattern.length];
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
    }
  }
  return out;
}

/// Builds an RGB buffer where each pixel is independently random uniform in
/// `[0, 255]` — maximum high-frequency content, the noisiest possible image
/// short of pathological constructions.
Uint8List _whiteNoise(int w, int h, {int seed = 7}) {
  final rng = Random(seed);
  final out = Uint8List(w * h * 3);
  for (var i = 0; i < out.length; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void main() {
  group('BlurMetric.varianceOfLaplacian', () {
    test('flat-grey buffer has zero variance (fully smooth)', () {
      final buf = _flat(16, 16, 128);
      expect(BlurMetric.varianceOfLaplacian(buf, 16, 16), 0);
    });

    test('alternating 0/255 stripes produce a large variance (sharp edges)',
        () {
      // Each interior row's Laplacian is ±255·2 (vertical neighbours flip);
      // variance is dominated by those samples.
      final buf = _stripes(16, 16, const <int>[0, 255]);
      final v = BlurMetric.varianceOfLaplacian(buf, 16, 16);
      // Empirical floor — the exact number depends on luma rounding, but
      // a sharp 0/255 stripe pattern is well above ~10 000.
      expect(v, greaterThan(10000),
          reason: 'High-contrast stripes must dwarf any plausible floor.');
    });

    test('low-amplitude ripple ≈ blurry frame stays under the prod floor',
        () {
      // Sinusoidal-ish band where neighbours differ by ≤ 2 — emulates the
      // softening you see in a motion-blurred face crop.
      final pattern = List<int>.generate(8, (i) => 120 + ((i % 4) ~/ 2));
      final buf = _stripes(112, 112, pattern);
      final v = BlurMetric.varianceOfLaplacian(buf, 112, 112);
      // Live floor in FaceThresholds is 60. This synthetic "blur" should
      // land well below — the test pins that intuition so a future
      // floor tweak still has headroom.
      expect(v, lessThan(60),
          reason: 'Synthetic low-amplitude ripple must read as blurry.');
    });

    test('white-noise frame easily clears the prod floor', () {
      // Per-pixel uniform random — saturated high-frequency content. This
      // is the upper-bound case: anything dynamic should score above 60.
      final buf = _whiteNoise(64, 64);
      final v = BlurMetric.varianceOfLaplacian(buf, 64, 64);
      expect(v, greaterThan(60));
    });

    test('returns 0 for sub-3px dimensions (no interior)', () {
      // Laplacian needs 4 neighbours → interior of (w−2)·(h−2). Smaller
      // buffers should fail closed without throwing.
      expect(
          BlurMetric.varianceOfLaplacian(_flat(2, 2, 128), 2, 2), 0);
      expect(
          BlurMetric.varianceOfLaplacian(_flat(8, 2, 128), 8, 2), 0);
    });

    test('returns 0 for truncated RGB buffer (defensive)', () {
      // Half-filled buffer must not throw or read out of bounds.
      final half = Uint8List(8 * 8 * 3 ~/ 2);
      expect(BlurMetric.varianceOfLaplacian(half, 8, 8), 0);
    });
  });
}
