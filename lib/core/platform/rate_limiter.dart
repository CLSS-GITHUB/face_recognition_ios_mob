import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

import '../constants/thresholds.dart';

/// Thin abstraction over `flutter_secure_storage` so the rate limiter can be
/// unit-tested without the platform channel. Production injects
/// [FlutterSecureStorageAdapter]; tests inject [InMemorySecureStorage].
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStorageAdapter implements SecureKeyValueStore {
  FlutterSecureStorageAdapter([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Test-friendly in-memory store. Not thread-safe; tests are single-isolate.
class InMemorySecureStorage implements SecureKeyValueStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

/// Outcome of [RateLimiter.check].
sealed class RateLimitDecision {
  const RateLimitDecision();
}

/// Attempt is allowed.
class RateLimitAllowed extends RateLimitDecision {
  const RateLimitAllowed({required this.remaining});

  /// Number of attempts left in the current window before cooldown engages.
  final int remaining;
}

/// Attempt is blocked. The caller should display a "try again in N s" copy
/// and not run the verification pipeline.
class RateLimitCoolingDown extends RateLimitDecision {
  const RateLimitCoolingDown({required this.retryAfter});

  /// How long until the next attempt is allowed.
  final Duration retryAfter;
}

/// Sliding-window rate limiter for verification attempts.
///
/// State is persisted in a [SecureKeyValueStore] so a tampering adversary
/// cannot reset the counter by clearing the application documents
/// directory; see architecture_recommendations.md §7.4 / §K SEC-011.
///
/// Window length, max failures, and cooldown come from
/// [FaceThresholds.rateLimitWindowMs] / `rateLimitMaxFailures` /
/// `rateLimitCooldownMs`.
class RateLimiter {
  RateLimiter({
    required SecureKeyValueStore storage,
    String key = _defaultKey,
    DateTime Function()? clock,
  })  : _storage = storage,
        _key = key,
        _clock = clock ?? DateTime.now;

  static const String _defaultKey = 'rl:verify';
  static final Logger _log = Logger('RateLimiter');

  final SecureKeyValueStore _storage;
  final String _key;
  final DateTime Function() _clock;

  Future<RateLimitDecision> check() async {
    final now = _clock();
    final state = await _readState();
    if (state.cooldownUntil != null && now.isBefore(state.cooldownUntil!)) {
      return RateLimitCoolingDown(retryAfter: state.cooldownUntil!.difference(now));
    }
    final pruned = _prune(state.failures, now);
    final remaining = FaceThresholds.rateLimitMaxFailures - pruned.length;
    if (remaining <= 0) {
      // Saturation: should have been caught by recordFailure, but guard in
      // case state was edited externally.
      final cooldownUntil =
          now.add(const Duration(milliseconds: FaceThresholds.rateLimitCooldownMs));
      await _writeState(_State(failures: pruned, cooldownUntil: cooldownUntil));
      return RateLimitCoolingDown(
        retryAfter: cooldownUntil.difference(now),
      );
    }
    // Persist any pruning we just did so subsequent reads are cheap.
    if (pruned.length != state.failures.length || state.cooldownUntil != null) {
      await _writeState(_State(failures: pruned, cooldownUntil: null));
    }
    return RateLimitAllowed(remaining: remaining);
  }

  Future<void> recordFailure() async {
    final now = _clock();
    final state = await _readState();
    final pruned = _prune(state.failures, now)..add(now);
    if (pruned.length >= FaceThresholds.rateLimitMaxFailures) {
      final cooldownUntil =
          now.add(const Duration(milliseconds: FaceThresholds.rateLimitCooldownMs));
      _log.info('Rate limit saturated: ${pruned.length} failures; '
          'cooldown until $cooldownUntil');
      await _writeState(_State(failures: pruned, cooldownUntil: cooldownUntil));
      return;
    }
    await _writeState(_State(failures: pruned, cooldownUntil: null));
  }

  /// Clear the counter on a successful verification (architecture §7.4).
  Future<void> reset() => _storage.delete(_key);

  // --- internal -------------------------------------------------------

  List<DateTime> _prune(List<DateTime> failures, DateTime now) {
    final cutoff = now.subtract(
      const Duration(milliseconds: FaceThresholds.rateLimitWindowMs),
    );
    return failures.where((t) => t.isAfter(cutoff)).toList();
  }

  Future<_State> _readState() async {
    final raw = await _storage.read(_key);
    if (raw == null || raw.isEmpty) return const _State.empty();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final failuresMs = (json['failures'] as List<dynamic>? ?? const <dynamic>[])
          .cast<int>()
          .map<DateTime>(DateTime.fromMillisecondsSinceEpoch)
          .toList();
      final cooldownMs = json['cooldownUntil'] as int?;
      return _State(
        failures: failuresMs,
        cooldownUntil: cooldownMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(cooldownMs),
      );
    } catch (e, st) {
      _log.warning('Corrupt rate-limit state — resetting', e, st);
      await _storage.delete(_key);
      return const _State.empty();
    }
  }

  Future<void> _writeState(_State state) async {
    final json = <String, dynamic>{
      'failures': state.failures
          .map((t) => t.millisecondsSinceEpoch)
          .toList(),
      'cooldownUntil': state.cooldownUntil?.millisecondsSinceEpoch,
    };
    await _storage.write(_key, jsonEncode(json));
  }
}

class _State {
  const _State({required this.failures, required this.cooldownUntil});
  const _State.empty()
      : failures = const <DateTime>[],
        cooldownUntil = null;

  final List<DateTime> failures;
  final DateTime? cooldownUntil;
}
