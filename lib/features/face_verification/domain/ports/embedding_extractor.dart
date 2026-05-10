import 'dart:typed_data';

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
}
