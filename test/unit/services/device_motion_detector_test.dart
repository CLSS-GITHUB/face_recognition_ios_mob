import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/services/device_motion_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('not static while the buffer is still filling', () {
    final d = DeviceMotionDetector();
    // 9.81 = gravity magnitude at rest. Fewer samples than bufferSize
    // means we should NOT yet declare static — punishing the user
    // before we have a full second of data is a UX bug.
    for (var i = 0; i < 25; i++) {
      d.record(0, 0, 9.81);
    }
    expect(d.bufferedSamples, 25);
    expect(d.isStatic(), isFalse);
  });

  test('static when the buffer fills with a constant gravity reading', () {
    final d = DeviceMotionDetector();
    // Phone on a flat surface: only gravity, no motion. Magnitude is
    // identical every sample → std-dev is zero → declared static.
    for (var i = 0; i < 50; i++) {
      d.record(0, 0, 9.81);
    }
    expect(d.bufferedSamples, 50);
    expect(d.isStatic(), isTrue);
  });

  test('not static under typical handheld tremor (~0.2 m/s²)', () {
    final d = DeviceMotionDetector();
    // Hand-held tremor produces small variations on top of gravity.
    // The threshold is 0.05 m/s²; this sweep produces ~0.14 m/s² std,
    // comfortably above the floor.
    for (var i = 0; i < 50; i++) {
      final t = (i % 7).toDouble() * 0.1 - 0.3; // -0.3 .. +0.3
      d.record(0, 0, 9.81 + t);
    }
    expect(d.isStatic(), isFalse);
  });

  test('reset clears the buffer', () {
    final d = DeviceMotionDetector();
    for (var i = 0; i < 50; i++) {
      d.record(0, 0, 9.81);
    }
    expect(d.isStatic(), isTrue);
    d.reset();
    expect(d.bufferedSamples, 0);
    expect(d.isStatic(), isFalse);
  });

  test('ring buffer drops oldest entries past capacity', () {
    final d = DeviceMotionDetector();
    for (var i = 0; i < 120; i++) {
      d.record(0, 0, 9.81);
    }
    expect(d.bufferedSamples, 50);
  });

  test('threshold pulls from FaceThresholds (parity guard)', () {
    // Modulate the magnitude by ±0.1 around gravity. Std-dev = 0.1,
    // safely above the 0.05 floor; if someone bumps the threshold
    // upward without intent, this trips.
    expect(FaceThresholds.replayDeviceMotionMaxStd, lessThan(0.1));
    final d = DeviceMotionDetector();
    for (var i = 0; i < 50; i++) {
      d.record(0, 0, i.isEven ? 9.71 : 9.91);
    }
    expect(d.isStatic(), isFalse);
  });

  test('orientation-invariant: same magnitude in any direction reads static',
      () {
    final d = DeviceMotionDetector();
    // Phone lying on its side: gravity ≈ on the x axis. Magnitude
    // still 9.81. Variance still zero.
    for (var i = 0; i < 50; i++) {
      d.record(9.81, 0, 0);
    }
    expect(d.isStatic(), isTrue);
  });
}
