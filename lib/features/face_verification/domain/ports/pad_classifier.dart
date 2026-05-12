import 'dart:typed_data';

/// Narrow port the verify controller depends on for a passive
/// Presentation-Attack-Detection (PAD) verdict on the same 112×112 RGB
/// crop the embedding extractor already consumes.
///
/// **Stacked-gate policy.** The current implementation runs PAD AFTER a
/// successful match but BEFORE the grant lands — a high spoof score
/// vetoes the grant. PAD is purely *additive* security: it never lets
/// a user in that the existing pipeline would have denied. When no
/// model is bundled, the production wiring resolves to
/// [NoOpPadClassifier] which always reports "real" — the pipeline
/// behaves exactly as it did pre-PAD.
///
/// Score semantics: `0.0` = strongly real / live face, `1.0` = strongly
/// spoofed. Implementations should clamp to `[0, 1]`. Threshold comes
/// from `FaceThresholds.padSpoofThreshold` (default 0.5, placeholder
/// pending the calibration study documented in
/// `docs/verification/ultra_fast_verification_analysis.md` §9.4).
///
/// Failure handling: throw [PadUnavailableError] when the underlying
/// model can't be reached. Callers should treat that as "PAD has no
/// vote on this attempt" — never as "spoof".
abstract class PadClassifier {
  /// Returns a spoof score in `[0, 1]` for the given 112×112 RGB
  /// buffer. Implementations should be cheap enough to run inside the
  /// per-verify hot path (target: ≤ 15 ms on a Pixel-6 class device).
  Future<double> classify(Uint8List rgb112);

  /// Human-readable identifier for `/debug/health` and verification-log
  /// telemetry. Examples: `"noop"`, `"isolate(silent-face-anti-spoofing-v1)"`,
  /// `"unavailable"`. Stable across calls.
  String get label;
}

/// Default production wiring when no PAD checkpoint has been bundled.
/// Always reports `0.0` (real). The verify controller's grant path is
/// unaffected — PAD's vote is "no objection" on every attempt.
///
/// Field operators reading `/debug/health` will see `pad: noop`, which
/// is the signal that the security model is exactly what it was
/// pre-PAD-scaffold: the active liveness challenge + the existing
/// motion / screen-refl / device-motion / embedding-sanity stack.
class NoOpPadClassifier implements PadClassifier {
  const NoOpPadClassifier();

  @override
  Future<double> classify(Uint8List rgb112) async => 0.0;

  @override
  String get label => 'noop';
}
