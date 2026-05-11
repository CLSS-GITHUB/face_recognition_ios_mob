import 'dart:async';

import 'package:face_ios_android/core/platform/security_check.dart';
import 'package:face_ios_android/features/face_verification/presentation/screens/debug_health_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DebugHealthReport _stubReport({bool requiresReEnroll = false}) =>
    DebugHealthReport(
      collectedAt: DateTime.utc(2026, 5, 11, 10, 30),
      schemaVersion: 4,
      userCountTotal: 3,
      userCountActive: 2,
      userCountRequiresReEnroll: requiresReEnroll ? 1 : 0,
      logCountTotal: 42,
      logCountLast24h: 7,
      isolateReady: true,
      isolateError: null,
      cameraPermissionGranted: true,
      security: const SecurityStatus(rooted: false, emulator: false),
      thresholds: const <String, Object?>{
        'verifyThreshold': 0.75,
        'modelVersion': 1,
      },
      recentLogs: const <DebugRecentLog>[],
    );

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DebugHealthScreen()),
    );

/// Tall surface so every ListView section is laid out and findable
/// without scrolling. Default test surface is 800×600, which clips
/// the lower sections (Thresholds / Recent logs).
Future<void> _useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('renders every section header', (tester) async {
    await _useTallSurface(tester);
    final container = ProviderContainer(overrides: [
      debugHealthReportProvider.overrideWith((_) async => _stubReport()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    expect(find.text('Database'), findsOneWidget);
    expect(find.text('Embedding isolate'), findsOneWidget);
    expect(find.text('Permissions & security'), findsOneWidget);
    expect(find.text('Thresholds'), findsOneWidget);
    expect(find.text('Recent verification logs'), findsOneWidget);
  });

  testWidgets('Copy / Refresh actions are present in the AppBar',
      (tester) async {
    final container = ProviderContainer(overrides: [
      debugHealthReportProvider.overrideWith((_) async => _stubReport()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.copy_all), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('shows the user/log counts from the report', (tester) async {
    final container = ProviderContainer(overrides: [
      debugHealthReportProvider
          .overrideWith((_) async => _stubReport(requiresReEnroll: true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    // Spot-check a couple of values to verify the body renders from the
    // overridden report rather than a stale default.
    expect(find.text('3'), findsOneWidget); // total users
    expect(find.text('2'), findsOneWidget); // active users
    expect(find.text('1'), findsOneWidget); // requires re-enroll
    expect(find.text('42'), findsOneWidget); // total logs
    expect(find.text('7'), findsOneWidget); // 24h logs
  });

  testWidgets('shows (no logs) when recentLogs is empty', (tester) async {
    await _useTallSurface(tester);
    final container = ProviderContainer(overrides: [
      debugHealthReportProvider.overrideWith((_) async => _stubReport()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();

    expect(find.text('(no logs)'), findsOneWidget);
  });

  testWidgets('shows a loading indicator before the report resolves',
      (tester) async {
    // Build a Completer-backed override so we can keep the future
    // pending and observe the loading branch.
    final completer = Completer<DebugHealthReport>();
    final container = ProviderContainer(overrides: [
      debugHealthReportProvider.overrideWith((_) => completer.future),
    ]);
    addTearDown(() {
      if (!completer.isCompleted) completer.complete(_stubReport());
      container.dispose();
    });
    await tester.pumpWidget(_harness(container));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
