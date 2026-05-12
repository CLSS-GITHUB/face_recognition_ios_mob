import 'dart:async';

/// A single timing or point-in-time event recorded by [LatencyTracker].
///
/// - [durationMicros] is `null` for [LatencyTracker.mark]-style events
///   (those record a moment, not an interval).
/// - [ok] is `false` when the wrapped operation threw — the duration is
///   still recorded so a flaky path's *time-to-fail* is visible on
///   `/debug/health` alongside its success-case sibling.
class LatencyEvent {
  const LatencyEvent({
    required this.name,
    required this.startedAt,
    required this.durationMicros,
    required this.ok,
  });

  final String name;
  final DateTime startedAt;
  final int? durationMicros;
  final bool ok;
}

/// Always-on cold-path latency instrumentation.
///
/// Built for the question "where is the time actually going on the tap
/// → first-useful-frame path?" — a question we kept answering by
/// guessing-and-shipping (F-1, O-7, etc.) instead of measuring. The
/// tracker records events into a bounded ring buffer that
/// `/debug/health` renders, so a field tester (or whoever is doing the
/// next perf pass) can read a real number off the screen instead of
/// taking the audit doc's estimates as gospel.
///
/// **Always on, by design.** The recorded cost per event is a couple
/// microseconds (a `DateTime.now` + a `Stopwatch` + an enqueue into a
/// fixed-size buffer). Behind a `kDebugMode` guard it would only help
/// in debug, which is exactly the build where we *also* want the data
/// least — the regression hunts happen in `--release`.
///
/// Bounded at [_capacity] = 128 events. That holds a few full Verify
/// Identity sessions worth of timings; older events are dropped silently
/// (oldest-first) so a long-running app never accumulates unbounded
/// memory. The buffer is in-memory only — events do not persist across
/// process restarts.
class LatencyTracker {
  LatencyTracker();

  static const int _capacity = 128;

  // Ring buffer. Using a fixed-size List with a write head keeps both
  // append and snapshot O(1) / O(n) respectively. A LinkedList would
  // need a separate counter to enforce capacity; this is simpler.
  final List<LatencyEvent?> _ring = List<LatencyEvent?>.filled(
    _capacity,
    null,
    growable: false,
  );
  int _writeIndex = 0;
  int _count = 0;

  /// Wraps [body] in a stopwatch and appends the result as an event
  /// named [name]. Returns whatever [body] returns. If [body] throws,
  /// the elapsed time is still recorded (with `ok: false`) and the
  /// exception is rethrown — so a hung prewarm task surfaces on
  /// `/debug/health` as a long failed event rather than just
  /// disappearing.
  Future<T> measure<T>(String name, FutureOr<T> Function() body) async {
    final startedAt = DateTime.now();
    final sw = Stopwatch()..start();
    bool ok = true;
    try {
      final result = await body();
      return result;
    } catch (_) {
      ok = false;
      rethrow;
    } finally {
      sw.stop();
      _append(LatencyEvent(
        name: name,
        startedAt: startedAt,
        durationMicros: sw.elapsedMicroseconds,
        ok: ok,
      ));
    }
  }

  /// Records a point-in-time event with no duration. Use for stages
  /// where the moment of arrival matters but there's nothing meaningful
  /// to time — e.g. "first camera frame received". The event lands on
  /// `/debug/health` as a marker the tester can subtract from a prior
  /// `measure` start to read a wall-clock gap.
  void mark(String name) {
    _append(LatencyEvent(
      name: name,
      startedAt: DateTime.now(),
      durationMicros: null,
      ok: true,
    ));
  }

  /// Snapshot of recorded events, newest-first. Returns an unmodifiable
  /// list so callers can safely iterate while the tracker continues to
  /// append.
  List<LatencyEvent> snapshot() {
    if (_count == 0) return const <LatencyEvent>[];
    final out = <LatencyEvent>[];
    // Walk backwards from the most recent write so the result is
    // newest-first without an extra reverse.
    for (var i = 0; i < _count; i++) {
      final idx = (_writeIndex - 1 - i + _capacity) % _capacity;
      final ev = _ring[idx];
      if (ev != null) out.add(ev);
    }
    return List.unmodifiable(out);
  }

  /// Drops every recorded event. Exposed so a /debug/health "clear"
  /// action can reset the buffer between manual cold-path runs without
  /// restarting the app.
  void clear() {
    for (var i = 0; i < _capacity; i++) {
      _ring[i] = null;
    }
    _writeIndex = 0;
    _count = 0;
  }

  void _append(LatencyEvent event) {
    _ring[_writeIndex] = event;
    _writeIndex = (_writeIndex + 1) % _capacity;
    if (_count < _capacity) _count++;
  }
}
