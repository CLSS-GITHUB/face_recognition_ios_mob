import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins every numeric threshold against the Android baseline. Any change
/// to FaceThresholds requires an explicit test edit — that's the point.
/// Cross-reference: `docs/migration/01_project_analysis.md` §1.9.
void main() {
  group('FaceThresholds parity with Android baseline', () {
    test('embedding constants', () {
      expect(FaceThresholds.inputSize, 112);
      expect(FaceThresholds.embeddingDim, 192);
      expect(FaceThresholds.tfliteThreads, 4);
      expect(FaceThresholds.pixelMean, 127.5);
    });

    test('quality constants', () {
      expect(FaceThresholds.minBrightness, 45);
      expect(FaceThresholds.maxBrightness, 245);
      expect(FaceThresholds.centeringNormal, 0.30);
      expect(FaceThresholds.centeringTurning, 0.50);
      expect(FaceThresholds.yawLimit, 35);
      expect(FaceThresholds.pitchLimit, 35);
    });

    test('liveness constants', () {
      expect(FaceThresholds.eyeClosed, 0.25);
      expect(FaceThresholds.eyeOpen, 0.60);
      expect(FaceThresholds.yawTurn, 15);
      expect(FaceThresholds.mouthOpenEnter, 0.85);
      expect(FaceThresholds.mouthCloseExit, 0.75);
      expect(FaceThresholds.stillAngle, 5);
    });

    test('crop / save constants', () {
      expect(FaceThresholds.faceCropMargin, 0.25);
      expect(FaceThresholds.jpegQuality, 90);
    });

    test('matching thresholds', () {
      expect(FaceThresholds.verifyThreshold, 0.75);
      expect(FaceThresholds.reEnrollVerifyThreshold, 0.80);
      expect(FaceThresholds.duplicateFaceThreshold, 0.85);
      expect(FaceThresholds.templateDedupThreshold, 0.95);
    });

    test('retry & storage guards', () {
      expect(FaceThresholds.extractionRetryLimit, 150);
      expect(FaceThresholds.maxTemplatesPerUser, 1000);
      expect(FaceThresholds.maxArrayLength, 10000);
    });

    test('liveness step order is fixed', () {
      expect(
        FaceThresholds.livenessStepOrder,
        ['BLINK', 'MOUTH_OPEN', 'TURN_LEFT', 'TURN_RIGHT', 'STILL'],
      );
    });
  });
}
