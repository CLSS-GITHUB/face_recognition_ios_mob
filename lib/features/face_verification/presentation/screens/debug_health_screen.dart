import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Variable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/platform/security_check.dart';

/// Snapshot of the on-device pipeline at a moment in time. Built once
/// per screen build (the provider is `autoDispose`) so revisiting the
/// page after, say, adding a user, shows the fresh counts.
class DebugHealthReport {
  const DebugHealthReport({
    required this.collectedAt,
    required this.schemaVersion,
    required this.userCountTotal,
    required this.userCountActive,
    required this.userCountRequiresReEnroll,
    required this.logCountTotal,
    required this.logCountLast24h,
    required this.isolateReady,
    required this.isolateError,
    required this.isolateDelegate,
    required this.padLabel,
    required this.cameraPermissionGranted,
    required this.security,
    required this.thresholds,
    required this.recentLogs,
  });

  final DateTime collectedAt;

  final int schemaVersion;
  final int userCountTotal;
  final int userCountActive;
  final int userCountRequiresReEnroll;
  final int logCountTotal;
  final int logCountLast24h;

  /// `true` when the embedding isolate is alive, `false` when its
  /// spawn future errored, `null` when still spawning. The screen
  /// gates its readout on this so a still-spawning isolate doesn't
  /// look like a failure.
  final bool? isolateReady;
  final String? isolateError;

  /// Identifier of the TFLite execution path actually selected at
  /// spawn time. `null` while the isolate is still spawning (so the
  /// row reads as "spawning…" in concert with [isolateReady]).
  /// See [EmbeddingIsolate.delegateLabel] for the format.
  final String? isolateDelegate;

  /// F-10 scaffold: identifier of the PAD (Presentation Attack
  /// Detection) classifier currently wired. Stable values:
  /// `"noop"` when PAD_ENABLED is off OR the spawn fell back;
  /// `"isolate(pending)"` while the PAD isolate is still spawning;
  /// `"isolate(<model-fingerprint>)"` once it's live.
  final String padLabel;

  final bool cameraPermissionGranted;
  final SecurityStatus security;

  /// Subset of FaceThresholds values useful to the field. Snapshot
  /// here so a build's calibration is recoverable from a screenshot.
  final Map<String, Object?> thresholds;

  /// At most 10 most-recent verification_logs rows, newest first.
  /// Lets the team see what the user has tried recently without
  /// needing a database extract.
  final List<DebugRecentLog> recentLogs;

  Map<String, Object?> toJson() => <String, Object?>{
        'collectedAt': collectedAt.toIso8601String(),
        'schemaVersion': schemaVersion,
        'users': <String, int>{
          'total': userCountTotal,
          'active': userCountActive,
          'requiresReEnroll': userCountRequiresReEnroll,
        },
        'verificationLogs': <String, int>{
          'total': logCountTotal,
          'last24h': logCountLast24h,
        },
        'embeddingIsolate': <String, Object?>{
          'ready': isolateReady,
          'error': isolateError,
          'delegate': isolateDelegate,
        },
        'pad': <String, Object?>{
          'classifier': padLabel,
        },
        'cameraPermissionGranted': cameraPermissionGranted,
        'security': <String, bool>{
          'rooted': security.rooted,
          'emulator': security.emulator,
          'compromised': security.isCompromised,
        },
        'thresholds': thresholds,
        'recentLogs': recentLogs.map((r) => r.toJson()).toList(),
      };
}

class DebugRecentLog {
  const DebugRecentLog({
    required this.at,
    required this.outcome,
    required this.userId,
    required this.failureReason,
    required this.bestSimilarity,
    required this.latencyMs,
  });

  final DateTime at;
  final String outcome;
  final String? userId;
  final String? failureReason;
  final double? bestSimilarity;
  final int latencyMs;

  Map<String, Object?> toJson() => <String, Object?>{
        // Drift's epoch-seconds round-trip drops the original timezone,
        // so [at] comes back as a local-zone DateTime even though
        // production writes go through UTC. Normalise to UTC here so
        // the exported JSON is unambiguously comparable to the
        // collectedAt UTC stamp at the top of the report.
        'at': at.toUtc().toIso8601String(),
        'outcome': outcome,
        'userId': userId,
        'failureReason': failureReason,
        'bestSimilarity': bestSimilarity,
        'latencyMs': latencyMs,
      };
}

/// Collects every piece of state surfaced by [DebugHealthScreen]. Kept
/// to a single shot per screen build so it doesn't auto-refresh and
/// fight a debugger trying to read it.
final debugHealthReportProvider =
    FutureProvider.autoDispose<DebugHealthReport>((ref) async {
  final db = ref.watch(dbProvider);
  final repo = ref.watch(userRepositoryProvider);

  // Users — fetch through the repository so the encrypted blob and
  // `requiresReEnroll` (model + age) verdict are evaluated identically
  // to the matching pipeline.
  final users = await repo.getAll();
  final activeUsers = users.where((u) => u.isActive).toList(growable: false);
  final requiresReEnroll =
      users.where((u) => u.requiresReEnroll).length;

  // Verification logs — quick aggregate counts via raw SQL. Avoids
  // adding a dao method just for the debug surface.
  final logTotalRow = await db
      .customSelect('SELECT COUNT(*) AS c FROM verification_logs')
      .getSingle();
  final logTotal = logTotalRow.read<int>('c');

  final since = DateTime.now().toUtc().subtract(const Duration(hours: 24));
  final log24hRow = await db.customSelect(
    'SELECT COUNT(*) AS c FROM verification_logs WHERE at >= ?',
    variables: <Variable>[Variable.withDateTime(since)],
  ).getSingle();
  final log24h = log24hRow.read<int>('c');

  // Recent 10 — newest first. Drift returns the row mapper for free
  // via select(...).get() on the table.
  final recentRows = await (db.select(db.verificationLogs)
        ..orderBy([(t) => OrderingTerm.desc(t.at)])
        ..limit(10))
      .get();
  final recentLogs = recentRows
      .map((r) => DebugRecentLog(
            at: r.at,
            outcome: r.outcome,
            userId: r.userId,
            failureReason: r.failureReason,
            bestSimilarity: r.bestSimilarity,
            latencyMs: r.latencyMs,
          ))
      .toList(growable: false);

  // Embedding isolate — read the AsyncValue *without* awaiting the
  // future, so the page renders even when the spawn is still pending.
  // We then surface the current state as a tri-state (ready / error /
  // spawning).
  final isolateAsync = ref.watch(embeddingIsolateProvider);
  final isolateReady = isolateAsync.maybeWhen(
    data: (_) => true,
    error: (_, _) => false,
    orElse: () => null,
  );
  final isolateError = isolateAsync.maybeWhen(
    error: (e, _) => e.toString(),
    orElse: () => null,
  );
  final isolateDelegate = isolateAsync.maybeWhen(
    data: (iso) => iso.delegateLabel,
    orElse: () => null,
  );

  final cameraGranted =
      ref.watch(cameraPermissionProvider).valueOrNull ?? false;
  final security = await ref.watch(securityStatusProvider.future);

  return DebugHealthReport(
    collectedAt: DateTime.now().toUtc(),
    schemaVersion: db.schemaVersion,
    userCountTotal: users.length,
    userCountActive: activeUsers.length,
    userCountRequiresReEnroll: requiresReEnroll,
    logCountTotal: logTotal,
    logCountLast24h: log24h,
    isolateReady: isolateReady,
    isolateError: isolateError,
    isolateDelegate: isolateDelegate,
    padLabel: ref.watch(padClassifierProvider).label,
    cameraPermissionGranted: cameraGranted,
    security: security,
    thresholds: _thresholdsSnapshot(),
    recentLogs: recentLogs,
  );
});

/// Subset of [FaceThresholds] that field debugging actually cares
/// about. Keeping this hand-rolled (vs. dart-mirrors-style reflection)
/// keeps the snapshot honest about which knobs are deployment-tunable.
Map<String, Object?> _thresholdsSnapshot() => <String, Object?>{
      'embeddingDim': FaceThresholds.embeddingDim,
      'modelVersion': FaceThresholds.modelVersion,
      'verifyThreshold': FaceThresholds.verifyThreshold,
      'verifyUserMargin': FaceThresholds.verifyUserMargin,
      'duplicateFaceThreshold': FaceThresholds.duplicateFaceThreshold,
      'templateDedupThreshold': FaceThresholds.templateDedupThreshold,
      'templateMaxAgeDays': FaceThresholds.templateMaxAgeDays,
      'verificationLogRetentionDays':
          FaceThresholds.verificationLogRetentionDays,
      'maxTemplatesPerUserMatched':
          FaceThresholds.maxTemplatesPerUserMatched,
      'replayMotionMaxStdPx': FaceThresholds.replayMotionMaxStdPx,
      'replayDeviceMotionMaxStd': FaceThresholds.replayDeviceMotionMaxStd,
      'rateLimitMaxFailures': FaceThresholds.rateLimitMaxFailures,
      'rateLimitWindowMs': FaceThresholds.rateLimitWindowMs,
      'rateLimitCooldownMs': FaceThresholds.rateLimitCooldownMs,
    };

/// Debug-only "is the pipeline healthy?" page. Wired at `/debug/health`
/// in [router.dart] under a `kDebugMode` guard.
class DebugHealthScreen extends ConsumerWidget {
  const DebugHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(debugHealthReportProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug · Health'),
        actions: [
          IconButton(
            tooltip: 'Copy as JSON',
            icon: const Icon(Icons.copy_all),
            onPressed: () async {
              final report = async.valueOrNull;
              if (report == null) return;
              await Clipboard.setData(ClipboardData(
                text: const JsonEncoder.withIndent('  ')
                    .convert(report.toJson()),
              ));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Health report copied to clipboard.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(debugHealthReportProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Health report failed:\n$e\n\n$st',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
        data: (report) => _ReportBody(report: report),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report});

  final DebugHealthReport report;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Collected',
          children: [_kv('At (UTC)', report.collectedAt.toIso8601String())],
        ),
        _Section(
          title: 'Database',
          children: [
            _kv('Schema version', '${report.schemaVersion}'),
            _kv('Users (total)', '${report.userCountTotal}'),
            _kv('Users (active)', '${report.userCountActive}'),
            _kv('Users (needs re-enroll)',
                '${report.userCountRequiresReEnroll}'),
            _kv('Verification logs (total)', '${report.logCountTotal}'),
            _kv('Verification logs (24h)', '${report.logCountLast24h}'),
          ],
        ),
        _Section(
          title: 'Embedding isolate',
          children: [
            _kv(
              'State',
              switch (report.isolateReady) {
                true => 'ready',
                false => 'error',
                null => 'spawning…',
              },
            ),
            _kv('TFLite delegate', report.isolateDelegate ?? 'spawning…'),
            _kv('PAD classifier', report.padLabel),
            if (report.isolateError != null)
              _kv('Error', report.isolateError!),
          ],
        ),
        _Section(
          title: 'Permissions & security',
          children: [
            _kv('Camera permission',
                report.cameraPermissionGranted ? 'granted' : 'denied'),
            _kv('Rooted', report.security.rooted ? 'yes' : 'no'),
            _kv('Emulator', report.security.emulator ? 'yes' : 'no'),
            _kv('Compromised',
                report.security.isCompromised ? 'YES' : 'no'),
          ],
        ),
        _Section(
          title: 'Thresholds',
          children: [
            for (final entry in report.thresholds.entries)
              _kv(entry.key, '${entry.value}'),
          ],
        ),
        _Section(
          title: 'Recent verification logs',
          children: report.recentLogs.isEmpty
              ? [const Text('(no logs)')]
              : [
                  for (final log in report.recentLogs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        // `.toUtc()` keeps each row's timestamp in the
                        // same timezone basis as the `Collected At
                        // (UTC)` field at the top of the report — Drift
                        // would otherwise render a UTC-stored moment
                        // back as a local-zone string with no Z suffix.
                        '${log.at.toUtc().toIso8601String()}  '
                        '${log.outcome.padRight(8)}  '
                        'user=${log.userId ?? "—"}  '
                        'sim=${log.bestSimilarity?.toStringAsFixed(3) ?? "—"}  '
                        '${log.latencyMs}ms'
                        '${log.failureReason != null ? "  reason=${log.failureReason}" : ""}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Text(k,
                  style: const TextStyle(fontFamily: 'monospace')),
            ),
            Expanded(
              flex: 7,
              child: Text(v,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  )),
            ),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
          const SizedBox(height: 6),
          const Divider(height: 1),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}
