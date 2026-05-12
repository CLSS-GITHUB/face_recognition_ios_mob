import 'dart:typed_data';

import '../../../../core/isolates/pad_isolate.dart';
import '../../domain/ports/pad_classifier.dart';

/// Adapts the [PadIsolate] to the domain [PadClassifier] port. Awaits
/// the spawn future on each call so the first classify pays a tiny
/// initial wait if the isolate is still bootstrapping — subsequent
/// calls hit the live isolate directly.
class IsolatePadClassifier implements PadClassifier {
  IsolatePadClassifier(this._isolate, {required this.label});

  final Future<PadIsolate> _isolate;

  @override
  final String label;

  @override
  Future<double> classify(Uint8List rgb112) async {
    final iso = await _isolate;
    return iso.classify(rgb112);
  }
}
