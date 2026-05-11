import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:flutter_test/flutter_test.dart';

User _make({int modelVersion = 0}) => User(
      userId: 'U1',
      name: 'Test',
      faceTemplates: const <Float32List>[],
      isActive: true,
      modelVersion: modelVersion,
    );

void main() {
  group('User.requiresReEnroll', () {
    test('legacy (modelVersion 0) requires re-enrolment', () {
      // Rows migrated up from schema v2 default to modelVersion = 0
      // because we cannot infer which model produced their templates.
      final u = _make(modelVersion: 0);
      expect(u.requiresReEnroll, isTrue);
    });

    test('current model matches → does not require re-enrolment', () {
      final u = _make(modelVersion: FaceThresholds.modelVersion);
      expect(u.requiresReEnroll, isFalse);
    });

    test('stale future version still surfaces as needs re-enrolment', () {
      // Downgrade / rollback scenario: a user enrolled under a newer
      // model is also incompatible. requiresReEnroll is symmetric — any
      // mismatch with the *currently-bundled* model triggers re-capture.
      final u = _make(modelVersion: FaceThresholds.modelVersion + 1);
      expect(u.requiresReEnroll, isTrue);
    });
  });

  test('copyWith preserves modelVersion when not overridden', () {
    final u = _make(modelVersion: 7);
    final renamed = u.copyWith(name: 'NewName');
    expect(renamed.modelVersion, 7);
    expect(renamed.name, 'NewName');
  });

  test('copyWith overrides modelVersion when specified', () {
    final u = _make(modelVersion: 0);
    final upgraded = u.copyWith(modelVersion: FaceThresholds.modelVersion);
    expect(upgraded.modelVersion, FaceThresholds.modelVersion);
    expect(upgraded.requiresReEnroll, isFalse);
  });
}
