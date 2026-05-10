import 'dart:typed_data';

import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:face_ios_android/features/face_verification/presentation/dialogs/verification_result_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

User _user(String name) => User(
      userId: 'U1',
      name: name,
      faceTemplates: const <Float32List>[],
      isActive: true,
    );

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  testWidgets('granted: shows user name and Access Granted title',
      (tester) async {
    await _pump(
      tester,
      VerificationResultDialog(
        matched: _user('John Doe'),
        onDismiss: () {},
      ),
    );
    expect(find.text('Access Granted'), findsOneWidget);
    expect(find.text('Identity confirmed for John Doe.'), findsOneWidget);
    expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);
  });

  testWidgets('denied: shows Access Denied title and generic copy',
      (tester) async {
    await _pump(
      tester,
      VerificationResultDialog(
        matched: null,
        onDismiss: () {},
      ),
    );
    expect(find.text('Access Denied'), findsOneWidget);
    expect(
      find.text('Face does not match any enrolled user.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
  });

  testWidgets('OK button calls onDismiss', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      VerificationResultDialog(
        matched: _user('Alice'),
        onDismiss: () => calls++,
      ),
    );
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(calls, 1);
  });
}
