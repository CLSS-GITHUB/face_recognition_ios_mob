import 'dart:typed_data';

import 'package:face_ios_android/features/face_verification/domain/ports/pad_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NoOpPadClassifier', () {
    test('always reports the real-face verdict (0.0)', () async {
      const pad = NoOpPadClassifier();
      // Any payload, any size — NoOp doesn't read the bytes.
      expect(await pad.classify(Uint8List(0)), 0.0);
      expect(await pad.classify(Uint8List(37632)), 0.0);
    });

    test('exposes the "noop" telemetry label', () {
      expect(const NoOpPadClassifier().label, 'noop');
    });
  });
}
