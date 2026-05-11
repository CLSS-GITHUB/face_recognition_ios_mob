import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/face_verification/domain/entities/face_data.dart';
import '../constants/thresholds.dart';
import 'image_processing.dart';

/// Pure-Dart port of BitmapUtils.kt:
/// - cropFace with 25% margin
/// - saveJpeg into `<appDocs>/user_faces/`
class BitmapUtils {
  BitmapUtils._();

  /// Crops the face region with [marginPercent] padding (default 25%, matching
  /// Android). The bbox is clamped to the source image bounds.
  static img.Image cropFace(
    img.Image source,
    ui.Rect bbox, {
    double marginPercent = FaceThresholds.faceCropMargin,
  }) {
    final mx = (bbox.width * marginPercent).round();
    final my = (bbox.height * marginPercent).round();
    final x = (bbox.left.round() - mx).clamp(0, source.width - 1);
    final y = (bbox.top.round() - my).clamp(0, source.height - 1);
    final w = (bbox.width.round() + 2 * mx).clamp(1, source.width - x);
    final h = (bbox.height.round() + 2 * my).clamp(1, source.height - y);
    return img.copyCrop(source, x: x, y: y, width: w, height: h);
  }

  /// Encodes the bitmap as JPEG (quality matching Android) and saves to
  /// `<appDocs>/user_faces/<fileName>.jpg`. Returns the absolute path.
  static Future<String> saveJpeg(img.Image bitmap, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final faces = Directory(p.join(dir.path, 'user_faces'));
    if (!faces.existsSync()) faces.createSync(recursive: true);
    final file = File(p.join(faces.path, '$fileName.jpg'));
    final bytes = img.encodeJpg(bitmap, quality: FaceThresholds.jpegQuality);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Average luminance (BT.601) over a sparse grid. Mirrors FaceAnalyzer.kt's
  /// "every 5th pixel" sampling.
  static double averageLuminance(img.Image image, {int step = 5}) {
    var sum = 0.0;
    var count = 0;
    for (var y = 0; y < image.height; y += step) {
      for (var x = 0; x < image.width; x += step) {
        final px = image.getPixel(x, y);
        sum += 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  /// Convert NV21 / RGB raw bytes to an `image.Image` for downstream
  /// processing.
  static img.Image rgbBytesToImage(Uint8List rgb, int width, int height) {
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgb.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
  }

  /// Crop → align → maybe-enhance → resize 112×112 → flatten to RGB bytes.
  /// Produces the exact byte layout `EmbeddingIsolate.extract` and
  /// `FaceRecognitionService.extractEmbedding` consume (37,632 bytes for
  /// the default 112×112 input). Shared between the verify and enrol
  /// pipelines so a probe and a stored template can only diverge through
  /// model output, never through preprocessing drift.
  static Uint8List buildExtractorPayload(img.Image source, FaceData face) {
    final crop = cropFace(source, face.boundingBox);
    final aligned = ImageProcessing.alignAndMaybeEnhance(crop, face);
    final resized = img.copyResize(
      aligned,
      width: FaceThresholds.inputSize,
      height: FaceThresholds.inputSize,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(
      resized.getBytes(order: img.ChannelOrder.rgb),
    );
  }
}
