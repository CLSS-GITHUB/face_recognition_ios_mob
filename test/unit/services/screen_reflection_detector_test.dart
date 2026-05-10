import 'dart:typed_data';

import 'package:face_ios_android/services/screen_reflection_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const int _payload = 112 * 112 * 3;

Uint8List _solid(int r, int g, int b) {
  final out = Uint8List(_payload);
  for (var i = 0; i < _payload; i += 3) {
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
  }
  return out;
}

void main() {
  const det = ScreenReflectionDetector();

  test('high-saturation high-luma red → flagged as screen', () {
    // Pure red: saturation=1.0, luma≈76. luma not high enough yet.
    expect(det.isLikelyScreen(_solid(255, 0, 0)), isFalse);
    // Bright magenta: sat=1.0, luma≈105 — still under luma cutoff.
    expect(det.isLikelyScreen(_solid(255, 0, 255)), isFalse);
    // Mostly-yellow + green tint: pushes luma above 220 with sat ≈ 0.78.
    expect(det.isLikelyScreen(_solid(255, 250, 50)), isTrue);
  });

  test('skin tone: not flagged', () {
    // Typical mid-tone skin (Fitzpatrick III–IV). Saturation modest,
    // luma well below the threshold.
    expect(det.isLikelyScreen(_solid(204, 158, 130)), isFalse);
  });

  test('grey wall under good light: not flagged', () {
    // High luma but near-zero saturation.
    expect(det.isLikelyScreen(_solid(230, 230, 230)), isFalse);
  });

  test('pure black: not flagged (early-out path)', () {
    expect(det.isLikelyScreen(_solid(0, 0, 0)), isFalse);
  });

  test('saturated dark colour: not flagged (luma below cutoff)', () {
    // sat=1.0 but luma≈30.
    expect(det.isLikelyScreen(_solid(100, 0, 0)), isFalse);
  });

  test('zero-length input is safely false', () {
    expect(det.isLikelyScreen(Uint8List(0)), isFalse);
  });
}
