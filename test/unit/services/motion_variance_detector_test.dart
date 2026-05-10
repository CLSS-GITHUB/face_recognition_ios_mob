import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/services/motion_variance_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('not static while the buffer is still filling', () {
    final d = MotionVarianceDetector();
    for (var i = 0; i < 10; i++) {
      d.recordCentroid(100, 100);
    }
    expect(d.bufferedFrames, 10);
    expect(d.isStatic(), isFalse,
        reason: 'must not reject before we have a full second of data');
  });

  test('static when the buffer fills with a frame-locked centroid', () {
    final d = MotionVarianceDetector();
    for (var i = 0; i < 30; i++) {
      d.recordCentroid(100, 100);
    }
    expect(d.bufferedFrames, 30);
    expect(d.isStatic(), isTrue);
  });

  test('not static under normal head wobble', () {
    final d = MotionVarianceDetector();
    // ±5 px wander — well above the replayMotionMaxStdPx (0.8) floor.
    for (var i = 0; i < 30; i++) {
      d.recordCentroid(100 + (i % 3) * 5.0, 200 + (i % 5) * 2.0);
    }
    expect(d.isStatic(), isFalse);
  });

  test('reset clears the buffer', () {
    final d = MotionVarianceDetector();
    for (var i = 0; i < 30; i++) {
      d.recordCentroid(0, 0);
    }
    expect(d.isStatic(), isTrue);
    d.reset();
    expect(d.bufferedFrames, 0);
    expect(d.isStatic(), isFalse);
  });

  test('ring buffer drops oldest entries past capacity', () {
    final d = MotionVarianceDetector();
    for (var i = 0; i < 60; i++) {
      d.recordCentroid(i.toDouble(), i.toDouble());
    }
    expect(d.bufferedFrames, 30);
  });

  test('threshold is consumed from FaceThresholds (parity guard)', () {
    // Sanity: one px of motion is well over the doc's 0.8 threshold, so a
    // buffer with that much motion must NOT register as static. If the
    // threshold ever changes upward without intent, this catches it.
    expect(FaceThresholds.replayMotionMaxStdPx, lessThan(1.0));
    final d = MotionVarianceDetector();
    for (var i = 0; i < 30; i++) {
      d.recordCentroid(i.isEven ? 100 : 102, 100);
    }
    expect(d.isStatic(), isFalse);
  });
}
