import 'dart:math';
import 'dart:typed_data';

import 'package:face_ios_android/services/gabor_texture_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const int _side = 112;
const int _payload = _side * _side * 3;

Uint8List _solid(int r, int g, int b) {
  final out = Uint8List(_payload);
  for (var i = 0; i < _payload; i += 3) {
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
  }
  return out;
}

/// Isotropic noise — equal-variance grain in every direction. Stand-in
/// for real-skin micro-texture for the purposes of this detector.
Uint8List _isotropicNoise({int seed = 0}) {
  final out = Uint8List(_payload);
  final rng = Random(seed);
  for (var i = 0; i < _payload; i += 3) {
    final v = 128 + rng.nextInt(64) - 32; // mid-grey ± 32
    out[i] = v;
    out[i + 1] = v;
    out[i + 2] = v;
  }
  return out;
}

/// Strong vertical stripes (alternating bright/dim columns). Stripe
/// width is the detector's stencil offset (2 px), giving a period of
/// 4 px between like-colour columns — but **importantly** the period
/// must NOT equal the full 4-pixel stencil span (offset ±2 → 4 px),
/// or the two endpoints land on the same phase and the gradient
/// averages to zero. Using stripe width 4 (period 8) puts the
/// stencil endpoints in opposite phases for every sample, producing
/// the strongest possible horizontal gradient.
Uint8List _verticalStripes() {
  final out = Uint8List(_payload);
  for (var y = 0; y < _side; y++) {
    for (var x = 0; x < _side; x++) {
      final v = ((x ~/ 4) & 1) == 0 ? 60 : 200;
      final off = (y * _side + x) * 3;
      out[off] = v;
      out[off + 1] = v;
      out[off + 2] = v;
    }
  }
  return out;
}

/// Strong horizontal stripes — the orthogonal partner to
/// [_verticalStripes]. Same period reasoning. Vertical-direction
/// energy dominates.
Uint8List _horizontalStripes() {
  final out = Uint8List(_payload);
  for (var y = 0; y < _side; y++) {
    final v = ((y ~/ 4) & 1) == 0 ? 60 : 200;
    for (var x = 0; x < _side; x++) {
      final off = (y * _side + x) * 3;
      out[off] = v;
      out[off + 1] = v;
      out[off + 2] = v;
    }
  }
  return out;
}

/// Stripes at 45° along the (x+y) axis. Stripe width must be tuned to
/// the diagonal stencil's effective spatial span: the offset is
/// (±2, ±2), giving an (x+y) delta of ±4 between stencil endpoints
/// (total span 8 in (x+y) units). Stripe width 8 — period 16 in
/// (x+y) — puts those endpoints in opposite stripe phases, producing
/// the strongest possible diagonal gradient. Period 8 (matching the
/// axial test) would put both endpoints in the same phase and zero
/// the diagonal channel, exactly the symmetric of the axial-period-
/// 4 zero-crossing bug.
Uint8List _diagonalStripes() {
  final out = Uint8List(_payload);
  for (var y = 0; y < _side; y++) {
    for (var x = 0; x < _side; x++) {
      final v = (((x + y) ~/ 8) & 1) == 0 ? 60 : 200;
      final off = (y * _side + x) * 3;
      out[off] = v;
      out[off + 1] = v;
      out[off + 2] = v;
    }
  }
  return out;
}

void main() {
  const det = GaborTextureDetector();

  group('GaborTextureDetector — degenerate inputs', () {
    test('zero-length buffer → degenerate, not flagged', () {
      final r = det.scoreAnisotropy(Uint8List(0));
      expect(r.isDegenerate, isTrue);
      expect(r.degenerateReason, 'input-too-small');
      expect(det.isLikelySpoofTexture(Uint8List(0)), isFalse);
    });

    test('short buffer → degenerate', () {
      final r = det.scoreAnisotropy(Uint8List(_payload - 1));
      expect(r.isDegenerate, isTrue);
    });

    test('solid colour (no texture) → degenerate flat-frame, not flagged', () {
      // Pure neutral grey produces zero gradient in every direction.
      // The brightness gate upstream rejects extremes; here we just
      // pass-through the texture decision.
      final r = det.scoreAnisotropy(_solid(128, 128, 128));
      expect(r.isDegenerate, isTrue);
      expect(r.degenerateReason, 'flat-frame');
      expect(det.isLikelySpoofTexture(_solid(128, 128, 128)), isFalse);
    });

    test('pure black → degenerate flat-frame', () {
      final r = det.scoreAnisotropy(_solid(0, 0, 0));
      expect(r.isDegenerate, isTrue);
    });
  });

  group('GaborTextureDetector — isotropic texture passes', () {
    test('mid-grey noise → low anisotropy, not flagged', () {
      final result = det.scoreAnisotropy(_isotropicNoise(seed: 1));
      expect(result.isDegenerate, isFalse);
      // Random gradients in every direction → ratio well under the
      // gate. Some directional drift from the finite sample is
      // expected, but it should not exceed the conservative 0.55
      // default by a long margin.
      expect(result.score, lessThan(0.4),
          reason: 'isotropic noise should be near-zero anisotropy');
      expect(det.isLikelySpoofTexture(_isotropicNoise(seed: 1)), isFalse);
    });

    test('noise reproducibility — same seed, same score', () {
      final a = det.scoreAnisotropy(_isotropicNoise(seed: 7)).score;
      final b = det.scoreAnisotropy(_isotropicNoise(seed: 7)).score;
      expect(a, equals(b));
    });
  });

  group('GaborTextureDetector — anisotropic patterns flagged', () {
    test('vertical stripes → flagged', () {
      final result = det.scoreAnisotropy(_verticalStripes());
      expect(result.isDegenerate, isFalse);
      // Horizontal gradient should dominate by ≥ 3x the mean.
      expect(result.score, greaterThan(GaborTextureDetector.anisotropyThreshold));
      expect(result.energy0, greaterThan(result.energy90),
          reason: 'vertical stripes → horizontal gradient dominates');
      expect(det.isLikelySpoofTexture(_verticalStripes()), isTrue);
    });

    test('horizontal stripes → flagged', () {
      final result = det.scoreAnisotropy(_horizontalStripes());
      expect(result.isDegenerate, isFalse);
      expect(result.score, greaterThan(GaborTextureDetector.anisotropyThreshold));
      expect(result.energy90, greaterThan(result.energy0),
          reason: 'horizontal stripes → vertical gradient dominates');
      expect(det.isLikelySpoofTexture(_horizontalStripes()), isTrue);
    });

    test('diagonal stripes → flagged on a diagonal channel', () {
      final result = det.scoreAnisotropy(_diagonalStripes());
      expect(result.isDegenerate, isFalse);
      expect(result.score, greaterThan(GaborTextureDetector.anisotropyThreshold));
      // 45° stripes — either e45 or e135 dominates (depending on
      // which side of the bar pattern the stencil lands on).
      final maxDiagonal = result.energy45 > result.energy135
          ? result.energy45
          : result.energy135;
      final maxAxial = result.energy0 > result.energy90
          ? result.energy0
          : result.energy90;
      expect(maxDiagonal, greaterThan(maxAxial * 0.5),
          reason: 'diagonal stripes lift at least one diagonal channel');
    });
  });
}
