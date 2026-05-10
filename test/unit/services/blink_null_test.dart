import 'package:face_ios_android/features/face_verification/domain/entities/face_data.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/liveness_step.dart';
import 'package:face_ios_android/services/liveness_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:ui';

FaceData _face({
  double? leftEye = 0.9,
  double? rightEye = 0.9,
}) =>
    FaceData(
      boundingBox: const Rect.fromLTWH(0, 0, 100, 100),
      landmarks: const {},
      headEulerX: 0,
      headEulerY: 0,
      headEulerZ: 0,
      leftEyeOpen: leftEye,
      rightEyeOpen: rightEye,
    );

void main() {
  group('LivenessStateMachine Blink Null Handling', () {
    test('robust implementation: BLINK succeeds even if eyes go null when closed', () {
      final m = LivenessStateMachine();
      
      // 1. Initial state: eyes open
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      expect(m.currentStep, LivenessStep.blink);
      
      // 2. User blinks: ML Kit returns null for eye probabilities
      // Since we saw them OPEN, we now treat NULL as CLOSED.
      m.process(_face(leftEye: null, rightEye: null));
      
      // 3. User opens eyes: ML Kit returns 0.9
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      
      // It should now advance to MOUTH_OPEN
      expect(m.currentStep, LivenessStep.mouthOpen);
    });

    test('robust implementation: BLINK does NOT start on NULL', () {
      final m = LivenessStateMachine();
      
      // 1. Initial state: ML Kit returns NULL (maybe face just detected)
      // Since we HAVEN'T seen OPEN, we treat NULL as OPEN.
      m.process(_face(leftEye: null, rightEye: null));
      expect(m.currentStep, LivenessStep.blink);
      
      // 2. We see OPEN
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      
      // 3. We see NULL (CLOSED)
      m.process(_face(leftEye: null, rightEye: null));
      
      // 4. We see OPEN
      m.process(_face(leftEye: 0.9, rightEye: 0.9));
      
      expect(m.currentStep, LivenessStep.mouthOpen);
    });
  });
}
