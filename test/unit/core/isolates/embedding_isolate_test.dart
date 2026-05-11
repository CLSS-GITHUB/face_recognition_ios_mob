@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/error/failures.dart';
import 'package:face_ios_android/core/isolates/embedding_isolate.dart';
import 'package:face_ios_android/core/utils/frame_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

const int _payloadBytes =
    FaceThresholds.inputSize * FaceThresholds.inputSize * 3;

Uint8List _syntheticNv21(int w, int h) {
  final out = Uint8List(w * h + (w * h) ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = i & 0xff;
  }
  return out;
}

Uint8List _frame({int seed = 0}) {
  final out = Uint8List(_payloadBytes);
  for (var i = 0; i < out.length; i++) {
    out[i] = (i + seed) & 0xff;
  }
  return out;
}

void main() {
  group('EmbeddingIsolate (stub mode)', () {
    test('spawn → extract → close round-trip', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        final v = await iso.extract(_frame());
        expect(v, isA<Float32List>());
        expect(v.length, FaceThresholds.embeddingDim);
        // L2-normalised: ‖v‖ == 1 within float tolerance.
        var sumSq = 0.0;
        for (final x in v) {
          sumSq += x * x;
        }
        expect(sumSq, closeTo(1.0, 1e-4));
      } finally {
        await iso.close();
      }
    });

    test('same input → identical output (deterministic)', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        final a = await iso.extract(_frame(seed: 42));
        final b = await iso.extract(_frame(seed: 42));
        expect(a, equals(b));
      } finally {
        await iso.close();
      }
    });

    test('different input → different output', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        final a = await iso.extract(_frame(seed: 1));
        final b = await iso.extract(_frame(seed: 2));
        expect(a, isNot(equals(b)));
      } finally {
        await iso.close();
      }
    });

    test('wrong-size input throws ArgumentError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        expect(
          () => iso.extract(Uint8List(_payloadBytes - 1)),
          throwsArgumentError,
        );
      } finally {
        await iso.close();
      }
    });

    test('concurrent extract throws EmbeddingBusyError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub(
        latency: const Duration(milliseconds: 80),
      );
      try {
        final first = iso.extract(_frame(seed: 1));
        // Second call before the first resolves must throw synchronously.
        expect(
          () => iso.extract(_frame(seed: 2)),
          throwsA(isA<EmbeddingBusyError>()),
        );
        await first; // let the first request complete cleanly
      } finally {
        await iso.close();
      }
    });

    test('after close, extract throws StateError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      await iso.close();
      expect(
        () => iso.extract(_frame()),
        throwsStateError,
      );
    });

    test('close mid-flight rejects pending future with StateError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub(
        latency: const Duration(milliseconds: 250),
      );
      final pending = iso.extract(_frame());
      // Don't await — close while the worker is still computing.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await iso.close();
      await expectLater(pending, throwsStateError);
    });

    test('close is idempotent', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      await iso.close();
      await iso.close(); // must not throw
    });
  });

  // Phase D — preparation pipeline (decode + crop + align + resize) runs on
  // the same isolate, sharing the single in-flight slot with extract.
  group('EmbeddingIsolate.prepare (stub mode)', () {
    test('NV21 round-trip returns a 112×112×3 payload', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        final out = await iso.prepare(
          rawBytes: _syntheticNv21(240, 320),
          width: 240,
          height: 320,
          format: RawFrameFormat.nv21,
          bbox: const Rect.fromLTWH(60, 90, 120, 140),
        );
        expect(out.length, _payloadBytes);
      } finally {
        await iso.close();
      }
    });

    test('rejects empty bytes synchronously with ArgumentError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        expect(
          () => iso.prepare(
            rawBytes: Uint8List(0),
            width: 240,
            height: 320,
            format: RawFrameFormat.nv21,
            bbox: const Rect.fromLTWH(0, 0, 64, 64),
          ),
          throwsArgumentError,
        );
      } finally {
        await iso.close();
      }
    });

    test('truncated NV21 reaches the worker → EmbeddingFailedError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        // 240×320 NV21 needs 115,200 bytes — supply far less. The host-side
        // ArgumentError gate only fires on dimension/length=0; this one
        // travels to the worker which returns null from FramePreparation
        // and replies with the structured failure type.
        await expectLater(
          iso.prepare(
            rawBytes: Uint8List(500),
            width: 240,
            height: 320,
            format: RawFrameFormat.nv21,
            bbox: const Rect.fromLTWH(0, 0, 64, 64),
          ),
          throwsA(isA<EmbeddingFailedError>()),
        );
      } finally {
        await iso.close();
      }
    });

    test('prepare while extract is in flight throws EmbeddingBusyError',
        () async {
      final iso = await EmbeddingIsolate.spawnTestStub(
        latency: const Duration(milliseconds: 80),
      );
      try {
        final firstExtract = iso.extract(_frame());
        // The single in-flight slot covers both methods — prepare must
        // bounce synchronously, same contract as concurrent extract.
        expect(
          () => iso.prepare(
            rawBytes: _syntheticNv21(64, 64),
            width: 64,
            height: 64,
            format: RawFrameFormat.nv21,
            bbox: const Rect.fromLTWH(0, 0, 32, 32),
          ),
          throwsA(isA<EmbeddingBusyError>()),
        );
        await firstExtract;
      } finally {
        await iso.close();
      }
    });

    test('extract → prepare → extract on the same isolate', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      try {
        // The in-flight slot is single-fire but releases on reply. Two
        // sequential calls of different kinds must coexist on one isolate
        // — that is the whole point of folding prepare into this worker.
        await iso.extract(_frame());
        final prep = await iso.prepare(
          rawBytes: _syntheticNv21(120, 160),
          width: 120,
          height: 160,
          format: RawFrameFormat.nv21,
          bbox: const Rect.fromLTWH(20, 20, 80, 100),
        );
        expect(prep.length, _payloadBytes);
        await iso.extract(_frame(seed: 7));
      } finally {
        await iso.close();
      }
    });

    test('prepare after close throws StateError', () async {
      final iso = await EmbeddingIsolate.spawnTestStub();
      await iso.close();
      expect(
        () => iso.prepare(
          rawBytes: _syntheticNv21(64, 64),
          width: 64,
          height: 64,
          format: RawFrameFormat.nv21,
          bbox: const Rect.fromLTWH(0, 0, 32, 32),
        ),
        throwsStateError,
      );
    });
  });

  // The "UI thread is free" proof. With the worker delayed, host-side
  // microtasks must keep firing — i.e. awaiting `extract` must not block the
  // calling isolate's event loop. If the work were inline, the ticker would
  // be starved and the ratio below would near zero.
  group('EmbeddingIsolate — host event loop is non-blocking', () {
    test(
      'host timers continue to fire during extract',
      () async {
        const extractLatency = Duration(milliseconds: 200);
        final iso = await EmbeddingIsolate.spawnTestStub(
          latency: extractLatency,
        );
        try {
          var ticks = 0;
          final stopwatch = Stopwatch()..start();

          final extractFuture = iso.extract(_frame());
          // Run a host-side ticker concurrently for the duration of the
          // extract. We expect the ticker to land at least 5 ticks by the
          // time the extract resolves — enough to prove the host is alive.
          final ticker = () async {
            while (!extractFuture.isCompletedSync) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              ticks++;
            }
          }();

          await extractFuture;
          await ticker;
          stopwatch.stop();

          expect(ticks, greaterThanOrEqualTo(5),
              reason: 'host ticker should fire while extract is in flight');
          // The extract took at least the stub latency, but the host
          // event loop kept scheduling microtasks the whole time.
          expect(
            stopwatch.elapsed,
            greaterThanOrEqualTo(extractLatency),
          );
        } finally {
          await iso.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'host can interleave a CPU loop with extract',
      () async {
        final iso = await EmbeddingIsolate.spawnTestStub(
          latency: const Duration(milliseconds: 150),
        );
        try {
          final extractFuture = iso.extract(_frame());
          // Tight CPU work yielded one event per iteration so we can prove
          // we keep getting scheduled while the worker is busy.
          var iterations = 0;
          while (!extractFuture.isCompletedSync) {
            await Future<void>(() {});
            iterations++;
            if (iterations > 10000) break; // sanity bail-out
          }
          await extractFuture;
          expect(iterations, greaterThan(10));
        } finally {
          await iso.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });
}

/// Lightweight "is it done yet?" check for a Future without blocking. We
/// poll a flag set by `.then`; this avoids a full `await` and lets the test
/// loop cooperatively run between checks.
extension _FutureSyncCheck<T> on Future<T> {
  static final Expando<bool> _done = Expando<bool>();

  bool get isCompletedSync {
    if (_done[this] == true) return true;
    // Lazily attach a resolver the first time we ask.
    _Bind.bind(this);
    return _done[this] == true;
  }
}

class _Bind {
  static final Set<Object> _bound = <Object>{};
  static void bind<T>(Future<T> f) {
    if (_bound.contains(f)) return;
    _bound.add(f);
    f.then(
      (_) => _FutureSyncCheck._done[f] = true,
      onError: (Object _, StackTrace _) => _FutureSyncCheck._done[f] = true,
    );
  }
}
