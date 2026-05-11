import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/utils/template_meta_codec.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:flutter_test/flutter_test.dart';

User _make({
  int modelVersion = 0,
  DateTime? enrolledAt,
  DateTime? lastEnrolledAt,
  List<FaceTemplateMeta> templateMeta = const <FaceTemplateMeta>[],
}) =>
    User(
      userId: 'U1',
      name: 'Test',
      faceTemplates: const <Float32List>[],
      isActive: true,
      modelVersion: modelVersion,
      enrolledAt: enrolledAt,
      lastEnrolledAt: lastEnrolledAt,
      templateMeta: templateMeta,
    );

void main() {
  group('User.requiresReEnroll (model version)', () {
    test('legacy (modelVersion 0) requires re-enrolment', () {
      // Rows migrated up from schema v2 default to modelVersion = 0
      // because we cannot infer which model produced their templates.
      final u = _make(modelVersion: 0);
      expect(u.requiresReEnroll, isTrue);
    });

    test('current model + fresh template → does not require re-enrolment',
        () {
      final u = _make(
        modelVersion: FaceThresholds.modelVersion,
        lastEnrolledAt: DateTime.now(),
      );
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

  group('User.isStaleAsOf (template age)', () {
    final now = DateTime.utc(2026, 5, 11, 12);

    test('fresh lastEnrolledAt → not stale', () {
      final u = _make(
        modelVersion: FaceThresholds.modelVersion,
        lastEnrolledAt: now.subtract(const Duration(days: 30)),
      );
      expect(u.isStaleAsOf(now), isFalse);
    });

    test('lastEnrolledAt exactly at the boundary → not yet stale', () {
      final u = _make(
        modelVersion: FaceThresholds.modelVersion,
        lastEnrolledAt: now.subtract(
          const Duration(days: FaceThresholds.templateMaxAgeDays),
        ),
      );
      expect(u.isStaleAsOf(now), isFalse,
          reason: 'Boundary is inclusive of the freshness window.');
    });

    test('lastEnrolledAt beyond templateMaxAgeDays → stale', () {
      final u = _make(
        modelVersion: FaceThresholds.modelVersion,
        lastEnrolledAt: now.subtract(
          const Duration(days: FaceThresholds.templateMaxAgeDays + 1),
        ),
      );
      expect(u.isStaleAsOf(now), isTrue);
    });

    test('falls back to enrolledAt when lastEnrolledAt is null', () {
      // Pre-v4 row: lastEnrolledAt was never written. The freshness
      // clock must use enrolledAt so the user isn't accidentally given
      // an infinite grace period.
      final u = _make(
        modelVersion: FaceThresholds.modelVersion,
        enrolledAt: now.subtract(
          const Duration(days: FaceThresholds.templateMaxAgeDays + 1),
        ),
      );
      expect(u.isStaleAsOf(now), isTrue);
    });

    test('rows with no timestamps and current model → not stale', () {
      // Defensive: a row with neither timestamp does not get
      // perma-flagged. In practice this is unreachable because the
      // model-version check above would have caught a legacy row.
      final u = _make(modelVersion: FaceThresholds.modelVersion);
      expect(u.isStaleAsOf(now), isFalse);
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
    final upgraded = u.copyWith(
      modelVersion: FaceThresholds.modelVersion,
      lastEnrolledAt: DateTime.now(),
    );
    expect(upgraded.modelVersion, FaceThresholds.modelVersion);
    expect(upgraded.requiresReEnroll, isFalse);
  });

  test('copyWith can clear lastEnrolledAt', () {
    final u = _make(
      modelVersion: FaceThresholds.modelVersion,
      lastEnrolledAt: DateTime.now(),
    );
    final cleared = u.copyWith(clearLastEnrolledAt: true);
    expect(cleared.lastEnrolledAt, isNull);
  });

  group('User templateMeta helpers', () {
    final stamp = DateTime.utc(2026, 5, 11);

    test('empty metadata defaults to bare-face only', () {
      final u = _make();
      expect(u.hasGlassesTemplate, isFalse);
      // Legacy rows (no templateMeta) get the bare-face default so
      // they keep matching against bare-face probes.
      expect(u.hasBareFaceTemplate, isTrue);
    });

    test('glasses-only metadata reports hasGlassesTemplate', () {
      final u = _make(templateMeta: <FaceTemplateMeta>[
        FaceTemplateMeta(wearsGlasses: true, capturedAt: stamp),
      ]);
      expect(u.hasGlassesTemplate, isTrue);
      expect(u.hasBareFaceTemplate, isFalse);
    });

    test('mixed metadata reports both', () {
      final u = _make(templateMeta: <FaceTemplateMeta>[
        FaceTemplateMeta(wearsGlasses: false, capturedAt: stamp),
        FaceTemplateMeta(wearsGlasses: true, capturedAt: stamp),
      ]);
      expect(u.hasGlassesTemplate, isTrue);
      expect(u.hasBareFaceTemplate, isTrue);
    });

    test('copyWith updates templateMeta when supplied', () {
      final u = _make();
      final replaced = u.copyWith(
        templateMeta: <FaceTemplateMeta>[
          FaceTemplateMeta(wearsGlasses: true, capturedAt: stamp),
        ],
      );
      expect(replaced.templateMeta, hasLength(1));
      expect(replaced.templateMeta.first.wearsGlasses, isTrue);
    });
  });
}
