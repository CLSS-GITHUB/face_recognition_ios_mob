import 'dart:typed_data';

/// Frame-sharpness metric used by the verify and enrol pipelines to short-
/// circuit motion-blurred captures before they reach the embedding extractor.
///
/// We compute the *variance of the discrete Laplacian* over the luma channel
/// of an RGB buffer. The Laplacian acts as a high-pass filter; its variance
/// over the image is a well-known no-reference focus measure (Pech-Pacheco
/// et al., 2000) that correlates strongly with subjective sharpness on
/// face-sized crops. Higher = sharper.
///
/// Why this gate matters: a motion-blurred 112×112 still drives a numerically
/// valid embedding through MobileFaceNet, but the cosine to the user's
/// enrolled template drops by ~0.05–0.10 — enough to fall into the
/// `verifyThreshold` ↔ `verifyUserMargin` band and produce a `noMatch` for a
/// legitimate user. Catching the blur up front saves the ~30 ms isolate
/// dispatch and surfaces a far more actionable "Hold steady" hint than a
/// generic match failure.
class BlurMetric {
  BlurMetric._();

  /// Variance-of-Laplacian over the BT.601 luma derived from an RGB byte
  /// buffer. Returns `0` for empty / degenerate input rather than throwing
  /// — the matcher treats `0` as "below floor" so the caller just rejects.
  ///
  /// The 5-tap discrete Laplacian kernel used here matches the canonical
  /// Pech-Pacheco implementation:
  ///   `L(x,y) = 4·I(x,y) − I(x-1,y) − I(x+1,y) − I(x,y-1) − I(x,y+1)`
  static double varianceOfLaplacian(Uint8List rgb, int width, int height) {
    if (width < 3 || height < 3) return 0;
    if (rgb.length < 3 * width * height) return 0;

    final pixels = width * height;
    final luma = Uint8List(pixels);
    for (var i = 0, j = 0; i < pixels; i++, j += 3) {
      // BT.601 luma, integer-rounded to keep the metric reproducible across
      // platforms (no float drift between Android and iOS).
      luma[i] = ((299 * rgb[j] + 587 * rgb[j + 1] + 114 * rgb[j + 2]) ~/ 1000)
          & 0xFF;
    }

    // Interior-only Laplacian — borders have no defined neighbours.
    final interior = (width - 2) * (height - 2);
    if (interior <= 0) return 0;

    var sum = 0;
    var sumSq = 0.0;
    for (var y = 1; y < height - 1; y++) {
      final rowStart = y * width;
      for (var x = 1; x < width - 1; x++) {
        final i = rowStart + x;
        final lap = 4 * luma[i] -
            luma[i - 1] -
            luma[i + 1] -
            luma[i - width] -
            luma[i + width];
        sum += lap;
        sumSq += lap.toDouble() * lap;
      }
    }

    final mean = sum / interior;
    final variance = sumSq / interior - mean * mean;
    return variance < 0 ? 0 : variance;
  }
}
