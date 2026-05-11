import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../features/face_verification/domain/entities/face_data.dart';

/// Wraps Google ML Kit Face Detection. Mirrors the Android `FaceProcessor` +
/// `FaceAnalyzer`/`FaceDetector` combination: detect with the same accuracy
/// preset and turn the platform `Face` into our portable `FaceData`.
class FaceDetectionService {
  FaceDetectionService({FaceDetectorOptions? options})
      : _detector = FaceDetector(
          // `enableContours` was historically on, but no code path in this
          // tree consumes `face.contours` — it cost ~3 ms / frame on the
          // ML Kit side for output we never read. The OcclusionDetector
          // uses the 4-landmark coverage signal, not the contour ring.
          options: options ??
              FaceDetectorOptions(
                performanceMode: FaceDetectorMode.fast,
                enableLandmarks: true,
                enableClassification: true,
                enableTracking: true,
                minFaceSize: 0.10,
              ),
        );

  final FaceDetector _detector;

  Future<List<FaceData>> detect(InputImage image) async {
    final faces = await _detector.processImage(image);
    return faces.map(FaceData.fromMlKit).toList(growable: false);
  }

  Future<void> dispose() => _detector.close();
}
