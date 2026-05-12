@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/error/failures.dart';
import 'package:face_ios_android/core/isolates/pad_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

const int _payloadBytes =
    FaceThresholds.inputSize * FaceThresholds.inputSize * 3;

Uint8List _frame() {
  final out = Uint8List(_payloadBytes);
  for (var i = 0; i < out.length; i++) {
    out[i] = i & 0xff;
  }
  return out;
}

void main() {
  group('PadIsolate (stub mode)', () {
    test('spawn → classify → close round-trip returns the stub score',
        () async {
      final iso = await PadIsolate.spawnTestStub(fixedScore: 0.0);
      try {
        final score = await iso.classify(_frame());
        expect(score, 0.0);
      } finally {
        await iso.close();
      }
    });

    test('non-zero stub score round-trips clamped to [0, 1]', () async {
      final iso = await PadIsolate.spawnTestStub(fixedScore: 1.7);
      try {
        // Stub configured above the [0, 1] range — worker clamps.
        expect(await iso.classify(_frame()), 1.0);
      } finally {
        await iso.close();
      }
    });

    test('reports a stable telemetry label', () async {
      final iso = await PadIsolate.spawnTestStub();
      try {
        expect(iso.modelLabel, 'stub');
      } finally {
        await iso.close();
      }
    });

    test('wrong-size payload throws ArgumentError', () async {
      final iso = await PadIsolate.spawnTestStub();
      try {
        expect(
          () => iso.classify(Uint8List(_payloadBytes - 1)),
          throwsArgumentError,
        );
      } finally {
        await iso.close();
      }
    });

    test('classify after close throws StateError', () async {
      final iso = await PadIsolate.spawnTestStub();
      await iso.close();
      expect(
        () => iso.classify(_frame()),
        throwsStateError,
      );
    });

    test('close is idempotent', () async {
      final iso = await PadIsolate.spawnTestStub();
      await iso.close();
      await iso.close(); // must not throw
    });

    test(
      'concurrent classify throws PadUnavailableError (busy)',
      () async {
        final iso = await PadIsolate.spawnTestStub(
          latency: const Duration(milliseconds: 80),
        );
        try {
          final first = iso.classify(_frame());
          expect(
            () => iso.classify(_frame()),
            throwsA(isA<PadUnavailableError>()),
          );
          await first; // let the first call complete cleanly
        } finally {
          await iso.close();
        }
      },
    );
  });
}
