import 'dart:math' as math;
import 'dart:typed_data';

/// Cheap anti-spoof heuristic: phone-on-phone replay attacks tend to
/// produce a crop with unnatural saturation + brightness because the
/// emitting screen has a flat colour-temperature and a small aperture.
/// Real skin under typical lighting is in a much narrower (saturation,
/// luminance) regime.
///
/// See `docs/verification/architecture_recommendations.md` §7.3.
///
/// Stateless. Operates on the same 112×112 RGB byte buffer the embedding
/// extractor expects, so the cost on top of the regular pipeline is one
/// pass of 256 sampled pixels — sub-millisecond.
class ScreenReflectionDetector {
  const ScreenReflectionDetector();

  /// Number of pixels to sample. The architecture doc spec says 256.
  static const int _samples = 256;

  /// Mean saturation above this raises the spoof signal.
  static const double _saturationThreshold = 0.65;

  /// Mean luma (BT.601) above this raises the spoof signal.
  static const double _lumaThreshold = 220;

  /// Returns `true` when the cropped face shows screen-like statistics:
  /// **both** saturation and luminance over their thresholds. Either alone
  /// is normal: a vivid red shirt, a sunlit face, etc. The combination is
  /// the unusual one.
  bool isLikelyScreen(Uint8List rgb) {
    if (rgb.length < 3) return false;
    final pixelCount = rgb.length ~/ 3;
    final stride = math.max(1, pixelCount ~/ _samples);

    var sumSat = 0.0;
    var sumLuma = 0.0;
    var taken = 0;
    for (var pi = 0; pi < pixelCount && taken < _samples; pi += stride) {
      final off = pi * 3;
      final r = rgb[off].toDouble();
      final g = rgb[off + 1].toDouble();
      final b = rgb[off + 2].toDouble();

      final maxC = math.max(r, math.max(g, b));
      final minC = math.min(r, math.min(g, b));
      final sat = maxC == 0 ? 0.0 : (maxC - minC) / maxC;

      final luma = 0.299 * r + 0.587 * g + 0.114 * b;

      sumSat += sat;
      sumLuma += luma;
      taken++;
    }
    if (taken == 0) return false;
    final meanSat = sumSat / taken;
    final meanLuma = sumLuma / taken;
    return meanSat > _saturationThreshold && meanLuma > _lumaThreshold;
  }
}
