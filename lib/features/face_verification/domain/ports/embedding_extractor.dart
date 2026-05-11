import 'dart:typed_data';
import 'dart:ui' show Rect;

import '../../../../core/utils/frame_preparation.dart';

/// Narrow port the `VerifyUser` use case depends on, so the use case stays
/// testable without spinning up an isolate.
///
/// In production this is satisfied by `EmbeddingIsolate` (a wiring slice
/// will add `implements EmbeddingExtractor` or a thin adapter). In tests it
/// is satisfied by a fake that returns a fixed `Float32List`.
abstract class EmbeddingExtractor {
  /// Extracts a 192-D L2-normalised embedding from a 112×112 RGB byte
  /// buffer (37,632 bytes). May throw `EmbeddingBusyError`,
  /// `EmbeddingFailedError`, or `EmbeddingIsolateUnavailableError` from
  /// `core/error/failures.dart` — `VerifyUser` catches and maps these.
  Future<Float32List> extract(Uint8List rgb112);

  /// Decode + crop + eye-align + resize a raw camera frame into the
  /// `inputSize × inputSize × 3` RGB buffer `extract` consumes. Phase D
  /// moved this off the UI thread; production satisfies it via the same
  /// long-lived embedding isolate (queue length 1 covering both calls).
  ///
  /// Throws the same isolate failures as [extract].
  Future<Uint8List> prepare({
    required Uint8List rawBytes,
    required int width,
    required int height,
    required RawFrameFormat format,
    required Rect bbox,
    int? leftEyeX,
    int? leftEyeY,
    int? rightEyeX,
    int? rightEyeY,
  });
}
