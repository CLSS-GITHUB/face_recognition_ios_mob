import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../core/constants/thresholds.dart';
import '../core/error/failures.dart';
import '../core/utils/image_processing.dart';
import '../features/face_verification/domain/entities/face_data.dart';

/// MobileFaceNet 112×112 → 192-D embedding.
///
/// Mirrors FaceRecognizer.kt:
/// - Always align + (conditionally) enhance the crop.
/// - Normalize pixels with `(p - 127.5) / 127.5` → [-1, 1].
/// - L2-normalize the output.
///
/// The `fastPath` parameter from the Kotlin source is intentionally dropped
/// here. See `docs/migration/09_performance.md` §9.7.
class FaceRecognitionService {
  FaceRecognitionService._(this._interpreter);

  static const _modelAsset = 'assets/models/mobile_facenet.tflite';
  static final Logger _log = Logger('FaceRecognizer');

  final Interpreter _interpreter;

  static Future<FaceRecognitionService> load() async {
    try {
      final options = InterpreterOptions()..threads = FaceThresholds.tfliteThreads;
      final interpreter = await Interpreter.fromAsset(_modelAsset, options: options);
      return FaceRecognitionService._(interpreter);
    } catch (e, st) {
      _log.severe('Failed to load TFLite model', e, st);
      throw const TFLiteUnavailableError();
    }
  }

  /// Extracts a 192-D L2-normalized embedding from a face crop. The crop must
  /// already be on the appropriate face region (not the full frame).
  Future<Float32List> extractEmbedding(
    img.Image faceCrop,
    FaceData face,
  ) async {
    final aligned = ImageProcessing.alignAndMaybeEnhance(faceCrop, face);
    final resized = img.copyResize(aligned,
        width: FaceThresholds.inputSize,
        height: FaceThresholds.inputSize,
        interpolation: img.Interpolation.linear);

    final input = _imageToInput(resized);
    final output = List.generate(
      1,
      (_) => List<double>.filled(FaceThresholds.embeddingDim, 0),
    );

    _interpreter.run(input, output);

    final raw = Float32List.fromList(output[0].cast<double>());
    return _l2Normalize(raw);
  }

  void close() => _interpreter.close();

  // ---- helpers ---------------------------------------------------------

  /// 1×112×112×3 input tensor with `(p - 127.5) / 127.5` normalization.
  List<List<List<List<double>>>> _imageToInput(img.Image image) {
    final n = FaceThresholds.inputSize;
    final tensor = List.generate(
      1,
      (_) => List.generate(
        n,
        (_) => List.generate(n, (_) => List<double>.filled(3, 0)),
      ),
    );
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final p = image.getPixel(x, y);
        tensor[0][y][x][0] = (p.r - FaceThresholds.pixelMean) / FaceThresholds.pixelMean;
        tensor[0][y][x][1] = (p.g - FaceThresholds.pixelMean) / FaceThresholds.pixelMean;
        tensor[0][y][x][2] = (p.b - FaceThresholds.pixelMean) / FaceThresholds.pixelMean;
      }
    }
    return tensor;
  }

  static Float32List _l2Normalize(Float32List v) {
    var sumSq = 0.0;
    for (var i = 0; i < v.length; i++) sumSq += v[i] * v[i];
    final norm = sqrt(sumSq);
    if (norm < 1e-6) return v;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) out[i] = v[i] / norm;
    return out;
  }
}
