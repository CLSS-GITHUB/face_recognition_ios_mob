import 'dart:math';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../core/constants/thresholds.dart';
import '../features/face_verification/domain/entities/face_data.dart';
import '../features/face_verification/domain/entities/liveness_step.dart';

/// Pure Dart port of LivenessDetector.kt. Sequence is fixed:
/// BLINK → MOUTH_OPEN → TURN_LEFT → TURN_RIGHT → STILL.
///
/// Drive with [process] on every quality-passing frame. Read [currentStep]
/// for UI; null means all steps complete. Listen via [onStepCompleted] /
/// [onAllStepsCompleted].
class LivenessStateMachine {
  LivenessStateMachine({
    this.onStepCompleted,
    this.onAllStepsCompleted,
  });

  static const _sequence = <LivenessStep>[
    LivenessStep.blink,
    LivenessStep.mouthOpen,
    LivenessStep.turnLeft,
    LivenessStep.turnRight,
    LivenessStep.still,
  ];

  void Function(LivenessStep step)? onStepCompleted;
  void Function()? onAllStepsCompleted;

  int _index = 0;
  bool _isBlinking = false;
  bool _isMouthOpen = false;

  LivenessStep? get currentStep =>
      _index >= _sequence.length ? null : _sequence[_index];

  int get completedCount => _index;
  int get totalSteps => _sequence.length;

  void reset() {
    _index = 0;
    _isBlinking = false;
    _isMouthOpen = false;
  }

  void process(FaceData face) {
    final step = currentStep;
    if (step == null) return;

    final advanced = switch (step) {
      LivenessStep.blink => _processBlink(face),
      LivenessStep.mouthOpen => _processMouthOpen(face),
      LivenessStep.turnLeft =>
        face.headEulerY > FaceThresholds.yawTurn,
      LivenessStep.turnRight =>
        face.headEulerY < -FaceThresholds.yawTurn,
      LivenessStep.still => face.headEulerY.abs() < FaceThresholds.stillAngle &&
          face.headEulerX.abs() < FaceThresholds.stillAngle,
    };

    if (advanced) {
      _index++;
      onStepCompleted?.call(step);
      if (_index >= _sequence.length) {
        onAllStepsCompleted?.call();
      }
    }
  }

  bool _processBlink(FaceData face) {
    final l = face.leftEyeOpen ?? 1.0;
    final r = face.rightEyeOpen ?? 1.0;
    if (l < FaceThresholds.eyeClosed && r < FaceThresholds.eyeClosed) {
      _isBlinking = true;
    } else if (_isBlinking &&
        l > FaceThresholds.eyeOpen &&
        r > FaceThresholds.eyeOpen) {
      _isBlinking = false;
      return true;
    }
    return false;
  }

  bool _processMouthOpen(FaceData face) {
    final ratio = _mouthOpenRatio(face);
    if (ratio == null) return false;
    if (!_isMouthOpen && ratio > FaceThresholds.mouthOpenEnter) {
      _isMouthOpen = true;
    } else if (_isMouthOpen && ratio < FaceThresholds.mouthCloseExit) {
      _isMouthOpen = false;
      return true;
    }
    return false;
  }

  /// nose-to-mouth distance / inter-eye distance — same heuristic as
  /// LivenessDetector.kt. Returns null if landmarks are missing.
  double? _mouthOpenRatio(FaceData face) {
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final nose = face.landmarks[FaceLandmarkType.noseBase];
    final mouth = face.landmarks[FaceLandmarkType.bottomMouth];
    if (leftEye == null || rightEye == null || nose == null || mouth == null) {
      return null;
    }
    final eyeDistance = _distance(leftEye, rightEye);
    if (eyeDistance < 20) return null;
    final noseToMouth = _distance(nose, mouth);
    final ratio = noseToMouth / eyeDistance;
    if (ratio < 0.3 || ratio > 1.5) return null;
    return ratio;
  }

  static double _distance(Point<int> a, Point<int> b) {
    final dx = (a.x - b.x).toDouble();
    final dy = (a.y - b.y).toDouble();
    return sqrt(dx * dx + dy * dy);
  }
}
