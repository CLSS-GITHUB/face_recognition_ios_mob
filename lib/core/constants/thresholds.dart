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

  /// Identifies which face-recognition checkpoint produced a stored
  /// template. Bumped together with [embeddingDim] / `verifyThreshold`
  /// whenever the bundled `mobile_facenet.tflite` (or its replacement)
  /// changes. Templates whose stored `modelVersion` does not match this
  /// constant are excluded from the active matching bank — the
  /// corresponding users are flagged for re-enrolment instead of being
  /// silently compared in the wrong feature space.
  ///
  /// History:
  ///   1 — original 192-D MobileFaceNet shipped with v1.0 of the app.
  static const int modelVersion = 1;

  // Quality (QualityAssessor)
  static const double minBrightness = 45;
  static const double maxBrightness = 245;
  static const double centeringNormal = 0.30;
  static const double centeringTurning = 0.50;
  static const double yawLimit = 35;
  static const double pitchLimit = 35;

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

  /// Open-set safety margin: the *best* enrolled user's similarity must
  /// beat the *runner-up* enrolled user's similarity by at least this
  /// much before we grant. Prevents identity confusion when ≥ 3 users
  /// are enrolled and one unrelated user happens to land in the noisy
  /// 0.75–0.85 cosine band against the live probe (the gap between
  /// `verifyThreshold` and `duplicateFaceThreshold`). Calibrated against
  /// the MobileFaceNet 192-D embedding; do not weaken below 0.03.
  static const double verifyUserMargin = 0.04;

  /// Per-user upper bound on the number of templates scanned during
  /// matching. Newest templates win on overflow. Bounds the O(N·M·D)
  /// linear scan cost so latency stays flat as a user re-enrols.
  static const int maxTemplatesPerUserMatched = 8;

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

  // Verify-flow constants — added in v2 alongside the Verify Identity
  // pipeline. Source of truth: docs/verification/architecture_recommendations.md
  // §3.4. Any change here must update the parity test in the same commit.

  /// Maximum wall-clock for a single verification attempt before the
  /// controller transitions to `denied(reason: timeout)`.
  static const int verifyTimeoutMs = 12000;

  /// Watchdog: if no new camera frame arrives for this long, we treat the
  /// stream as stale and reset quality state.
  static const int frameStaleMs = 1500;

  /// Brightness floor specific to the verify flow ("Move to better
  /// lighting"). Slightly stricter than the enrol-time `minBrightness` (45)
  /// so we do not over-reject during quiet office light.
  static const int lowLightBrightness = 35;

  /// Required ML Kit landmarks present (left eye, right eye, nose base,
  /// bottom mouth). Below this count the OcclusionDetector raises a failure.
  static const int occlusionLandmarkMin = 4;

  /// Number of consecutive non-blink frames with both eye-open
  /// probabilities NULL before the eye-visibility heuristic rejects (e.g.
  /// sunglasses, persistent occlusion). Two frames at 30 fps ≈ 66 ms.
  static const int eyeVisibleConsecutiveFrames = 2;

  /// Bounding-box centroid std-dev (in pixels) over the last ~1 s rolling
  /// buffer. Below this floor for a sustained window means the face is
  /// frame-locked — reject as static-image / print spoof.
  static const double replayMotionMaxStdPx = 0.8;

  /// Lower bound paired with `replayMotionMaxStdPx` for the spoof window
  /// hysteresis (see architecture_recommendations.md §7.2).
  static const double replayMotionMinStdPx = 0.6;

  /// Allowed verification failures within one rate-limit window before the
  /// screen forces a cooldown.
  static const int rateLimitMaxFailures = 5;

  /// Sliding-window length used to count failures.
  static const int rateLimitWindowMs = 60000;

  /// Length of the forced cooldown shown to the user after exhaustion.
  static const int rateLimitCooldownMs = 30000;

  /// Default policy: do NOT require a mouth-open step for verification.
  /// High-security deployments flip this to true at boot.
  static const bool mouthOpenStepRequired = false;

  /// After this many consecutive denied attempts in a single screen entry,
  /// the controller fully resets the camera + isolate to recover from a
  /// stuck state.
  static const int verifyMaxAttemptsBeforeReset = 10;

  /// `verification_logs` retention window. Rows with `at < now - this` are
  /// deleted on every cold start (fire-and-forget, see
  /// `verificationLogPurgeProvider`). Keeps the local audit trail bounded
  /// without losing the recent history Manage Users displays.
  static const int verificationLogRetentionDays = 30;

  /// Maximum age, in days, that a stored face template is considered
  /// "fresh" for matching. Beyond this the owning user falls into the
  /// re-enrolment bucket (same UI surface as a model-version mismatch).
  /// Defeats slow drift: a face captured two years ago will diverge from
  /// the same person today even with no model change.
  static const int templateMaxAgeDays = 180;

  /// Maximum acceleration-magnitude std-dev (m/s²) over the device-
  /// motion rolling buffer below which the device is treated as
  /// stationary — typical for a phone-on-tripod replay. Calibrated
  /// above the raw IMU noise floor (~0.01 m/s²) and below the band of
  /// normal handheld tremor (~0.05–0.3 m/s²). Same semantic as
  /// [replayMotionMaxStdPx]: the *upper* bound that still counts as
  /// "no motion".
  static const double replayDeviceMotionMaxStd = 0.05;
}
