import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:face_ios_android/features/face_verification/presentation/widgets/user_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

User _user({int modelVersion = 0}) => User(
      userId: 'U1',
      name: 'Alice',
      faceTemplates: const <Float32List>[],
      isActive: true,
      modelVersion: modelVersion,
    );

Widget _harness(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets(
      'stale-version user → re-enroll banner visible + primary "Re-enroll now" CTA',
      (tester) async {
    // modelVersion 0 = "legacy / pre-v3" → User.requiresReEnroll is true.
    final user = _user(modelVersion: 0);
    await tester.pumpWidget(_harness(
      UserDetailSheet(
        user: user,
        onSaveName: (_) {},
        onReEnroll: () {},
        onDelete: () {},
      ),
    ));

    expect(
      find.textContaining('enrolled with a previous face model'),
      findsOneWidget,
      reason: 'The re-enroll banner must be visible for stale-version users.',
    );
    // Primary CTA copy is "Re-enroll now" (FilledButton), not the default
    // "Re-enroll" outlined button used for current-version users.
    expect(find.text('Re-enroll now'), findsOneWidget);
    expect(find.text('Re-enroll'), findsNothing);
    // Delete moves to a less-prominent text button labelled "Delete instead".
    expect(find.text('Delete instead'), findsOneWidget);
  });

  testWidgets('current-version user → no banner, normal action row',
      (tester) async {
    final user = _user(modelVersion: FaceThresholds.modelVersion);
    await tester.pumpWidget(_harness(
      UserDetailSheet(
        user: user,
        onSaveName: (_) {},
        onReEnroll: () {},
        onDelete: () {},
      ),
    ));

    expect(
      find.textContaining('enrolled with a previous face model'),
      findsNothing,
      reason:
          'Current-version users must not see the re-enrolment warning banner.',
    );
    // Default action row: outlined Re-enroll + outlined Delete buttons.
    expect(find.text('Re-enroll'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Re-enroll now'), findsNothing);
    expect(find.text('Delete instead'), findsNothing);
  });

  testWidgets('Re-enroll CTA invokes the callback', (tester) async {
    var reEnrollCount = 0;
    final user = _user(modelVersion: 0);
    await tester.pumpWidget(_harness(
      UserDetailSheet(
        user: user,
        onSaveName: (_) {},
        onReEnroll: () => reEnrollCount++,
        onDelete: () {},
      ),
    ));

    await tester.tap(find.text('Re-enroll now'));
    await tester.pump();
    expect(reEnrollCount, 1);
  });
}
