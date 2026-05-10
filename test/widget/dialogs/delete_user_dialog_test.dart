import 'package:face_ios_android/features/face_verification/presentation/dialogs/delete_user_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpDialog(WidgetTester tester, Widget dialog) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: dialog))),
  );
}

void main() {
  testWidgets('shows the user name in the prompt', (tester) async {
    await _pumpDialog(
      tester,
      DeleteUserDialog(userName: 'Alice', onConfirm: () {}),
    );
    expect(find.textContaining('Alice'), findsOneWidget);
    expect(find.text('Delete User'), findsOneWidget);
  });

  testWidgets('Cancel pops without calling onConfirm', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => DeleteUserDialog(
                    userName: 'Bob',
                    onConfirm: () => calls++,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete User'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete User'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('Delete button calls onConfirm', (tester) async {
    var calls = 0;
    await _pumpDialog(
      tester,
      DeleteUserDialog(userName: 'Carol', onConfirm: () => calls++),
    );
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(calls, 1);
  });
}
