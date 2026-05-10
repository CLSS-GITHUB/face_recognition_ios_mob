import 'dart:typed_data';

import '../../../../core/isolates/embedding_isolate.dart';
import '../../domain/ports/embedding_extractor.dart';

/// Adapter from the domain [EmbeddingExtractor] port to the concrete
/// [EmbeddingIsolate]. The DI graph hands this adapter a `Future<EmbeddingIsolate>`
/// (the isolate spawn future) so the first call awaits spawn and subsequent
/// calls hit the live isolate directly.
class IsolateEmbeddingExtractor implements EmbeddingExtractor {
  IsolateEmbeddingExtractor(this._isolate);

  final Future<EmbeddingIsolate> _isolate;

  @override
  Future<Float32List> extract(Uint8List rgb112) async {
    final iso = await _isolate;
    return iso.extract(rgb112);
  }
}
