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
      // Centered on the 1080x1920 frame; 300x300 = 4.34% face area, just
      // above the 4% face-too-small gate.
      boundingBox: bbox ?? const Rect.fromLTWH(390, 810, 300, 300),
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
    // 300x300 keeps face area above the 4% gate.
    final partlyOff = const Rect.fromLTWH(120, 810, 300, 300);
    final r = assessor.assess(_face(bbox: partlyOff), frame,
        currentStep: LivenessStep.turnLeft, brightness: 150);
    expect(r.isGood, isTrue);
  });

  test('rejects extreme yaw outside movement steps', () {
    // yawLimit = 35°; use a value clearly above it. The Kotlin baseline
    // used a 25° limit, which is why this test originally expected 30°
    // to trip — the Dart port relaxed the limit to 35° to match real
    // ML Kit yaw noise on front cameras.
    final r = assessor.assess(_face(yaw: 40), frame,
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

  test('does not flag missing eye probability during BLINK step', () {
    final r = assessor.assess(_face(leftEye: null, rightEye: null), frame,
        currentStep: LivenessStep.blink, brightness: 150);
    expect(r.issues, isNot(contains('Eyes not clearly visible')));
    expect(r.isGood, isTrue);
  });
}
