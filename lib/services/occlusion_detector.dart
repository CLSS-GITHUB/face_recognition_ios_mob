import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../core/constants/thresholds.dart';
import '../features/face_verification/domain/entities/face_data.dart';
import '../features/face_verification/domain/entities/liveness_step.dart';

/// Reasons why the OcclusionDetector rejects a frame. Surfaced to the
/// controller as part of `VerificationFailure` so the UI can show a specific
/// instruction ("Eyes not clearly visible", "Remove anything covering your
/// face").
enum OcclusionReason {
  /// Fewer than `FaceThresholds.occlusionLandmarkMin` of the required ML Kit
  /// landmarks (left eye, right eye, nose base, bottom mouth) are present.
  /// Common cause: scarf or hand covering the lower face.
  insufficientLandmarks,

  /// In the non-blink phase, both eye-open probabilities have been NULL for
  /// `FaceThresholds.eyeVisibleConsecutiveFrames` consecutive frames. Common
  /// cause: sunglasses.
  eyesNotVisible,
}

/// Mutable per-attempt counter consumed by the (otherwise stateless)
/// `OcclusionDetector`. The controller owns the instance and resets it when
/// the screen disposes or the attempt restarts.
class OcclusionState {
  int _consecutiveEyeMissing = 0;

  int get consecutiveEyeMissing => _consecutiveEyeMissing;

  void recordEyeVisibility({required bool eyesMissing}) {
    if (eyesMissing) {
      _consecutiveEyeMissing++;
    } else {
      _consecutiveEyeMissing = 0;
    }
  }

  void reset() {
    _consecutiveEyeMissing = 0;
  }
}

/// Pure-Dart occlusion gate. See
/// `docs/verification/architecture_recommendations.md` §3.6.
///
/// v1 implements two cheap heuristics on signals that are already in
/// [FaceData]:
///   1. **Landmark coverage** — count of required ML Kit landmarks present.
///   2. **Eye visibility** — outside the BLINK liveness step, both
///      `leftEyeOpen` and `rightEyeOpen` must be non-null for at least
///      `eyeVisibleConsecutiveFrames` consecutive frames. ML Kit returns
///      null when classifier confidence is low; a sustained null is a strong
///      signal for sunglasses or other persistent occlusion.
///
/// The contour-coverage and bbox-vs-oval heuristics described in the
/// architecture doc are deferred to a follow-up slice that adds
/// `face.contours` to [FaceData].
class OcclusionDetector {
  const OcclusionDetector();

  static const Set<FaceLandmarkType> requiredLandmarks = <FaceLandmarkType>{
    FaceLandmarkType.leftEye,
    FaceLandmarkType.rightEye,
    FaceLandmarkType.noseBase,
    FaceLandmarkType.bottomMouth,
  };

  /// Returns `null` when the frame is fine, or an [OcclusionReason] when the
  /// frame should be rejected.
  ///
  /// `currentStep` may be `null` while the controller is still in the
  /// pre-liveness scanning phase; we treat that as "not in BLINK" so the
  /// eye-visibility check still applies — covering the eyes before liveness
  /// even starts is the simplest spoof.
  OcclusionReason? assess(
    FaceData face,
    OcclusionState state, {
    LivenessStep? currentStep,
  }) {
    final presentRequired =
        face.landmarks.keys.where(requiredLandmarks.contains).length;
    if (presentRequired < FaceThresholds.occlusionLandmarkMin) {
      return OcclusionReason.insufficientLandmarks;
    }

    final inBlink = currentStep == LivenessStep.blink;
    if (inBlink) {
      // ML Kit legitimately returns null eye-open during a blink — don't
      // accumulate. Reset so we don't carry a stale count out of BLINK.
      state.reset();
      return null;
    }

    final eyesMissing = face.leftEyeOpen == null || face.rightEyeOpen == null;
    state.recordEyeVisibility(eyesMissing: eyesMissing);
    if (state.consecutiveEyeMissing >=
        FaceThresholds.eyeVisibleConsecutiveFrames) {
      return OcclusionReason.eyesNotVisible;
    }
    return null;
  }
}
