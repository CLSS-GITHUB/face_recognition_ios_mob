import 'dart:math';
import 'dart:ui';

import 'package:face_ios_android/features/face_verification/domain/entities/face_data.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/liveness_step.dart';
import 'package:face_ios_android/services/liveness_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

FaceData _face({
  double yaw = 0,
  double pitch = 0,
  double? leftEye = 0.9,
  double? rightEye = 0.9,
  Map<FaceLandmarkType, Point<int>>? landmarks,
}) =>
    FaceData(
      boundingBox: const Rect.fromLTWH(0, 0, 100, 100),
      landmarks: landmarks ?? const {},
      headEulerX: pitch,
      headEulerY: yaw,
      headEulerZ: 0,
      leftEyeOpen: leftEye,
      rightEyeOpen: rightEye,
    );

void main() {
  group('LivenessStateMachine', () {
    test('starts at BLINK', () {
      expect(LivenessStateMachine().currentStep, LivenessStep.blink);
    });

    test('BLINK advances on open→close→open transition', () {
      // The state machine (and the production VerificationController)
      // require seeing open eyes *first* before a close→open edge is
      // counted as a blink — this prevents users who arrive with their
      // eyes closed from accidentally advancing the FSM as soon as
      // ML Kit reports their eyes opening. Drive the full sequence.
      final m = LivenessStateMachine();
      m.process(_face(leftEye: 0.9, rightEye: 0.9)); // baseline: open
      m.process(_face(leftEye: 0.2, rightEye: 0.2)); // close
      expect(m.currentStep, LivenessStep.blink);
      m.process(_face(leftEye: 0.9, rightEye: 0.9)); // open again → advance
      expect(m.currentStep, LivenessStep.mouthOpen);
    });

    test('BLINK does not advance on partial closure', () {
      final m = LivenessStateMachine();
      m.process(_face(leftEye: 0.5, rightEye: 0.5));
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      expect(m.currentStep, LivenessStep.blink);
    });

    test('TURN_LEFT advances on yaw > 15', () {
      final m = LivenessStateMachine()..reset();
      // Drive a real open→close→open blink (the FSM requires the
      // leading open frame — see the dedicated blink test above).
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      m.process(_face(leftEye: 0.2, rightEye: 0.2));
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      // Now at MOUTH_OPEN — fake landmarks to satisfy the ratio.
      final landmarks = <FaceLandmarkType, Point<int>>{
        FaceLandmarkType.leftEye: const Point(0, 0),
        FaceLandmarkType.rightEye: const Point(50, 0),
        FaceLandmarkType.noseBase: const Point(25, 25),
        FaceLandmarkType.bottomMouth: const Point(25, 70), // ratio = 45/50 = 0.9
      };
      m.process(_face(landmarks: landmarks));
      // Now close mouth — ratio drops below 0.75
      final closed = <FaceLandmarkType, Point<int>>{
        FaceLandmarkType.leftEye: const Point(0, 0),
        FaceLandmarkType.rightEye: const Point(50, 0),
        FaceLandmarkType.noseBase: const Point(25, 25),
        FaceLandmarkType.bottomMouth: const Point(25, 60), // ratio = 35/50 = 0.7
      };
      m.process(_face(landmarks: closed));
      expect(m.currentStep, LivenessStep.turnLeft);
      m.process(_face(yaw: 20));
      expect(m.currentStep, LivenessStep.turnRight);
    });

    test('reset() returns to step 0', () {
      final m = LivenessStateMachine();
      // Full open→close→open blink to advance past BLINK.
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      m.process(_face(leftEye: 0.2, rightEye: 0.2));
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      expect(m.currentStep, isNot(LivenessStep.blink));
      m.reset();
      expect(m.currentStep, LivenessStep.blink);
      expect(m.completedCount, 0);
    });

    test('onStepCompleted fires once per step', () {
      final completed = <LivenessStep>[];
      final m = LivenessStateMachine(
        onStepCompleted: completed.add,
      );
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      m.process(_face(leftEye: 0.2, rightEye: 0.2));
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      expect(completed, [LivenessStep.blink]);
    });

    test('onAllStepsCompleted fires once after final step', () {
      var fired = 0;
      final m = LivenessStateMachine(onAllStepsCompleted: () => fired++);
      // Drive each step in turn. Blink stage needs the full
      // open→close→open trio so the FSM's "saw open first" gate is
      // honoured (see the dedicated blink-advance test).
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      m.process(_face(leftEye: 0.2, rightEye: 0.2));
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      final lmOpen = <FaceLandmarkType, Point<int>>{
        FaceLandmarkType.leftEye: const Point(0, 0),
        FaceLandmarkType.rightEye: const Point(50, 0),
        FaceLandmarkType.noseBase: const Point(25, 25),
        FaceLandmarkType.bottomMouth: const Point(25, 70),
      };
      final lmClose = <FaceLandmarkType, Point<int>>{
        FaceLandmarkType.leftEye: const Point(0, 0),
        FaceLandmarkType.rightEye: const Point(50, 0),
        FaceLandmarkType.noseBase: const Point(25, 25),
        FaceLandmarkType.bottomMouth: const Point(25, 60),
      };
      m.process(_face(landmarks: lmOpen));
      m.process(_face(landmarks: lmClose));
      m.process(_face(yaw: 20));
      m.process(_face(yaw: -20));
      m.process(_face(yaw: 0, pitch: 0));
      expect(fired, 1);
      expect(m.currentStep, isNull);
    });
  });
}
