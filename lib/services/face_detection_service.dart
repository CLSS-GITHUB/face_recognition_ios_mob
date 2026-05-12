import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/services.dart' show MissingPluginException;
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

  /// O-7: forces ML Kit's native face-detection blob to load before the
  /// camera stream produces its first frame.
  ///
  /// On a cold app launch the first `processImage` call pays ~100-300 ms
  /// of native-side init (model load, JNI bridge warm-up, AOT codegen
  /// for the detector graph). Without this method, that cost lands on
  /// whichever frame happens to arrive first — usually right when the
  /// user is staring at the preview waiting for the face-tracking
  /// overlay to come alive. Triggering it during `verifyPrewarmProvider`
  /// instead overlaps the init with the route transition + camera
  /// `initialize` cost, so the first real frame's detect hits a hot
  /// detector.
  ///
  /// Best-effort: any exception (missing platform binding in tests,
  /// plugin not yet registered on a hot-restart edge) is swallowed.
  /// The live verify path constructs its own `InputImage` and calls
  /// `detect` again on the first real frame — a failed prewarm just
  /// means we forfeit the latency win for that launch, not that
  /// detection stops working.
  ///
  /// The synthetic image is a 256×256 all-zero buffer in the same wire
  /// format the camera plugin emits on this platform (NV21 on Android,
  /// BGRA8888 on iOS). A 0-pixel image trivially contains no face; the
  /// `processImage` call still runs the full native pipeline and ML
  /// Kit's cold-init lands inside it.
  Future<void> prewarm() async {
    try {
      final input = _syntheticInputImage();
      if (input == null) return;
      await _detector.processImage(input);
    } on MissingPluginException {
      // ML Kit's platform channel isn't bound — unit-test environment,
      // or a hot-restart edge where the engine is still wiring plugins.
      // No-op: prewarm is best-effort.
    } catch (_) {
      // Any other failure mode (malformed synthetic input on an
      // unexpected platform, native blob refused to load) is non-fatal.
      // The real-frame call path will surface it normally if it
      // persists, but the prewarm itself must never throw upward.
    }
  }

  Future<void> dispose() => _detector.close();

  /// Builds a small all-zero image in the wire format the live camera
  /// pipeline emits on this platform. Returns null on unsupported
  /// platforms so the prewarm short-circuits cleanly.
  ///
  /// 256×256 chosen to comfortably exceed ML Kit's internal minimum-
  /// resolution checks while staying small enough that the synthetic
  /// buffer allocates in <1 ms.
  static InputImage? _syntheticInputImage() {
    const side = 256;
    if (Platform.isAndroid) {
      // NV21 = Y plane (side*side) + interleaved VU plane (side*side/2).
      // All zeros = uniform black. bytesPerRow = stride = side.
      final bytes = Uint8List(side * side + side * side ~/ 2);
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(side.toDouble(), side.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: side,
        ),
      );
    }
    if (Platform.isIOS) {
      // BGRA8888 = 4 bytes per pixel. bytesPerRow = side*4.
      final bytes = Uint8List(side * side * 4);
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(side.toDouble(), side.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.bgra8888,
          bytesPerRow: side * 4,
        ),
      );
    }
    return null;
  }
}
