import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

import '../constants/thresholds.dart';
import 'bitmap_utils.dart';
import 'camera_image_converter.dart' show Nv21Decoder;

/// Wire-level identifier for the raw camera plane being sent to the
/// embedding isolate's `prepare` codepath. The integer values are stable
/// because they cross the isolate boundary as `int`s — re-ordering them
/// would silently break older clients in flight.
enum RawFrameFormat {
  nv21, // 0
  bgra8888, // 1
}

/// End-to-end "raw camera frame → 112×112 RGB extractor payload" pipeline.
///
/// Pulled out of the controllers (and out of [BitmapUtils.buildExtractorPayload]
/// / [Nv21Decoder]) so the same code path runs on the host *and* inside the
/// long-lived embedding isolate. Phase D moved the per-frame work into the
/// isolate to keep the UI thread free during a verify; this helper exists so
/// neither side reaches for a different implementation by accident — a probe
/// and a stored template can only diverge through model output, never through
/// preprocessing drift.
class FramePreparation {
  FramePreparation._();

  /// Decode → crop (with [FaceThresholds.faceCropMargin]) → eye-axis align →
  /// optional histogram equalisation → resize to [FaceThresholds.inputSize] →
  /// flatten to RGB bytes. Returns the same byte layout
  /// `EmbeddingIsolate.extract` already consumes.
  ///
  /// `bbox` is in ML Kit's rotated-frame coordinates (i.e. the same space
  /// already used by the on-host call sites). Eye coords may be `null`
  /// independently — when both are non-null we rotate the crop so the
  /// inter-eye axis is horizontal.
  ///
  /// Returns `null` only when the input bytes can't be decoded (wrong size
  /// for the declared format). All other failure modes (degenerate bbox,
  /// missing landmarks) fall through to the un-aligned default rather than
  /// throwing — same conservative behaviour the host pipeline already had.
  static Uint8List? prepare({
    required Uint8List rawBytes,
    required int width,
    required int height,
    required RawFrameFormat format,
    required Rect bbox,
    int? leftEyeX,
    int? leftEyeY,
    int? rightEyeX,
    int? rightEyeY,
  }) {
    final decoded = _decodeRaw(rawBytes, width, height, format);
    if (decoded == null) return null;

    final crop = BitmapUtils.cropFace(decoded, bbox);
    final aligned = _alignAndMaybeEnhance(
      crop,
      leftEyeX: leftEyeX,
      leftEyeY: leftEyeY,
      rightEyeX: rightEyeX,
      rightEyeY: rightEyeY,
    );
    final resized = img.copyResize(
      aligned,
      width: FaceThresholds.inputSize,
      height: FaceThresholds.inputSize,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(resized.getBytes(order: img.ChannelOrder.rgb));
  }

  static img.Image? _decodeRaw(
    Uint8List bytes,
    int width,
    int height,
    RawFrameFormat format,
  ) {
    switch (format) {
      case RawFrameFormat.nv21:
        final expected = width * height + (width * height) ~/ 2;
        if (bytes.length < expected) return null;
        final rgb = Nv21Decoder.nv21ToRgb(bytes, width, height);
        return BitmapUtils.rgbBytesToImage(rgb, width, height);
      case RawFrameFormat.bgra8888:
        final expected = width * height * 4;
        if (bytes.length < expected) return null;
        final rgb = Uint8List(width * height * 3);
        var di = 0;
        for (var i = 0; i < bytes.length; i += 4) {
          rgb[di++] = bytes[i + 2];
          rgb[di++] = bytes[i + 1];
          rgb[di++] = bytes[i];
        }
        return BitmapUtils.rgbBytesToImage(rgb, width, height);
    }
  }

  /// Inlined port of ImageProcessing.alignAndMaybeEnhance that takes raw
  /// landmark coords instead of a `FaceData`. The two diverge only in their
  /// argument plumbing — the math (atan2 over the inter-eye axis, skip if
  /// already < 1°, normalize when average luma < 100) is identical.
  static img.Image _alignAndMaybeEnhance(
    img.Image faceCrop, {
    int? leftEyeX,
    int? leftEyeY,
    int? rightEyeX,
    int? rightEyeY,
    double brightnessThreshold = 100,
  }) {
    var out = faceCrop;
    if (leftEyeX != null &&
        leftEyeY != null &&
        rightEyeX != null &&
        rightEyeY != null) {
      final dx = (rightEyeX - leftEyeX).toDouble();
      final dy = (rightEyeY - leftEyeY).toDouble();
      final angleDeg = atan2(dy, dx) * 180 / pi;
      if (angleDeg.abs() >= 1) {
        out = img.copyRotate(out, angle: -angleDeg);
      }
    }
    final avg = _averageLuminance(out);
    if (avg < brightnessThreshold) {
      out = img.normalize(out, min: 0, max: 255);
    }
    return out;
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
