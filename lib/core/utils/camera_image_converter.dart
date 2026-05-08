import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

/// Bridges `camera`'s `CameraImage` to ML Kit's `InputImage`.
///
/// Android — request `ImageFormatGroup.nv21` from the controller; the single
/// plane maps directly to NV21 bytes.
/// iOS — `ImageFormatGroup.bgra8888` is delivered as a single BGRA plane.
///
/// Returns `null` if the format is unsupported (e.g. the platform delivered
/// YUV_420_888 because NV21 wasn't honored — caller should reconfigure the
/// camera).
class CameraImageConverter {
  CameraImageConverter._();

  static InputImage? toInputImage(
    CameraImage image,
    CameraDescription camera,
    int sensorOrientation,
  ) {
    final rotation = _rotationFromCamera(camera, sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // ML Kit only accepts NV21 on Android and BGRA8888 on iOS as bytes.
    final bool acceptable = (Platform.isAndroid && format == InputImageFormat.nv21) ||
        (Platform.isIOS && format == InputImageFormat.bgra8888);
    if (!acceptable) return null;

    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  static InputImageRotation? _rotationFromCamera(
    CameraDescription camera,
    int sensorOrientation,
  ) {
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }
    // Android: front-camera mirrors, back-camera doesn't. The plugin already
    // accounts for sensor orientation; pass it through.
    return InputImageRotationValue.fromRawValue(sensorOrientation);
  }
}

/// Convert NV21 (Y plane interleaved with VU) to RGB Uint8List.
/// Used when we need pixel access (cropping, alignment, TFLite input).
class Nv21Decoder {
  Nv21Decoder._();

  /// Returns an RGB byte buffer of length `width * height * 3`.
  static Uint8List nv21ToRgb(Uint8List nv21, int width, int height) {
    final out = Uint8List(width * height * 3);
    final frameSize = width * height;
    var rgbIndex = 0;
    for (var y = 0; y < height; y++) {
      var uvp = frameSize + (y >> 1) * width;
      var u = 0, v = 0;
      for (var x = 0; x < width; x++) {
        final yp = y * width + x;
        var yv = (nv21[yp] & 0xFF) - 16;
        if (yv < 0) yv = 0;
        if ((x & 1) == 0) {
          v = (nv21[uvp++] & 0xFF) - 128;
          u = (nv21[uvp++] & 0xFF) - 128;
        }
        final y1192 = 1192 * yv;
        var r = y1192 + 1634 * v;
        var g = y1192 - 833 * v - 400 * u;
        var b = y1192 + 2066 * u;
        r = r.clamp(0, 262143);
        g = g.clamp(0, 262143);
        b = b.clamp(0, 262143);
        out[rgbIndex++] = (r >> 10) & 0xFF;
        out[rgbIndex++] = (g >> 10) & 0xFF;
        out[rgbIndex++] = (b >> 10) & 0xFF;
      }
    }
    return out;
  }
}
