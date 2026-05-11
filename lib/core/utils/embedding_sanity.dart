import 'dart:math';
import 'dart:typed_data';

/// Validates and L2-normalises a raw face embedding before it reaches
/// the matcher. Throws [StateError] when the raw vector is degenerate
/// — NaN/Inf anywhere, or a magnitude below [_degenerateNormFloor].
///
/// Why throw instead of return-an-empty-vector: a silently-degenerate
/// embedding will produce ~zero cosine against every template, so the
/// matcher would emit a misleading "no match" outcome. Throwing maps
/// (via the isolate's wire protocol) to `EmbeddingFailedError` → the
/// VerifyUser use case logs the attempt as `extractionFailed`, which
/// keeps tuning telemetry honest and surfaces the *real* failure mode
/// (model glitch, bad frame) instead of burying it as a regular deny.
///
/// Caller-side note: any normal Object thrown inside the isolate's
/// worker is caught at the top of the message loop and turned into an
/// `_ExtractFailure`; that's also why we don't need a bespoke error
/// type here.
class EmbeddingSanity {
  EmbeddingSanity._();

  /// Inputs smaller than this in L2 magnitude are treated as degenerate
  /// (no information). 1e-6 matches the floor previously used inline in
  /// the isolate; it sits comfortably below any plausible MobileFaceNet
  /// pre-normalisation magnitude (real outputs are O(10s)).
  static const double _degenerateNormFloor = 1e-6;

  /// Returns a fresh L2-normalised copy of [raw]. Throws on degenerate
  /// input — callers should let the throw propagate so the failure
  /// reaches the verify-log as `extractionFailed` instead of `noMatch`.
  static Float32List sanitizeAndNormalize(Float32List raw) {
    var sumSq = 0.0;
    for (var i = 0; i < raw.length; i++) {
      final x = raw[i];
      if (x.isNaN || x.isInfinite) {
        // Refuse the embedding rather than silently producing a NaN
        // cosine downstream. Index is included in the message so a
        // device-specific crash is debuggable from the log.
        throw StateError(
          'Embedding contains NaN/Inf at index $i — degenerate inference.',
        );
      }
      sumSq += x * x;
    }
    final norm = sqrt(sumSq);
    if (norm < _degenerateNormFloor) {
      throw StateError(
        'Embedding norm $norm below $_degenerateNormFloor floor — '
        'degenerate inference.',
      );
    }
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      out[i] = raw[i] / norm;
    }
    return out;
  }
}
