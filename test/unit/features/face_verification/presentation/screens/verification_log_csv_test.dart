@TestOn('vm')
library;

import 'package:face_ios_android/features/face_verification/presentation/screens/verification_log_csv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('verificationLogsToCsv', () {
    test('empty input emits header-only with CRLF', () {
      // Header must still appear so pandas.read_csv doesn't EOF on the
      // pasted artifact. A trailing CRLF is part of the row terminator
      // contract per RFC 4180.
      final out = verificationLogsToCsv(const <VerificationLogCsvRow>[]);
      expect(
        out,
        'at_utc,outcome,user_id,failure_reason,'
        'best_similarity,pad_score,latency_ms\r\n',
      );
    });

    test('a single granted row renders all columns', () {
      final out = verificationLogsToCsv([
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12, 9, 30, 15),
          outcome: 'granted',
          userId: 'U-abc',
          failureReason: null,
          bestSimilarity: 0.834,
          padScore: 0.07,
          latencyMs: 187,
        ),
      ]);
      final lines = out.split('\r\n');
      // Header + row + trailing empty (because we always end with CRLF).
      expect(lines.length, 3);
      expect(lines[1],
          '2026-05-12T09:30:15.000Z,granted,U-abc,,0.834,0.07,187');
    });

    test('null user / pad / similarity render as empty fields', () {
      // Empty fields parse as NaN under pandas defaults — the
      // calibration code expects that, NOT a synthetic 0. Confirms
      // null-flavour preservation across the wire.
      final out = verificationLogsToCsv([
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12),
          outcome: 'denied',
          userId: null,
          failureReason: 'noMatch',
          bestSimilarity: null,
          padScore: null,
          latencyMs: 42,
        ),
      ]);
      final row = out.split('\r\n')[1];
      expect(row, '2026-05-12T00:00:00.000Z,denied,,noMatch,,,42');
    });

    test('local-zone DateTime is normalised to UTC on export', () {
      // Drift returns rows in the device's local timezone even though
      // production writes go through UTC. The export must reproject
      // back to UTC so the calibration artifact is unambiguous and the
      // ISO-8601 Z suffix matches the contract documented in the
      // serializer.
      final localMidnight = DateTime(2026, 5, 12);
      final out = verificationLogsToCsv([
        VerificationLogCsvRow(
          at: localMidnight,
          outcome: 'granted',
          userId: 'U1',
          failureReason: null,
          bestSimilarity: 0.9,
          padScore: 0.0,
          latencyMs: 100,
        ),
      ]);
      final row = out.split('\r\n')[1];
      // First field should end with Z and equal localMidnight.toUtc().
      final firstField = row.split(',').first;
      expect(firstField.endsWith('Z'), isTrue);
      expect(firstField, localMidnight.toUtc().toIso8601String());
    });

    test('fields with commas / quotes / newlines are RFC 4180 quoted', () {
      // failure_reason and user_id are free-form strings. A future
      // failure-reason wireName containing a comma must not corrupt
      // the column boundary; an embedded quote must be doubled.
      final out = verificationLogsToCsv([
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12),
          outcome: 'error',
          userId: 'user,with,commas',
          failureReason: 'has "quotes" and\nnewline',
          bestSimilarity: null,
          padScore: null,
          latencyMs: 1,
        ),
      ]);
      final row = out.split('\r\n')[1];
      // user_id field becomes "user,with,commas"
      // failure_reason field becomes "has ""quotes"" and<LF>newline"
      // Splitting on naive comma isn't safe; use a structural assertion.
      expect(row.contains('"user,with,commas"'), isTrue);
      expect(row.contains('"has ""quotes"" and\nnewline"'), isTrue);
    });

    test('multiple rows preserve insertion order', () {
      // The exporter relies on the caller's ORDER BY for chronological
      // intent (newest-first today). Internal reordering would silently
      // break that assumption.
      final out = verificationLogsToCsv([
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12, 10),
          outcome: 'granted',
          userId: 'A',
          failureReason: null,
          bestSimilarity: null,
          padScore: null,
          latencyMs: 1,
        ),
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12, 11),
          outcome: 'denied',
          userId: 'B',
          failureReason: null,
          bestSimilarity: null,
          padScore: null,
          latencyMs: 2,
        ),
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12, 12),
          outcome: 'spoof',
          userId: 'C',
          failureReason: null,
          bestSimilarity: null,
          padScore: null,
          latencyMs: 3,
        ),
      ]);
      final lines = out.split('\r\n');
      expect(lines[1].contains(',granted,A,'), isTrue);
      expect(lines[2].contains(',denied,B,'), isTrue);
      expect(lines[3].contains(',spoof,C,'), isTrue);
    });

    test('pad_score round-trips with full precision (no rounding)', () {
      // Threshold calibration sweeps work over the raw double; if the
      // exporter formatted to a fixed number of decimals it would
      // bucket scores and corrupt the FRR/FAR histogram near the
      // operating point.
      final out = verificationLogsToCsv([
        VerificationLogCsvRow(
          at: DateTime.utc(2026, 5, 12),
          outcome: 'granted',
          userId: 'U1',
          failureReason: null,
          bestSimilarity: null,
          padScore: 0.12345678901234,
          latencyMs: 1,
        ),
      ]);
      final row = out.split('\r\n')[1];
      expect(row.contains('0.12345678901234'), isTrue);
    });
  });
}
