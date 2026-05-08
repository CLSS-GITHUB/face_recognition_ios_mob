/// Single source of truth for every numeric threshold ported from the Android
/// Native baseline. Pinned in `test/unit/core/thresholds_parity_test.dart`.
/// Cross-reference: `docs/migration/01_project_analysis.md` §1.9.
class FaceThresholds {
  FaceThresholds._();

  // Embedding
  static const int inputSize = 112;
  static const int embeddingDim = 192;
  static const int tfliteThreads = 4;
  static const double pixelMean = 127.5;

  // Quality (QualityAssessor)
  static const double minBrightness = 45;
  static const double maxBrightness = 245;
  static const double centeringNormal = 0.20;
  static const double centeringTurning = 0.40;
  static const double yawLimit = 25;
  static const double pitchLimit = 25;

  // Liveness
  static const double eyeClosed = 0.25;
  static const double eyeOpen = 0.60;
  static const double yawTurn = 15;
  static const double mouthOpenEnter = 0.85;
  static const double mouthCloseExit = 0.75;
  static const double stillAngle = 5;

  // Crop & save
  static const double faceCropMargin = 0.25;
  static const int jpegQuality = 90;

  // Matching
  static const double verifyThreshold = 0.75;
  static const double reEnrollVerifyThreshold = 0.80;
  static const double duplicateFaceThreshold = 0.85;
  static const double templateDedupThreshold = 0.95;

  // Retry
  static const int extractionRetryLimit = 150;

  // Storage guards (mirror Converters.kt)
  static const int maxTemplatesPerUser = 1000;
  static const int maxArrayLength = 10000;

  // Liveness step order — fixed sequence from LivenessDetector.kt
  static const List<String> livenessStepOrder = [
    'BLINK',
    'MOUTH_OPEN',
    'TURN_LEFT',
    'TURN_RIGHT',
    'STILL',
  ];
}
