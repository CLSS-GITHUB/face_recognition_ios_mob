@Tags(<String>['perf'])
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/services/face_matching_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart cosine-search perf gate.
///
/// Architecture §8.1 target: cosine search p95 ≤ 8 ms / 1000 templates on
/// MidRange. This test runs on whatever host executes it; we use a
/// generous ceiling (50 ms) so it doesn't false-fail on overloaded
/// shared CI runners while still catching multi-x regressions. Tighten
/// when we have a real-device gate.
///
/// Tagged `perf` so a CI job can opt in via `flutter test --tags perf`
/// without slowing the main suite.
void main() {
  test('findBestMatch p95 ≤ 50 ms over 1000 templates', () {
    const dim = FaceThresholds.embeddingDim;
    const count = 1000;
    const probes = 200;

    final rng = Random(42);
    Float32List rand() {
      final v = Float32List(dim);
      var sumSq = 0.0;
      for (var i = 0; i < dim; i++) {
        v[i] = rng.nextDouble() * 2 - 1;
        sumSq += v[i] * v[i];
      }
      final norm = sqrt(sumSq);
      for (var i = 0; i < dim; i++) {
        v[i] /= norm;
      }
      return v;
    }

    final flat = Float32List(count * dim);
    for (var i = 0; i < count; i++) {
      final t = rand();
      flat.setRange(i * dim, (i + 1) * dim, t);
    }

    const matcher = FaceMatchingService();
    final samples = <int>[];

    // Warm-up — JIT effects.
    for (var i = 0; i < 10; i++) {
      matcher.findBestMatch(rand(), flat, count);
    }

    final sw = Stopwatch();
    for (var i = 0; i < probes; i++) {
      final probe = rand();
      sw
        ..reset()
        ..start();
      matcher.findBestMatch(probe, flat, count);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    samples.sort();
    final p50 = samples[(samples.length * 0.50).floor()];
    final p95 = samples[(samples.length * 0.95).floor()];
    // ignore: avoid_print
    print('cosine_search 1000×$dim — p50=${p50}us p95=${p95}us');
    expect(p95, lessThan(50000),
        reason:
            'cosine search p95 over 1000 templates regressed past 50 ms ceiling');
  });
}
