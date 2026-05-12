/// One row of [verification_logs] flattened to the columns a calibration
/// study cares about. Built from the Drift row inside the debug-health
/// screen; kept as a plain data class here so the CSV serializer is
/// pure-Dart-testable without dragging Drift into the test environment.
///
/// `userId` is the FK to `users.userId` (a UUID), NOT the user's name —
/// the verification_logs table never stores names, so the export is
/// pseudonymous by construction.
class VerificationLogCsvRow {
  const VerificationLogCsvRow({
    required this.at,
    required this.outcome,
    required this.userId,
    required this.failureReason,
    required this.bestSimilarity,
    required this.padScore,
    required this.latencyMs,
  });

  final DateTime at;
  final String outcome;
  final String? userId;
  final String? failureReason;
  final double? bestSimilarity;
  final double? padScore;
  final int latencyMs;
}

/// Serializes [rows] to an RFC 4180 CSV string with the header
///
///   at_utc,outcome,user_id,failure_reason,best_similarity,pad_score,latency_ms
///
/// Use this to bridge the on-device `verification_logs` table to an
/// off-device calibration pipeline. PAD_POLICY=shadow deployments are
/// the primary consumer: the field tester taps "Export logs (CSV)" on
/// `/debug/health`, the rows land on the clipboard, they paste into
/// Excel / pandas / R and compute FRR/FAR over a chosen
/// `padSpoofThreshold` sweep.
///
/// Encoding contract:
/// - Header is always emitted, even when [rows] is empty (so the
///   pasted artifact still parses with `pandas.read_csv`).
/// - Line endings are CRLF, per RFC 4180.
/// - `at` is rendered as a UTC ISO 8601 string with the `Z` suffix.
///   Drift returns rows in the device's local time even though we
///   persist UTC; the `.toUtc()` normalises that for export.
/// - Null fields render as the empty string. `pandas.read_csv` parses
///   that as `NaN` by default, which is what the calibration code
///   wants.
/// - Fields containing `,`, `"`, `\r`, or `\n` are double-quoted, with
///   any internal `"` doubled per RFC 4180. The fields that are
///   numeric or enum-like (outcome, scores, latency) won't trigger
///   the quoting path in practice — it's there for `failure_reason`
///   and `user_id`, which are free-form strings.
String verificationLogsToCsv(Iterable<VerificationLogCsvRow> rows) {
  const String eol = '\r\n';
  final buffer = StringBuffer()
    ..write('at_utc,outcome,user_id,failure_reason,'
        'best_similarity,pad_score,latency_ms')
    ..write(eol);
  for (final r in rows) {
    buffer
      ..write(r.at.toUtc().toIso8601String())
      ..write(',')
      ..write(_csvField(r.outcome))
      ..write(',')
      ..write(_csvField(r.userId))
      ..write(',')
      ..write(_csvField(r.failureReason))
      ..write(',')
      ..write(_csvNumber(r.bestSimilarity))
      ..write(',')
      ..write(_csvNumber(r.padScore))
      ..write(',')
      ..write(r.latencyMs)
      ..write(eol);
  }
  return buffer.toString();
}

/// RFC 4180 field escaping. Null becomes empty. Plain ASCII without
/// special characters passes through. Anything with a comma, quote,
/// CR, or LF gets wrapped in double quotes with internal `"` doubled.
String _csvField(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final needsQuote = raw.contains(',') ||
      raw.contains('"') ||
      raw.contains('\r') ||
      raw.contains('\n');
  if (!needsQuote) return raw;
  final escaped = raw.replaceAll('"', '""');
  return '"$escaped"';
}

/// Numeric fields don't need quoting — render directly via
/// [num.toString] which gives stable, lossless output for doubles
/// (no fixed-precision rounding that would corrupt threshold tuning).
String _csvNumber(double? value) => value == null ? '' : value.toString();
