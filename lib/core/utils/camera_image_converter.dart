import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    DeviceOrientation deviceOrientation,
  ) {
    final rotation = _rotationFromCamera(camera, deviceOrientation);
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

  /// Compute the rotation hint ML Kit needs to bring the image to its
  /// natural orientation.
  ///
  /// iOS — the camera plugin already reports a device-relative
  /// `sensorOrientation`, so pass it through.
  ///
  /// Android — combine the sensor orientation with the current device
  /// orientation, with sign depending on lens direction. Front cameras add,
  /// back cameras subtract. Mirrors the standard ML Kit Flutter sample. The
  /// previous "pass sensorOrientation through" implementation only worked
  /// when the device was held in portrait-up; any other orientation
  /// degraded ML Kit's classifier (eye-open / smiling probabilities) even
  /// though face detection itself stayed forgiving.
  static InputImageRotation? _rotationFromCamera(
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    }
    final degrees = androidRotationDegrees(
      sensorOrientation: camera.sensorOrientation,
      lensDirection: camera.lensDirection,
      deviceOrientation: deviceOrientation,
    );
    return InputImageRotationValue.fromRawValue(degrees);
  }

  /// Pure-compute helper for the Android rotation formula. Front cameras add
  /// the device orientation to the sensor orientation; back cameras subtract.
  /// Result is normalised to `[0, 360)`.
  @visibleForTesting
  static int androidRotationDegrees({
    required int sensorOrientation,
    required CameraLensDirection lensDirection,
    required DeviceOrientation deviceOrientation,
  }) {
    final device = _deviceOrientationDegrees(deviceOrientation);
    return lensDirection == CameraLensDirection.front
        ? (sensorOrientation + device) % 360
        : (sensorOrientation - device + 360) % 360;
  }

  static int _deviceOrientationDegrees(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return 0;
      case DeviceOrientation.landscapeLeft:
        return 90;
      case DeviceOrientation.portraitDown:
        return 180;
      case DeviceOrientation.landscapeRight:
        return 270;
    }
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
