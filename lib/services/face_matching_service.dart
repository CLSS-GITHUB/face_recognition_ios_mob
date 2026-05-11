import 'dart:typed_data';

import '../core/constants/thresholds.dart';
import '../features/face_verification/domain/entities/match_result.dart';

/// Pure-Dart cosine similarity + best-match search.
///
/// Mirrors NativeFaceMatcher.kt's surface, with a Dart implementation.
/// Both inputs are assumed L2-normalized — the cosine reduces to a dot
/// product. The inner loops use `Float32x4` SIMD (dart:typed_data) so a
/// 192-D dot product is 48 fused-multiply-adds instead of 192. On a
/// 1000-template bank this keeps the linear scan well under 1 ms in AOT.
///
/// FFI acceleration is deferred (see docs/migration/09_performance.md §9.3).
class FaceMatchingService {
  const FaceMatchingService();

  /// Cosine similarity ∈ [-1, 1]. Both vectors must be L2-normalized.
  /// Falls back to a scalar loop when the lengths are not multiples of 4
  /// — in practice MobileFaceNet's 192-D output is always a multiple of 4
  /// so the SIMD path always wins.
  double cosine(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError(
          'Embedding lengths differ: ${a.length} vs ${b.length}');
    }
    return _dot(a, b);
  }

  /// Searches a flattened bank of [count] templates of length
  /// `FaceThresholds.embeddingDim` for the highest cosine similarity to
  /// [probe]. Returns `MatchResult.none()` when [count] is 0 or when no
  /// template clears [threshold].
  ///
  /// Kept for backward compatibility; the verify use case now calls
  /// [findBestUser] so it can apply an open-set margin check.
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
      final s = _dotOffset(probe, flattened, off, dim);
      if (s > bestSim) {
        bestSim = s;
        bestIndex = i;
      }
    }
    if (bestSim < threshold) return MatchResult.none();
    return MatchResult(index: bestIndex, similarity: bestSim);
  }

  /// Open-set best-user search.
  ///
  /// Scans every template in [flattened] (length `count * embeddingDim`)
  /// and groups similarities by **user**: `userOf[i]` is the unique-user
  /// index for the template at slot `i`. Returns the best user (by their
  /// *best* template) and the runner-up user's best similarity. The
  /// caller compares the gap against [FaceThresholds.verifyUserMargin]
  /// to reject identity confusions before granting.
  ///
  /// - When `count == 0` or the probe is malformed → "none" result.
  /// - When only one unique user is enrolled, [runnerUpSimilarity]
  ///   defaults to `-1.0` so the margin check always passes (single-user
  ///   deployments are effectively closed-set against that user).
  UserMatchResult findBestUser(
    Float32List probe,
    Float32List flattened,
    Int32List userOf,
    int count, {
    required int uniqueUserCount,
  }) {
    // ------------------------------------------------------------------
    // Defensive entry guards. These are cheap and never throw — a bad
    // bank should return "none" so the caller logs `noMatch` and the UI
    // stays responsive instead of crashing the screen.
    // ------------------------------------------------------------------
    if (count <= 0 ||
        uniqueUserCount <= 0 ||
        probe.length != FaceThresholds.embeddingDim ||
        userOf.length < count) {
      return const UserMatchResult.none();
    }
    final dim = FaceThresholds.embeddingDim;
    if (flattened.length < count * dim) {
      return const UserMatchResult.none();
    }

    // Per-user "best similarity so far" accumulator. Initialised to
    // -2.0 (one below the cosine floor) so the first template for any
    // user always wins its slot.
    final perUserBest = Float32List(uniqueUserCount);
    for (var i = 0; i < uniqueUserCount; i++) {
      perUserBest[i] = -2.0;
    }

    // Hot loop. Each iteration is a 192-D dot product (~48 SIMD FMAs
    // when the dim is a multiple of 4). We do NOT short-circuit on a
    // hit — every template must be scored so we can compute the
    // runner-up margin.
    for (var i = 0; i < count; i++) {
      final off = i * dim;
      final s = _dotOffset(probe, flattened, off, dim);
      final uid = userOf[i];
      // Guard against a corrupt index — silently skip rather than crash.
      if (uid < 0 || uid >= uniqueUserCount) continue;
      if (s > perUserBest[uid]) {
        perUserBest[uid] = s;
      }
    }

    // Find best and runner-up across users. Two passes would be cleaner
    // but uniqueUserCount is small (≤ tens), so a single pass with two
    // accumulators is fine and avoids extra allocation.
    var bestIdx = -1;
    var bestSim = -2.0;
    var runnerSim = -2.0;
    for (var u = 0; u < uniqueUserCount; u++) {
      final s = perUserBest[u];
      if (s > bestSim) {
        runnerSim = bestSim;
        bestSim = s;
        bestIdx = u;
      } else if (s > runnerSim) {
        runnerSim = s;
      }
    }

    // Single-user deployments (or unique count of 1 after dedup) get a
    // synthetic runner-up of -1 so the margin check at the call site
    // can stay symmetric without a separate code path.
    if (uniqueUserCount < 2) {
      runnerSim = -1.0;
    }

    if (bestIdx < 0) return const UserMatchResult.none();
    return UserMatchResult(
      userIndex: bestIdx,
      bestSimilarity: bestSim,
      runnerUpSimilarity: runnerSim,
    );
  }

  // -------------------------------------------------------------- math --

  /// `a · b` for two equally sized vectors. Public-facing wrapper.
  static double _dot(Float32List a, Float32List b) {
    return _dotOffset(a, b, 0, a.length);
  }

  /// `a · b[off:off+len]`. Uses Float32x4 SIMD for the bulk of the
  /// vector (`len ~/ 4 * 4` elements) and finishes any remainder with a
  /// scalar tail. The bank is always aligned to the embedding dim so
  /// the tail is empty in practice, but the fallback keeps the math
  /// honest if a caller ever passes an odd-sized vector.
  static double _dotOffset(
    Float32List a,
    Float32List b,
    int off,
    int len,
  ) {
    final blockEnd = len - (len & 3);
    var acc = Float32x4.zero();
    // Float32x4List view over the existing bytes — no copy.
    final aSimd = a.buffer.asFloat32x4List(a.offsetInBytes, len ~/ 4);
    final bSimd = b.buffer.asFloat32x4List(
      b.offsetInBytes + off * 4,
      len ~/ 4,
    );
    final lanes = blockEnd >> 2;
    for (var i = 0; i < lanes; i++) {
      acc += aSimd[i] * bSimd[i];
    }
    var s = acc.x + acc.y + acc.z + acc.w;
    for (var i = blockEnd; i < len; i++) {
      s += a[i] * b[off + i];
    }
    return s;
  }
}
