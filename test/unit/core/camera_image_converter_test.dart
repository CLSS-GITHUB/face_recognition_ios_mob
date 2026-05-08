import 'package:camera/camera.dart';
import 'package:face_ios_android/core/utils/camera_image_converter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraImageConverter.androidRotationDegrees', () {
    // sensorOrientation values mirror what most Android devices report
    // (front: 270, back: 90) — same as the camera plugin's docs.

    test('front camera, portrait up → 270', () {
      expect(
        CameraImageConverter.androidRotationDegrees(
          sensorOrientation: 270,
          lensDirection: CameraLensDirection.front,
          deviceOrientation: DeviceOrientation.portraitUp,
        ),
        270,
      );
    });

    test('front camera, landscape left → 0 (270 + 90 mod 360)', () {
      expect(
        CameraImageConverter.androidRotationDegrees(
          sensorOrientation: 270,
          lensDirection: CameraLensDirection.front,
          deviceOrientation: DeviceOrientation.landscapeLeft,
        ),
        0,
      );
    });

    test('front camera, portrait down → 90 (270 + 180 mod 360)', () {
      expect(
        CameraImageConverter.androidRotationDegrees(
          sensorOrientation: 270,
          lensDirection: CameraLensDirection.front,
          deviceOrientation: DeviceOrientation.portraitDown,
        ),
        90,
      );
    });

    test('back camera, portrait up → 90', () {
      expect(
        CameraImageConverter.androidRotationDegrees(
          sensorOrientation: 90,
          lensDirection: CameraLensDirection.back,
          deviceOrientation: DeviceOrientation.portraitUp,
        ),
        90,
      );
    });

    test('back camera, landscape right → 180 (90 - 270 + 360 mod 360)', () {
      expect(
        CameraImageConverter.androidRotationDegrees(
          sensorOrientation: 90,
          lensDirection: CameraLensDirection.back,
          deviceOrientation: DeviceOrientation.landscapeRight,
        ),
        180,
      );
    });

    test('result is always in [0, 360)', () {
      const sensors = [0, 90, 180, 270];
      const orientations = [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeRight,
      ];
      const lenses = [CameraLensDirection.front, CameraLensDirection.back];
      for (final s in sensors) {
        for (final o in orientations) {
          for (final l in lenses) {
            final r = CameraImageConverter.androidRotationDegrees(
              sensorOrientation: s,
              lensDirection: l,
              deviceOrientation: o,
            );
            expect(r, inInclusiveRange(0, 359));
          }
        }
      }
    });
  });
}
