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
