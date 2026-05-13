import 'package:face_ios_android/core/diagnostics/pad_calibration.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a sample fixture of N real users (score 0.1) and N spoof
/// attempts (score 0.9) — the canonical "clean separation" case.
List<PadCalibrationSample> _wellSeparated(int n) {
  return <PadCalibrationSample>[
    for (var i = 0; i < n; i++)
      const PadCalibrationSample(padScore: 0.1, isSpoof: false),
    for (var i = 0; i < n; i++)
      const PadCalibrationSample(padScore: 0.9, isSpoof: true),
  ];
}

void main() {
  group('PadCalibration.sweepThresholds', () {
    test('empty input → empty sweep', () {
      expect(PadCalibration.sweepThresholds(const []), isEmpty);
    });

    test('default steps produces 21 evenly-spaced points', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(10));
      expect(sweep.length, 21);
      expect(sweep.first.threshold, 0.0);
      expect(sweep.last.threshold, 1.0);
      // Strictly increasing across the sweep.
      for (var i = 1; i < sweep.length; i++) {
        expect(sweep[i].threshold, greaterThan(sweep[i - 1].threshold));
      }
    });

    test('well-separated data → zero FRR + zero FAR at midpoint', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(20));
      // Find the threshold closest to 0.5.
      final mid = sweep.firstWhere((p) => (p.threshold - 0.5).abs() < 0.03);
      expect(mid.falseRejectRate, 0.0,
          reason: 'reals at 0.1 are all below threshold');
      expect(mid.falseAcceptRate, 0.0,
          reason: 'spoofs at 0.9 are all above threshold');
    });

    test('threshold 0 denies every real user (FRR = 1)', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(10));
      // Threshold 0: padScore > 0 → every real user (score 0.1) denied.
      final t0 = sweep.first;
      expect(t0.threshold, 0.0);
      expect(t0.falseRejectRate, 1.0);
      expect(t0.falseAcceptRate, 0.0);
    });

    test('threshold 1.0 grants every spoof (FAR = 1)', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(10));
      final t1 = sweep.last;
      expect(t1.threshold, 1.0);
      expect(t1.falseRejectRate, 0.0);
      expect(t1.falseAcceptRate, 1.0,
          reason: 'no spoof score exceeds 1.0 strictly');
    });

    test('totals are stable across the sweep', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(7));
      for (final p in sweep) {
        expect(p.realTotal, 7);
        expect(p.spoofTotal, 7);
      }
    });

    test('steps < 2 throws ArgumentError', () {
      expect(
        () => PadCalibration.sweepThresholds(_wellSeparated(1), steps: 1),
        throwsArgumentError,
      );
    });

    test('threshold semantics: strict > not ≥', () {
      // A real sample exactly at threshold 0.5 passes; a spoof exactly
      // at 0.5 also passes (FAR contributes by 1).
      final samples = <PadCalibrationSample>[
        const PadCalibrationSample(padScore: 0.5, isSpoof: false),
        const PadCalibrationSample(padScore: 0.5, isSpoof: true),
      ];
      final sweep = PadCalibration.sweepThresholds(samples, steps: 11);
      final at05 = sweep.firstWhere((p) => (p.threshold - 0.5).abs() < 1e-9);
      expect(at05.falseRejectRate, 0.0, reason: 'real at 0.5 ≤ threshold');
      expect(at05.falseAcceptRate, 1.0, reason: 'spoof at 0.5 ≤ threshold');
    });
  });

  group('PadCalibration.pickThresholdForMaxFar', () {
    test('returns null when nothing meets the bound', () {
      final samples = <PadCalibrationSample>[
        // 4 spoofs all at score 0; FAR=1 at every threshold ≥ 0.
        const PadCalibrationSample(padScore: 0.0, isSpoof: true),
        const PadCalibrationSample(padScore: 0.0, isSpoof: true),
        const PadCalibrationSample(padScore: 0.0, isSpoof: true),
        const PadCalibrationSample(padScore: 0.0, isSpoof: true),
      ];
      final sweep = PadCalibration.sweepThresholds(samples);
      expect(PadCalibration.pickThresholdForMaxFar(sweep, 0.1), isNull);
    });

    test('picks lowest-FRR point under the FAR cap', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(20));
      // FAR ≤ 0.05 — well-separated data satisfies this anywhere
      // from threshold 0.1 up to 0.85.
      final pick = PadCalibration.pickThresholdForMaxFar(sweep, 0.05);
      expect(pick, isNotNull);
      expect(pick!.falseAcceptRate, lessThanOrEqualTo(0.05));
      expect(pick.falseRejectRate, 0.0,
          reason: 'well-separated → FRR achievable at 0');
    });

    test('tie-break prefers the higher threshold (more permissive)', () {
      // Two thresholds both produce FRR 0 and FAR ≤ 0.05.
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(10));
      final pick = PadCalibration.pickThresholdForMaxFar(sweep, 0.05);
      expect(pick!.threshold, greaterThan(0.5),
          reason: 'should prefer the higher (more permissive) cutoff');
    });
  });

  group('PadCalibration.distribution', () {
    test('empty input → zeroed-out summary', () {
      final d = PadCalibration.distribution(const []);
      expect(d.count, 0);
      expect(d.mean, 0);
    });

    test('uniform-spread input → expected percentiles', () {
      // 11 scores at 0.0, 0.1, …, 1.0.
      final samples = <PadCalibrationSample>[
        for (var i = 0; i <= 10; i++)
          PadCalibrationSample(padScore: i / 10.0, isSpoof: false),
      ];
      final d = PadCalibration.distribution(samples);
      expect(d.count, 11);
      expect(d.mean, closeTo(0.5, 1e-9));
      expect(d.p50, closeTo(0.5, 1e-9));
      expect(d.p90, closeTo(0.9, 1e-9));
    });

    test('bimodal distribution shows the gap (real vs spoof crowd)', () {
      // 80 real users at 0.05 + 20 spoof attempts at 0.95 — the
      // typical field shape, where the real population is the
      // majority. Median lands in the real cluster; tail picks up
      // the spoof cluster.
      final samples = <PadCalibrationSample>[
        for (var i = 0; i < 80; i++)
          const PadCalibrationSample(padScore: 0.05, isSpoof: false),
        for (var i = 0; i < 20; i++)
          const PadCalibrationSample(padScore: 0.95, isSpoof: true),
      ];
      final d = PadCalibration.distribution(samples);
      expect(d.p50, closeTo(0.05, 1e-9),
          reason: 'median lands in the real-user cluster');
      expect(d.p99, closeTo(0.95, 1e-9),
          reason: 'tail picks up the spoof cluster');
    });
  });

  group('PadCalibration.samplesFromLogs', () {
    VerificationLog log({
      required String outcome,
      double? padScore,
    }) =>
        VerificationLog(
          userId: 'u',
          at: DateTime(2026, 5, 13),
          outcome: outcome,
          latencyMs: 50,
          padScore: padScore,
        );

    test('granted with score → real proxy sample', () {
      final samples = PadCalibration.samplesFromLogs([
        log(outcome: VerificationOutcome.granted, padScore: 0.2),
      ]);
      expect(samples, hasLength(1));
      expect(samples.first.padScore, 0.2);
      expect(samples.first.isSpoof, isFalse);
    });

    test('spoof outcome → spoof proxy sample', () {
      final samples = PadCalibration.samplesFromLogs([
        log(outcome: VerificationOutcome.spoof, padScore: 0.7),
      ]);
      expect(samples, hasLength(1));
      expect(samples.first.isSpoof, isTrue);
    });

    test('denied / error / timeout / rateLimited → skipped', () {
      final logs = <VerificationLog>[
        log(outcome: VerificationOutcome.denied, padScore: 0.3),
        log(outcome: VerificationOutcome.error, padScore: 0.0),
        log(outcome: VerificationOutcome.timeout, padScore: null),
        log(outcome: VerificationOutcome.rateLimited, padScore: 0.5),
      ];
      expect(PadCalibration.samplesFromLogs(logs), isEmpty);
    });

    test('null padScore skipped by default', () {
      final samples = PadCalibration.samplesFromLogs([
        log(outcome: VerificationOutcome.granted, padScore: null),
      ]);
      expect(samples, isEmpty);
    });

    test('null padScore optionally included as 0.0', () {
      final samples = PadCalibration.samplesFromLogs(
        [log(outcome: VerificationOutcome.granted, padScore: null)],
        includeNullPadScore: true,
      );
      expect(samples, hasLength(1));
      expect(samples.first.padScore, 0.0);
      expect(samples.first.isSpoof, isFalse);
    });

    test('out-of-range padScore is clamped to [0, 1]', () {
      final samples = PadCalibration.samplesFromLogs([
        log(outcome: VerificationOutcome.granted, padScore: -0.3),
        log(outcome: VerificationOutcome.spoof, padScore: 1.7),
      ]);
      expect(samples[0].padScore, 0.0);
      expect(samples[1].padScore, 1.0);
    });
  });

  group('PadCalibration.sweepAsCsv', () {
    test('produces a header + one row per sweep point', () {
      final sweep = PadCalibration.sweepThresholds(_wellSeparated(2), steps: 3);
      final csv = PadCalibration.sweepAsCsv(sweep);
      final lines = csv.trim().split('\n');
      expect(lines.first, 'threshold,frr,far,real_total,spoof_total');
      expect(lines.length, 1 + 3);
    });
  });
}
