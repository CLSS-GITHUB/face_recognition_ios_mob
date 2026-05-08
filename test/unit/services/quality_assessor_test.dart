import 'dart:math';
import 'dart:ui';

import 'package:face_ios_android/features/face_verification/domain/entities/face_data.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/liveness_step.dart';
import 'package:face_ios_android/services/quality_assessor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

FaceData _face({
  Rect? bbox,
  double yaw = 0,
  double pitch = 0,
  double roll = 0,
  double? leftEye = 0.9,
  double? rightEye = 0.9,
}) =>
    FaceData(
      boundingBox: bbox ?? const Rect.fromLTWH(440, 600, 200, 200),
      landmarks: <FaceLandmarkType, Point<int>>{},
      headEulerX: pitch,
      headEulerY: yaw,
      headEulerZ: roll,
      leftEyeOpen: leftEye,
      rightEyeOpen: rightEye,
    );

void main() {
  const assessor = QualityAssessor();
  const frame = Size(1080, 1920);

  test('passes when face is well-lit, centered, frontal', () {
    final r = assessor.assess(_face(), frame, brightness: 150);
    expect(r.isGood, isTrue);
    expect(r.issues, isEmpty);
  });

  test('rejects when too dark', () {
    final r = assessor.assess(_face(), frame, brightness: 30);
    expect(r.isGood, isFalse);
    expect(r.issues.first, contains('dark'));
  });

  test('rejects when too bright', () {
    final r = assessor.assess(_face(), frame, brightness: 250);
    expect(r.isGood, isFalse);
    expect(r.issues.first, contains('bright'));
  });

  test('rejects when face too small', () {
    final tiny = const Rect.fromLTWH(500, 800, 80, 80); // ~0.3% of frame
    final r = assessor.assess(_face(bbox: tiny), frame, brightness: 150);
    expect(r.issues, contains('Face too small — move closer'));
  });

  test('rejects when face fills frame', () {
    final huge = const Rect.fromLTWH(0, 0, 1080, 1700);
    final r = assessor.assess(_face(bbox: huge), frame, brightness: 150);
    expect(r.issues, contains('Face too close — move back'));
  });

  test('rejects when off-center horizontally on a non-movement step', () {
    final off = const Rect.fromLTWH(50, 600, 200, 200);
    final r = assessor.assess(_face(bbox: off), frame,
        currentStep: LivenessStep.blink, brightness: 150);
    expect(r.issues, contains('Center your face in the frame'));
  });

  test('relaxes horizontal centering during TURN_LEFT', () {
    // ~25% offset from center → still within turning band (40%).
    final partlyOff = const Rect.fromLTWH(150, 600, 200, 200);
    final r = assessor.assess(_face(bbox: partlyOff), frame,
        currentStep: LivenessStep.turnLeft, brightness: 150);
    expect(r.isGood, isTrue);
  });

  test('rejects extreme yaw outside movement steps', () {
    final r = assessor.assess(_face(yaw: 30), frame,
        currentStep: LivenessStep.still, brightness: 150);
    expect(r.issues, contains('Look straight ahead'));
  });

  test('allows extreme yaw during TURN_LEFT step', () {
    final r = assessor.assess(_face(yaw: 30), frame,
        currentStep: LivenessStep.turnLeft, brightness: 150);
    expect(r.isGood, isTrue);
  });

  test('flags missing eye probability', () {
    final r = assessor.assess(
        _face(leftEye: null), frame, brightness: 150);
    expect(r.issues, contains('Eyes not clearly visible'));
  });
}
