import 'dart:math';
import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/services/face_matching_service.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _unit(int dim, int axis) {
  final v = Float32List(dim);
  v[axis] = 1.0;
  return v;
}

Float32List _normalize(List<double> raw) {
  final v = Float32List.fromList(raw);
  var sumSq = 0.0;
  for (var x in v) {
    sumSq += x * x;
  }
  final n = sqrt(sumSq);
  for (var i = 0; i < v.length; i++) {
    v[i] = v[i] / n;
  }
  return v;
}

void main() {
  const matcher = FaceMatchingService();
  const dim = FaceThresholds.embeddingDim;

  test('cosine of identical L2-normalized vectors is ~1', () {
    final v = _unit(dim, 7);
    expect(matcher.cosine(v, v), closeTo(1.0, 1e-6));
  });

  test('cosine of orthogonal unit vectors is ~0', () {
    final a = _unit(dim, 0);
    final b = _unit(dim, 1);
    expect(matcher.cosine(a, b), closeTo(0.0, 1e-6));
  });

  test('cosine throws on mismatched lengths', () {
    expect(() => matcher.cosine(Float32List(192), Float32List(128)),
        throwsArgumentError);
  });

  test('findBestMatch returns the matching template', () {
    final templates = [_unit(dim, 0), _unit(dim, 1), _unit(dim, 2)];
    final flat = Float32List(dim * templates.length);
    for (var i = 0; i < templates.length; i++) {
      flat.setRange(i * dim, (i + 1) * dim, templates[i]);
    }
    final probe = _unit(dim, 1);
    final result = matcher.findBestMatch(probe, flat, templates.length);
    expect(result.index, 1);
    expect(result.similarity, closeTo(1.0, 1e-6));
    expect(result.isMatch, isTrue);
  });

  test('findBestMatch returns none when below threshold', () {
    final templates = [_normalize(List.filled(dim, 0)..[0] = 1)];
    final flat = Float32List(dim)..setRange(0, dim, templates.first);
    // Probe orthogonal to every template — similarity 0.
    final probe = _unit(dim, 5);
    final result = matcher.findBestMatch(probe, flat, 1);
    expect(result.isMatch, isFalse);
    expect(result.index, -1);
  });

  test('findBestMatch returns none for empty bank', () {
    final probe = _unit(dim, 0);
    final result = matcher.findBestMatch(probe, Float32List(0), 0);
    expect(result.isMatch, isFalse);
  });

  test('findBestUser groups by user and reports runner-up', () {
    // alice owns two templates (axis 0 and axis 1); bob owns one
    // template (axis 2). Probe lies along axis 1 — best is alice
    // (cos = 1 via her second template), runner-up is bob (cos = 0).
    final probe = _unit(dim, 1);
    final flat = Float32List(3 * dim)
      ..setRange(0 * dim, 1 * dim, _unit(dim, 0))
      ..setRange(1 * dim, 2 * dim, _unit(dim, 1))
      ..setRange(2 * dim, 3 * dim, _unit(dim, 2));
    final userOf = Int32List.fromList(<int>[0, 0, 1]);

    final result = matcher.findBestUser(
      probe,
      flat,
      userOf,
      3,
      uniqueUserCount: 2,
    );

    expect(result.hasResult, isTrue);
    expect(result.userIndex, 0, reason: 'alice (unique index 0) should win');
    expect(result.bestSimilarity, closeTo(1.0, 1e-6));
    expect(result.runnerUpSimilarity, closeTo(0.0, 1e-6));
    expect(result.margin, closeTo(1.0, 1e-6));
  });

  test('findBestUser single-user → runner-up = -1.0 (closed-set fallback)',
      () {
    final probe = _unit(dim, 0);
    final flat = Float32List(dim)..setRange(0, dim, _unit(dim, 0));
    final userOf = Int32List.fromList(<int>[0]);

    final result = matcher.findBestUser(
      probe,
      flat,
      userOf,
      1,
      uniqueUserCount: 1,
    );

    expect(result.bestSimilarity, closeTo(1.0, 1e-6));
    expect(result.runnerUpSimilarity, -1.0,
        reason: 'Single-user banks must use the closed-set runner-up.');
    expect(result.margin, closeTo(2.0, 1e-6));
  });

  test('findBestUser returns none on empty / malformed bank', () {
    expect(
      matcher
          .findBestUser(_unit(dim, 0), Float32List(0), Int32List(0), 0,
              uniqueUserCount: 0)
          .hasResult,
      isFalse,
    );
    expect(
      matcher
          .findBestUser(_unit(dim, 0), Float32List(dim), Int32List(0), 1,
              uniqueUserCount: 1)
          .hasResult,
      isFalse,
      reason: 'userOf shorter than count → none, no crash',
    );
  });
}
