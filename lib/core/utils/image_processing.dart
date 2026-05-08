import 'dart:math';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../../features/face_verification/domain/entities/face_data.dart';

/// ImageQualityEngine.kt's enhance() pipeline, ported.
///
/// 1. Align: rotate so the inter-eye axis is horizontal.
/// 2. Histogram-equalize only when average luminance < 100 (matching the
///    Android threshold). Skipping the EQ on already-bright frames preserves
///    the embedding distribution.
class ImageProcessing {
  ImageProcessing._();

  static img.Image alignAndMaybeEnhance(
    img.Image faceCrop,
    FaceData face, {
    double brightnessThreshold = 100,
  }) {
    var out = _alignByEyes(faceCrop, face);
    final avg = _averageLuminance(out);
    if (avg < brightnessThreshold) {
      out = img.normalize(out, min: 0, max: 255);
    }
    return out;
  }

  static img.Image _alignByEyes(img.Image image, FaceData face) {
    final left = face.landmarks[FaceLandmarkType.leftEye];
    final right = face.landmarks[FaceLandmarkType.rightEye];
    if (left == null || right == null) return image;
    final dx = (right.x - left.x).toDouble();
    final dy = (right.y - left.y).toDouble();
    final angleRad = atan2(dy, dx);
    final angleDeg = angleRad * 180 / pi;
    if (angleDeg.abs() < 1) return image; // already vertical-ish
    return img.copyRotate(image, angle: -angleDeg);
  }

  static double _averageLuminance(img.Image image) {
    var sum = 0.0;
    var count = 0;
    for (var y = 0; y < image.height; y += 5) {
      for (var x = 0; x < image.width; x += 5) {
        final px = image.getPixel(x, y);
        sum += 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }
}
