import 'dart:math';

import '../core/constants/thresholds.dart';

/// Anti-spoof gate that complements [MotionVarianceDetector]: where the
/// latter watches the *face* bounding box for frame-locked stillness
/// (printed photo / static screen), this watches the *device* itself
/// for the same signal. A phone on a tripod showing a recorded video
/// defeats face-bbox stillness checks (the face inside the video does
/// move), but the device accelerometer reads near-zero variance — the
/// signal we look for here.
///
/// 1D variance over `|accel|` so the result is invariant to device
/// orientation. Magnitude of the raw accelerometer includes gravity:
/// at rest it sits near 9.8 m/s² in any orientation, fluctuating only
/// with sensor noise (~0.01 m/s²) or with hand tremor (~0.05–0.3 m/s²)
/// or motion. Variance of magnitude collapses orientation out of the
/// equation while preserving the motion signal we care about.
///
/// Intentionally tiny: invoked from a high-frequency sensor stream so
/// each `record` call must stay well under a millisecond.
class DeviceMotionDetector {
  DeviceMotionDetector({this.bufferSize = _defaultBufferSize});

  /// 50 samples ≈ 1 s at the 50 Hz sampling period the controller
  /// requests from sensors_plus. Matches the architecture doc's rolling
  /// window length used by the face-motion detector.
  static const int _defaultBufferSize = 50;
  final int bufferSize;

  final List<double> _magnitudes = <double>[];

  int get bufferedSamples => _magnitudes.length;

  /// Records one accelerometer sample. Stored as magnitude only —
  /// gravity remains baked in because we only use *variance* of
  /// magnitude, not its absolute level.
  void record(double x, double y, double z) {
    final m = sqrt(x * x + y * y + z * z);
    _magnitudes.add(m);
    if (_magnitudes.length > bufferSize) {
      _magnitudes.removeAt(0);
    }
  }

  void reset() => _magnitudes.clear();

  /// `true` when accel-magnitude std-dev across a *full* buffer is
  /// below [FaceThresholds.replayDeviceMotionMaxStd]. Returns `false`
  /// while the buffer is still filling — we never declare static
  /// before a full second of evidence (a fresh attempt must not be
  /// punished for the first frames before the IMU has spun up).
  bool isStatic() {
    if (_magnitudes.length < bufferSize) return false;

    var sum = 0.0;
    for (final m in _magnitudes) {
      sum += m;
    }
    final n = _magnitudes.length;
    final mean = sum / n;

    var sumSq = 0.0;
    for (final m in _magnitudes) {
      final d = m - mean;
      sumSq += d * d;
    }
    final std = sqrt(sumSq / n);

    return std < FaceThresholds.replayDeviceMotionMaxStd;
  }
}
