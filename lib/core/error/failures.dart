/// Sealed error hierarchy for the face-verification feature.
/// Mirrors `04_api_mapping.md` §4.4.
sealed class FaceServiceError implements Exception {
  const FaceServiceError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class NoFaceDetectedError extends FaceServiceError {
  const NoFaceDetectedError() : super('No face detected');
}

class MultipleFacesError extends FaceServiceError {
  const MultipleFacesError()
      : super('Multiple faces detected. Only one person allowed.');
}

class QualityFailedError extends FaceServiceError {
  const QualityFailedError(this.issues) : super('Quality failed');
  final List<String> issues;
}

class EmbeddingFailedError extends FaceServiceError {
  const EmbeddingFailedError() : super('Embedding extraction failed');
}

class TFLiteUnavailableError extends FaceServiceError {
  const TFLiteUnavailableError() : super('TFLite interpreter unavailable');
}

/// Spawn or per-frame init of the embedding isolate failed (model load,
/// XNNPack init, sandbox / platform restriction). The controller should
/// fall back to inline TFLite — see architecture_recommendations.md §11.
class EmbeddingIsolateUnavailableError extends FaceServiceError {
  const EmbeddingIsolateUnavailableError(super.message);
}

/// `extract` was called while a previous extract is still in flight. The
/// isolate's queue length is 1 (drop-newer-when-busy) — see §3.3.
class EmbeddingBusyError extends FaceServiceError {
  const EmbeddingBusyError()
      : super('Embedding isolate is busy with a previous extract');
}

/// PAD (Presentation Attack Detection) inference failed or the PAD
/// pipeline is unavailable (no checkpoint bundled, isolate spawn
/// errored). The controller treats this as a soft failure — the active
/// liveness gates and existing anti-spoof stack still apply, so the
/// fall-through is to deny PAD's veto vote, not to reject the user.
class PadUnavailableError extends FaceServiceError {
  const PadUnavailableError(super.message);
}
