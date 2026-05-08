import 'dart:typed_data';

import '../core/constants/thresholds.dart';
import '../features/face_verification/domain/entities/match_result.dart';

/// Pure-Dart cosine similarity + best-match search.
///
/// Mirrors NativeFaceMatcher.kt's surface, with a Dart implementation.
/// Both inputs are assumed L2-normalized — the cosine reduces to a dot product.
/// FFI acceleration is deferred (see docs/migration/09_performance.md §9.3).
class FaceMatchingService {
  const FaceMatchingService();

  /// Cosine similarity ∈ [-1, 1]. Both vectors must be L2-normalized.
  double cosine(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError('Embedding lengths differ: ${a.length} vs ${b.length}');
    }
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  /// Searches a flattened bank of [count] templates of length
  /// `FaceThresholds.embeddingDim` for the highest cosine similarity to
  /// [probe]. Returns `MatchResult.none()` when [count] is 0 or when no
  /// template clears the verify threshold.
  MatchResult findBestMatch(
    Float32List probe,
    Float32List flattened,
    int count, {
    double threshold = FaceThresholds.verifyThreshold,
  }) {
    if (count <= 0 || probe.length != FaceThresholds.embeddingDim) {
      return const MatchResult.none();
    }
    final dim = FaceThresholds.embeddingDim;
    if (flattened.length < count * dim) {
      throw ArgumentError(
          'Flattened bank too short: have ${flattened.length}, need ${count * dim}');
    }

    var bestIndex = -1;
    var bestSim = -2.0;
    for (var i = 0; i < count; i++) {
      final off = i * dim;
      var s = 0.0;
      for (var j = 0; j < dim; j++) {
        s += probe[j] * flattened[off + j];
      }
      if (s > bestSim) {
        bestSim = s;
        bestIndex = i;
      }
    }
    if (bestSim < threshold) return MatchResult.none();
    return MatchResult(index: bestIndex, similarity: bestSim);
  }
}
