@TestOn('vm')
library;

import 'package:face_ios_android/features/face_verification/presentation/controllers/user_management_controller.dart';
import 'package:face_ios_android/features/face_verification/presentation/screens/user_management_screen.dart';
import 'package:face_ios_android/features/face_verification/presentation/view_models/user_management_row_vm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

GoRouter _router() => GoRouter(
      initialLocation: '/manage',
      routes: <RouteBase>[
        GoRoute(
          path: '/manage',
          builder: (_, _) => const UserManagementScreen(),
        ),
        GoRoute(
          path: '/enroll',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('Enroll route'))),
        ),
      ],
    );

void main() {
  testWidgets('empty state shows the "Enroll your first user" CTA',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          userManagementRowsProvider.overrideWith(
            (_) => Stream<List<UserManagementRowVm>>.value(
              const <UserManagementRowVm>[],
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No users enrolled'), findsOneWidget);
    expect(find.text('Enroll your first user'), findsOneWidget);
    expect(find.byIcon(Icons.person_off_outlined), findsOneWidget);
  });

  testWidgets('loading state shows a progress indicator', (tester) async {
    final completer = _PendingStream<List<UserManagementRowVm>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          userManagementRowsProvider.overrideWith((_) => completer.stream),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump(); // first frame; stream still empty
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

/// Stream that never emits — used to pin the screen in `loading` state.
class _PendingStream<T> {
  Stream<T> get stream async* {
    // Intentionally never yields.
  }
}
