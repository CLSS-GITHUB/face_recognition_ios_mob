import 'dart:math';
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Internal value-object mirroring FaceData.kt. Created from an ML Kit `Face`
/// via [FaceData.fromMlKit] so the rest of the pipeline never sees the
/// platform type directly.
class FaceData {
  const FaceData({
    required this.boundingBox,
    required this.landmarks,
    required this.headEulerX,
    required this.headEulerY,
    required this.headEulerZ,
    this.leftEyeOpen,
    this.rightEyeOpen,
    this.smiling,
  });

  final Rect boundingBox;
  final Map<FaceLandmarkType, Point<int>> landmarks;
  final double headEulerX; // pitch
  final double headEulerY; // yaw
  final double headEulerZ; // roll
  final double? leftEyeOpen;
  final double? rightEyeOpen;
  final double? smiling;

  factory FaceData.fromMlKit(Face face) {
    final lm = <FaceLandmarkType, Point<int>>{};
    for (final entry in face.landmarks.entries) {
      final p = entry.value?.position;
      if (p != null) lm[entry.key] = p;
    }
    return FaceData(
      boundingBox: face.boundingBox,
      landmarks: lm,
      headEulerX: face.headEulerAngleX ?? 0,
      headEulerY: face.headEulerAngleY ?? 0,
      headEulerZ: face.headEulerAngleZ ?? 0,
      leftEyeOpen: face.leftEyeOpenProbability,
      rightEyeOpen: face.rightEyeOpenProbability,
      smiling: face.smilingProbability,
    );
  }
}
