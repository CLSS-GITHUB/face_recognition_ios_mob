import 'dart:typed_data';

import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:face_ios_android/features/face_verification/presentation/dialogs/verification_result_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

User _user(String name) => User(
      userId: 'EMP-001',
      name: name,
      faceTemplates: const <Float32List>[],
      isActive: true,
    );

Widget _harness(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFFEFEFEF),
      body: Center(child: SizedBox(width: 360, child: child)),
    ),
  );
}

void main() {
  testWidgets('granted dialog matches golden', (tester) async {
    await tester.pumpWidget(_harness(
      VerificationResultPanel(
        matched: _user('John Doe'),
        onDismiss: () {},
      ),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/verification_result_dialog_granted.png'),
    );
  });

  testWidgets('denied dialog matches golden', (tester) async {
    await tester.pumpWidget(_harness(
      VerificationResultPanel(
        matched: null,
        onDismiss: () {},
      ),
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/verification_result_dialog_denied.png'),
    );
  });
}
