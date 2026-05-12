@TestOn('vm')
library;

import 'package:face_ios_android/core/diagnostics/latency_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LatencyTracker', () {
    test('empty tracker snapshot is empty + const', () {
      final tracker = LatencyTracker();
      final s = tracker.snapshot();
      expect(s, isEmpty);
      // identical to the empty sentinel — callers don't allocate when
      // there's nothing recorded yet (cold-path render on /debug/health
      // hits this branch every time the screen mounts).
      expect(identical(s, const <LatencyEvent>[]), isTrue);
    });

    test('measure records duration on success and returns the value',
        () async {
      final tracker = LatencyTracker();
      final result = await tracker.measure<int>('op', () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return 42;
      });
      expect(result, 42);
      final s = tracker.snapshot();
      expect(s, hasLength(1));
      expect(s.single.name, 'op');
      expect(s.single.ok, isTrue);
      // Duration is non-null and reflects the 5 ms sleep with slack —
      // unit-test clocks are noisy; we don't pin the upper bound.
      expect(s.single.durationMicros, isNotNull);
      expect(s.single.durationMicros!, greaterThanOrEqualTo(3000));
    });

    test('measure records duration on failure and rethrows', () async {
      final tracker = LatencyTracker();
      Object? caught;
      try {
        await tracker.measure<void>('flaky', () async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          throw StateError('boom');
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>(),
          reason: 'measure must propagate the original exception');
      final s = tracker.snapshot();
      expect(s, hasLength(1));
      expect(s.single.name, 'flaky');
      expect(s.single.ok, isFalse,
          reason: 'failed operations record with ok=false so /debug/health '
              'can flag hung/slow-failing tasks visually');
      expect(s.single.durationMicros, isNotNull);
    });

    test('mark records a point-in-time event with null duration', () {
      final tracker = LatencyTracker();
      tracker.mark('firstFrame');
      final s = tracker.snapshot();
      expect(s, hasLength(1));
      expect(s.single.name, 'firstFrame');
      expect(s.single.durationMicros, isNull,
          reason: 'mark events have no duration — they are timestamps, '
              'not intervals');
      expect(s.single.ok, isTrue);
    });

    test('snapshot returns newest-first', () async {
      final tracker = LatencyTracker();
      tracker.mark('a');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      tracker.mark('b');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      tracker.mark('c');
      final names = tracker.snapshot().map((e) => e.name).toList();
      expect(names, ['c', 'b', 'a'],
          reason: 'most recent event must come first so /debug/health '
              'shows the latest cold-path run at the top');
    });

    test('ring buffer drops oldest events past capacity', () {
      // The buffer is capacity-128 by design. Push 150 events and
      // confirm the oldest 22 fall off and the newest 128 survive in
      // newest-first order.
      final tracker = LatencyTracker();
      for (var i = 0; i < 150; i++) {
        tracker.mark('evt_$i');
      }
      final s = tracker.snapshot();
      expect(s, hasLength(128));
      expect(s.first.name, 'evt_149');
      expect(s.last.name, 'evt_22');
    });

    test('clear empties the buffer', () {
      final tracker = LatencyTracker();
      tracker.mark('a');
      tracker.mark('b');
      expect(tracker.snapshot(), hasLength(2));
      tracker.clear();
      expect(tracker.snapshot(), isEmpty);
      // Subsequent appends start from a fresh index, not append to the
      // cleared positions.
      tracker.mark('c');
      final s = tracker.snapshot();
      expect(s, hasLength(1));
      expect(s.single.name, 'c');
    });

    test('snapshot is unmodifiable', () {
      final tracker = LatencyTracker();
      tracker.mark('a');
      final s = tracker.snapshot();
      expect(() => s.add(s.first), throwsUnsupportedError,
          reason: 'caller must not be able to mutate the tracker through '
              'the snapshot list');
    });

    test('measure accepts a synchronous body', () async {
      // FutureOr<T> Function() lets callers pass either sync or async
      // bodies. The sync path matters for instrumentation around
      // ref.read() and similar non-Future operations.
      final tracker = LatencyTracker();
      final result = await tracker.measure<int>('sync', () => 7);
      expect(result, 7);
      expect(tracker.snapshot().single.name, 'sync');
    });
  });
}
