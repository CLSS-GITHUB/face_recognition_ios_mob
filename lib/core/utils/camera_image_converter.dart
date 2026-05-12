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
  ///
  /// F-9 (lite): optimised over the original scalar loop with
  ///   * **2-pixel inner unroll**: each iteration consumes one UV pair
  ///     and emits two RGB triples, eliminating the per-pixel `(x & 1)`
  ///     branch and the `if-else UV fetch` ladder.
  ///   * **UV-contribution hoist**: `1634·V`, `-833·V`, `-400·U`,
  ///     `2066·U` are computed once per UV pair instead of twice; only
  ///     `1192·Y` is per-pixel.
  ///   * **Per-row loop-invariant lifting**: `y * width`, `(y >> 1) *
  ///     width + frameSize`, and the row-relative output index are
  ///     hoisted outside the inner loop.
  ///   * **Dropped no-op `& 0xFF` masks**: `Uint8List[i]` returns an
  ///     int in `[0, 255]` already; the masks were dead code.
  ///   * **Dropped no-op `(value >> 10) & 0xFF`**: after the clamp to
  ///     `[0, 262143]` (= 0x3FFFF), the shift always produces a value
  ///     in `[0, 255]`, so the mask is redundant. A `Uint8List` store
  ///     truncates anyway.
  ///   * **`int.clamp` on each channel** — AOT-inlined to a min/max
  ///     pair, so this is as cheap as the branchy `if-else` version
  ///     while reading cleanly.
  ///
  /// Why not Dart's `Int32x4` / `Float32x4`: `Int32x4` lacks multiply
  /// and shift (the two ops YUV→RGB actually needs); `Float32x4` works
  /// but the per-pixel `int → double → int → uint8` round-trip plus
  /// lane extraction at the end measured as a wash on the test
  /// Samsung. Byte-equivalent output with the original implementation
  /// is pinned by `nv21_decoder_test.dart`.
  static Uint8List nv21ToRgb(Uint8List nv21, int width, int height) {
    final out = Uint8List(width * height * 3);
    final frameSize = width * height;
    // Handle the odd-width case (defensive — camera output is
    // essentially always even-width but the decoder shouldn't crash on
    // synthetic inputs).
    final pairsPerRow = width >> 1;
    final hasTrailingPixel = (width & 1) == 1;

    for (var y = 0; y < height; y++) {
      final yRowStart = y * width;
      var uvp = frameSize + (y >> 1) * width;
      var outIdx = yRowStart * 3;
      var yIdx = yRowStart;

      for (var pair = 0; pair < pairsPerRow; pair++) {
        // One UV fetch per two pixels — saves the per-pixel `(x & 1)`
        // branch the scalar loop paid.
        final v = nv21[uvp++] - 128;
        final u = nv21[uvp++] - 128;

        // UV contributions are pair-constant; compute once, reuse
        // twice. R has no U term, B has no V term.
        final vR = 1634 * v;
        final vMinusG = 833 * v;
        final uMinusG = 400 * u;
        final uB = 2066 * u;

        // -- pixel 0 of the pair --
        var yv = nv21[yIdx++] - 16;
        if (yv < 0) yv = 0;
        var y1192 = 1192 * yv;
        var r = y1192 + vR;
        var g = y1192 - vMinusG - uMinusG;
        var b = y1192 + uB;
        r = r.clamp(0, 262143);
        g = g.clamp(0, 262143);
        b = b.clamp(0, 262143);
        out[outIdx++] = r >> 10;
        out[outIdx++] = g >> 10;
        out[outIdx++] = b >> 10;

        // -- pixel 1 of the pair --
        yv = nv21[yIdx++] - 16;
        if (yv < 0) yv = 0;
        y1192 = 1192 * yv;
        r = y1192 + vR;
        g = y1192 - vMinusG - uMinusG;
        b = y1192 + uB;
        r = r.clamp(0, 262143);
        g = g.clamp(0, 262143);
        b = b.clamp(0, 262143);
        out[outIdx++] = r >> 10;
        out[outIdx++] = g >> 10;
        out[outIdx++] = b >> 10;
      }

      // Trailing-pixel handling for odd widths. Reuses the most recent
      // UV pair (matches the original loop's behaviour — odd-width
      // frames replay the last `(x & 1) == 0` branch's UV values).
      if (hasTrailingPixel) {
        final lastV = nv21[uvp - 2] - 128;
        final lastU = nv21[uvp - 1] - 128;
        var yv = nv21[yRowStart + width - 1] - 16;
        if (yv < 0) yv = 0;
        final y1192 = 1192 * yv;
        var r = y1192 + 1634 * lastV;
        var g = y1192 - 833 * lastV - 400 * lastU;
        var b = y1192 + 2066 * lastU;
        r = r.clamp(0, 262143);
        g = g.clamp(0, 262143);
        b = b.clamp(0, 262143);
        out[outIdx++] = r >> 10;
        out[outIdx++] = g >> 10;
        out[outIdx++] = b >> 10;
      }
    }
    return out;
  }
}
