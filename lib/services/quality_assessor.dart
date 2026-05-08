import 'dart:ui';

import '../core/constants/thresholds.dart';
import '../features/face_verification/domain/entities/face_data.dart';
import '../features/face_verification/domain/entities/liveness_step.dart';
import '../features/face_verification/domain/entities/quality_result.dart';

/// Pure Dart port of QualityAssessor.kt. The same gates and thresholds are
/// applied; the only divergence is that we return a `QualityResult` value
/// object instead of mutating shared state.
///
/// Threshold sources are pinned in `core/constants/thresholds.dart`.
class QualityAssessor {
  const QualityAssessor();

  QualityResult assess(
    FaceData face,
    Size frame, {
    LivenessStep? currentStep,
    required double brightness,
  }) {
    final issues = <String>[];

    // 1. Brightness gate.
    if (brightness < FaceThresholds.minBrightness) {
      issues.add('Too dark — find better lighting');
    } else if (brightness > FaceThresholds.maxBrightness) {
      issues.add('Too bright — reduce glare');
    }

    // 2. Face size gate (4–70 % of frame area, matching Android's relaxed
    //    bounds for live previews).
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final frameArea = frame.width * frame.height;
    if (frameArea > 0) {
      final ratio = faceArea / frameArea;
      if (ratio < 0.04) {
        issues.add('Face too small — move closer');
      } else if (ratio > 0.70) {
        issues.add('Face too close — move back');
      }
    }

    // 3. Centering. Relax sideways during turn steps.
    final cx = face.boundingBox.center.dx;
    final cy = face.boundingBox.center.dy;
    final fxOffset = ((cx - frame.width / 2) / frame.width).abs();
    final fyOffset = ((cy - frame.height / 2) / frame.height).abs();
    final hThreshold = currentStep != null && currentStep.isMovement
        ? FaceThresholds.centeringTurning
        : FaceThresholds.centeringNormal;
    if (fxOffset > hThreshold || fyOffset > FaceThresholds.centeringNormal) {
      issues.add('Center your face in the frame');
    }

    // 4. Head pose limits — only outside movement steps.
    final isMovementStep = currentStep != null && currentStep.isMovement;
    if (!isMovementStep) {
      if (face.headEulerY.abs() > FaceThresholds.yawLimit ||
          face.headEulerX.abs() > FaceThresholds.pitchLimit) {
        issues.add('Look straight ahead');
      }
    }

    // 5. Eye visibility — required for the BLINK step in particular.
    if (face.leftEyeOpen == null || face.rightEyeOpen == null) {
      issues.add('Eyes not clearly visible');
    }

    return issues.isEmpty
        ? const QualityResult.ok()
        : QualityResult.failed(issues);
  }
}
