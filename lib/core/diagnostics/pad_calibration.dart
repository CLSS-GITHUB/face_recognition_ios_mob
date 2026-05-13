import '../../features/face_verification/domain/entities/verification_log.dart';

/// B1/B2 enabler: pure-Dart calibration helpers for the passive PAD
/// classifier's spoof-score threshold.
///
/// **Why this exists.** `FaceThresholds.padSpoofThreshold` ships with a
/// placeholder default (0.5). Flipping `PadPolicy` to `enforce`
/// without first running the threshold against real deployment data
/// either over-rejects users (FRR regression) or under-rejects
/// attacks (no security benefit). The procurement runbook
/// (`docs/verification/pad_checkpoint_procurement.md` §6) describes
/// the loop; this file is the maths.
///
/// **What it does.** Takes a list of [PadCalibrationSample] —
/// `(padScore, isSpoof)` tuples assembled from CSV exports of
/// `verification_logs` — and produces:
///
///   1. A threshold sweep with FRR / FAR at each candidate cutoff,
///      so the operator can pick the operating point that meets the
///      deployment's risk envelope (typical: FRR ≤ 1%, FAR ≤ 5%).
///   2. A score-distribution summary for the case where ground-truth
///      labels are not available — useful for spotting bimodality
///      and proposing rough cutoffs before the security team has
///      labelled attempts.
///
/// Stateless, no I/O, no platform deps — runs in the same Dart VM
/// as the unit tests so calibration can be exercised in CI on
/// synthetic data.

/// One row of calibration data. Built from a [VerificationLog] row
/// plus an external ground-truth flag (was this attempt actually
/// from a live face, or from a print / replay attack).
class PadCalibrationSample {
  const PadCalibrationSample({
    required this.padScore,
    required this.isSpoof,
  });

  /// PAD spoof score in `[0, 1]`. `0` = real, `1` = strong spoof.
  final double padScore;

  /// Ground truth. `true` if the attempt was actually adversarial
  /// (print, replay, mask). `false` if it was a real user.
  /// Sourced outside this code — typically a security-team field
  /// study that annotates attempts post-hoc.
  final bool isSpoof;
}

/// One row of a threshold-sweep curve.
class PadThresholdPoint {
  const PadThresholdPoint({
    required this.threshold,
    required this.falseRejectRate,
    required this.falseAcceptRate,
    required this.realTotal,
    required this.spoofTotal,
  });

  /// Candidate cutoff. An attempt is treated as "denied by PAD" when
  /// `padScore > threshold`.
  final double threshold;

  /// `denied_real / real_total`. Real users this cutoff would have
  /// wrongly stopped.
  final double falseRejectRate;

  /// `granted_spoof / spoof_total`. Adversarial attempts this cutoff
  /// would have wrongly let through.
  final double falseAcceptRate;

  final int realTotal;
  final int spoofTotal;
}

/// Summary of a score distribution at named percentiles. Useful when
/// ground-truth labels aren't yet available — the operator can pick
/// a rough cutoff based on where the bulk of the population sits.
class PadScoreDistribution {
  const PadScoreDistribution({
    required this.count,
    required this.mean,
    required this.p50,
    required this.p90,
    required this.p95,
    required this.p99,
  });

  final int count;
  final double mean;
  final double p50;
  final double p90;
  final double p95;
  final double p99;
}

class PadCalibration {
  PadCalibration._();

  /// Computes the FRR/FAR sweep over [samples] for [steps] candidate
  /// thresholds linearly spaced across `[0, 1]`. A `steps` of 21
  /// produces cutoffs at 0.00, 0.05, 0.10, …, 1.00 — the granularity
  /// the runbook's calibration step suggests.
  ///
  /// Returns an empty list if [samples] is empty.
  ///
  /// Threshold semantics match `verification_controller.dart`'s gate:
  /// an attempt is "denied by PAD" when `padScore > threshold`.
  /// Strictly greater, not ≥ — a sample exactly at the threshold
  /// passes. Matches the existing
  /// `FaceThresholds.padSpoofThreshold` comparison so the sweep's
  /// recommended cutoff is directly droppable into production.
  static List<PadThresholdPoint> sweepThresholds(
    List<PadCalibrationSample> samples, {
    int steps = 21,
  }) {
    if (samples.isEmpty) return const <PadThresholdPoint>[];
    if (steps < 2) {
      throw ArgumentError.value(steps, 'steps', 'must be ≥ 2');
    }

    var realTotal = 0;
    var spoofTotal = 0;
    for (final s in samples) {
      if (s.isSpoof) {
        spoofTotal++;
      } else {
        realTotal++;
      }
    }

    final out = <PadThresholdPoint>[];
    for (var i = 0; i < steps; i++) {
      final t = i / (steps - 1);
      var realDenied = 0;
      var spoofGranted = 0;
      for (final s in samples) {
        final deniedByPad = s.padScore > t;
        if (s.isSpoof) {
          if (!deniedByPad) spoofGranted++;
        } else {
          if (deniedByPad) realDenied++;
        }
      }
      out.add(PadThresholdPoint(
        threshold: t,
        falseRejectRate: realTotal == 0 ? 0.0 : realDenied / realTotal,
        falseAcceptRate: spoofTotal == 0 ? 0.0 : spoofGranted / spoofTotal,
        realTotal: realTotal,
        spoofTotal: spoofTotal,
      ));
    }
    return out;
  }

  /// Picks the threshold from a [sweep] that minimises FRR subject to
  /// `falseAcceptRate ≤ maxFar`, or `null` when no candidate clears
  /// the bound. Ties are broken by choosing the highest threshold
  /// (most permissive — biased toward letting users in).
  ///
  /// Typical use:
  ///   ```dart
  ///   final sweep = PadCalibration.sweepThresholds(samples);
  ///   final pick = PadCalibration.pickThresholdForMaxFar(sweep, 0.05);
  ///   ```
  /// The runbook §6 step 3 calls this with the target FAR for the
  /// deployment's risk envelope.
  static PadThresholdPoint? pickThresholdForMaxFar(
    List<PadThresholdPoint> sweep,
    double maxFar,
  ) {
    PadThresholdPoint? best;
    for (final p in sweep) {
      if (p.falseAcceptRate > maxFar) continue;
      if (best == null) {
        best = p;
        continue;
      }
      // Lower FRR wins. Equal FRR → higher threshold wins
      // (more permissive).
      if (p.falseRejectRate < best.falseRejectRate ||
          (p.falseRejectRate == best.falseRejectRate &&
              p.threshold > best.threshold)) {
        best = p;
      }
    }
    return best;
  }

  /// Distribution summary of just the PAD scores — for the case where
  /// ground-truth labels haven't been collected yet. Useful for
  /// spotting bimodality in the score distribution (real population
  /// near 0, spoof population near 1 → clear separation, calibration
  /// likely to work well; flat distribution → model is uninformative
  /// for this device population, escalate before flipping enforce).
  static PadScoreDistribution distribution(
    List<PadCalibrationSample> samples,
  ) {
    if (samples.isEmpty) {
      return const PadScoreDistribution(
        count: 0,
        mean: 0,
        p50: 0,
        p90: 0,
        p95: 0,
        p99: 0,
      );
    }
    final scores = <double>[for (final s in samples) s.padScore]..sort();
    final n = scores.length;
    var sum = 0.0;
    for (final s in scores) {
      sum += s;
    }
    double percentile(double q) {
      // Nearest-rank percentile — matches numpy.percentile's
      // `method='lower'`. With n=1 every percentile is the single
      // sample.
      final idx = (q * (n - 1)).round().clamp(0, n - 1);
      return scores[idx];
    }

    return PadScoreDistribution(
      count: n,
      mean: sum / n,
      p50: percentile(0.50),
      p90: percentile(0.90),
      p95: percentile(0.95),
      p99: percentile(0.99),
    );
  }

  /// Convenience: build calibration samples from
  /// [VerificationLog] rows in *proxy mode* — when ground-truth
  /// labels aren't available, we approximate `isSpoof = true` for
  /// rows whose outcome was `spoof` (any anti-spoof gate fired,
  /// including the new Gabor + screen-reflection + motion stack)
  /// and `isSpoof = false` for rows whose outcome was `granted`.
  /// All other outcomes (`denied`, `error`, `timeout`,
  /// `rateLimited`) are skipped — too noisy to label.
  ///
  /// **Important caveat**: this is a proxy. The `spoof` outcome
  /// includes denials by motion/screen-reflection/Gabor gates, not
  /// just PAD-actual-attacks. The proxy over-estimates the "spoof
  /// population" and underestimates FAR for the PAD model
  /// specifically. Use this for early exploration only;
  /// run the security-team-labelled study before flipping
  /// `PadPolicy` to enforce.
  static List<PadCalibrationSample> samplesFromLogs(
    Iterable<VerificationLog> logs, {
    bool includeNullPadScore = false,
  }) {
    final out = <PadCalibrationSample>[];
    for (final log in logs) {
      final score = log.padScore;
      if (score == null) {
        if (!includeNullPadScore) continue;
        // The verify pipeline persists 0.0 when PAD couldn't run on
        // an attempt that reached the PAD step; null when PAD wasn't
        // reached at all. Treat null as score 0 for the operator
        // who opted in.
        out.add(PadCalibrationSample(padScore: 0, isSpoof: _proxyIsSpoof(log)));
        continue;
      }
      if (log.outcome != VerificationOutcome.granted &&
          log.outcome != VerificationOutcome.spoof) {
        continue;
      }
      out.add(PadCalibrationSample(
        padScore: score.clamp(0.0, 1.0).toDouble(),
        isSpoof: _proxyIsSpoof(log),
      ));
    }
    return out;
  }

  static bool _proxyIsSpoof(VerificationLog log) {
    return log.outcome == VerificationOutcome.spoof;
  }

  /// Pretty-print a sweep result as a CSV string. The runbook's
  /// step 3 invocation can pipe the output of this function into
  /// any plotting tool (Python / Sheets / DataDog) for visual
  /// inspection of the FRR/FAR curve.
  static String sweepAsCsv(List<PadThresholdPoint> sweep) {
    final buf = StringBuffer('threshold,frr,far,real_total,spoof_total\n');
    for (final p in sweep) {
      buf
        ..write(p.threshold.toStringAsFixed(3))
        ..write(',')
        ..write(p.falseRejectRate.toStringAsFixed(6))
        ..write(',')
        ..write(p.falseAcceptRate.toStringAsFixed(6))
        ..write(',')
        ..write(p.realTotal)
        ..write(',')
        ..write(p.spoofTotal)
        ..write('\n');
    }
    return buf.toString();
  }
}
