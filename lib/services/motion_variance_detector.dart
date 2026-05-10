import 'dart:math';

import '../core/constants/thresholds.dart';

/// Stateful anti-spoof gate: a frame-locked face (perfectly still bounding
/// box across ~1 second of frames) is almost certainly a printed photo or a
/// static screen. Drop those before the embedding step burns CPU.
///
/// See `docs/verification/architecture_recommendations.md` §7.2.
///
/// The detector is intentionally tiny — it's called from the camera-frame
/// path, so all the per-frame work needs to fit in well under a millisecond.
class MotionVarianceDetector {
  MotionVarianceDetector({this.bufferSize = _defaultBufferSize});

  /// 30 frames at 30 fps ≈ 1 s of data, matching the architecture doc's
  /// rolling window.
  static const int _defaultBufferSize = 30;
  final int bufferSize;

  final List<_Centroid> _buffer = <_Centroid>[];

  int get bufferedFrames => _buffer.length;

  void recordCentroid(double x, double y) {
    _buffer.add(_Centroid(x, y));
    if (_buffer.length > bufferSize) {
      _buffer.removeAt(0);
    }
  }

  void reset() => _buffer.clear();

  /// `true` when std-dev in both x and y is below
  /// `replayMotionMaxStdPx` across a *full* buffer. Returns `false` while
  /// the buffer is still filling — we never reject before we have a full
  /// second of evidence (avoids killing the very first attempt).
  bool isStatic() {
    if (_buffer.length < bufferSize) return false;

    var sumX = 0.0;
    var sumY = 0.0;
    for (final p in _buffer) {
      sumX += p.x;
      sumY += p.y;
    }
    final n = _buffer.length;
    final meanX = sumX / n;
    final meanY = sumY / n;

    var sxSq = 0.0;
    var sySq = 0.0;
    for (final p in _buffer) {
      final dx = p.x - meanX;
      final dy = p.y - meanY;
      sxSq += dx * dx;
      sySq += dy * dy;
    }
    final stdX = sqrt(sxSq / n);
    final stdY = sqrt(sySq / n);

    return stdX < FaceThresholds.replayMotionMaxStdPx &&
        stdY < FaceThresholds.replayMotionMaxStdPx;
  }
}

class _Centroid {
  const _Centroid(this.x, this.y);
  final double x;
  final double y;
}
