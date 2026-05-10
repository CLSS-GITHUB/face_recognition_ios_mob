import 'dart:math';
import 'dart:ui';

import 'package:face_ios_android/features/face_verification/domain/entities/face_data.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/liveness_step.dart';
import 'package:face_ios_android/services/occlusion_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

FaceData _face({
  Set<FaceLandmarkType> presentLandmarks = const <FaceLandmarkType>{
    FaceLandmarkType.leftEye,
    FaceLandmarkType.rightEye,
    FaceLandmarkType.noseBase,
    FaceLandmarkType.bottomMouth,
  },
  double? leftEye = 0.9,
  double? rightEye = 0.9,
}) {
  final lm = <FaceLandmarkType, Point<int>>{
    for (final t in presentLandmarks) t: const Point<int>(100, 100),
  };
  return FaceData(
    boundingBox: const Rect.fromLTWH(390, 810, 300, 300),
    landmarks: lm,
    headEulerX: 0,
    headEulerY: 0,
    headEulerZ: 0,
    leftEyeOpen: leftEye,
    rightEyeOpen: rightEye,
  );
}

void main() {
  const detector = OcclusionDetector();

  group('OcclusionDetector — landmark coverage', () {
    test('passes when all four required landmarks are present', () {
      final r = detector.assess(_face(), OcclusionState());
      expect(r, isNull);
    });

    test('rejects when fewer than four required landmarks are present', () {
      final r = detector.assess(
        _face(presentLandmarks: const <FaceLandmarkType>{
          FaceLandmarkType.leftEye,
          FaceLandmarkType.rightEye,
        }),
        OcclusionState(),
      );
      expect(r, OcclusionReason.insufficientLandmarks);
    });

    test('extra non-required landmarks do not change the verdict', () {
      // leftEar / rightEar are not in the required set; presence is fine,
      // but they cannot rescue an under-covered face.
      final r = detector.assess(
        _face(presentLandmarks: const <FaceLandmarkType>{
          FaceLandmarkType.leftEye,
          FaceLandmarkType.leftEar,
          FaceLandmarkType.rightEar,
        }),
        OcclusionState(),
      );
      expect(r, OcclusionReason.insufficientLandmarks);
    });
  });

  group('OcclusionDetector — eye visibility', () {
    test('single null-eye frame is tolerated (below threshold)', () {
      final state = OcclusionState();
      final r = detector.assess(
        _face(leftEye: null, rightEye: null),
        state,
        currentStep: LivenessStep.still,
      );
      expect(r, isNull, reason: 'first null-eye frame must not reject');
      expect(state.consecutiveEyeMissing, 1);
    });

    test('two consecutive null-eye frames in non-blink phase reject', () {
      final state = OcclusionState();
      detector.assess(
        _face(leftEye: null, rightEye: null),
        state,
        currentStep: LivenessStep.still,
      );
      final r = detector.assess(
        _face(leftEye: null, rightEye: null),
        state,
        currentStep: LivenessStep.still,
      );
      expect(r, OcclusionReason.eyesNotVisible);
    });

    test('null-eye during BLINK phase is allowed and resets the counter', () {
      final state = OcclusionState();
      // Build up one strike outside blink…
      detector.assess(
        _face(leftEye: null, rightEye: null),
        state,
        currentStep: LivenessStep.still,
      );
      expect(state.consecutiveEyeMissing, 1);

      // …a blink-step frame with null eyes must not advance the counter.
      final r = detector.assess(
        _face(leftEye: null, rightEye: null),
        state,
        currentStep: LivenessStep.blink,
      );
      expect(r, isNull);
      expect(state.consecutiveEyeMissing, 0,
          reason: 'BLINK step resets the eye-visibility counter');
    });

    test('eye-open returning resets the counter', () {
      final state = OcclusionState();
      detector.assess(
        _face(leftEye: null, rightEye: null),
        state,
        currentStep: LivenessStep.still,
      );
      detector.assess(
        _face(leftEye: 0.9, rightEye: 0.9),
        state,
        currentStep: LivenessStep.still,
      );
      expect(state.consecutiveEyeMissing, 0);
    });

    test('only one eye null still advances the counter', () {
      final state = OcclusionState();
      detector.assess(
        _face(leftEye: null, rightEye: 0.9),
        state,
        currentStep: LivenessStep.still,
      );
      final r = detector.assess(
        _face(leftEye: null, rightEye: 0.9),
        state,
        currentStep: LivenessStep.still,
      );
      expect(r, OcclusionReason.eyesNotVisible);
    });

    test('null currentStep is treated as not-blink (pre-liveness phase)', () {
      final state = OcclusionState();
      detector.assess(_face(leftEye: null, rightEye: null), state);
      final r = detector.assess(_face(leftEye: null, rightEye: null), state);
      expect(r, OcclusionReason.eyesNotVisible);
    });
  });

  test('landmark failure short-circuits before the eye check runs', () {
    // No required landmarks present + null eyes — landmark reason wins.
    final state = OcclusionState();
    final r = detector.assess(
      _face(
        presentLandmarks: const <FaceLandmarkType>{},
        leftEye: null,
        rightEye: null,
      ),
      state,
      currentStep: LivenessStep.still,
    );
    expect(r, OcclusionReason.insufficientLandmarks);
    // Counter must not advance when landmark gate already failed.
    expect(state.consecutiveEyeMissing, 0);
  });
}
