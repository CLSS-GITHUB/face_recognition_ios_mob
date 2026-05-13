import 'dart:convert';
import 'dart:io' show Platform;

import 'package:logging/logging.dart';

import '../platform/rate_limiter.dart' show SecureKeyValueStore;

/// A3: per-device TFLite delegate choice cache.
///
/// `EmbeddingIsolate._selectInterpreter` runs a CPU-golden validation
/// pass against every accelerator tier (GPU → NNAPI → XNNPACK → CPU) at
/// spawn time. Each trial is one full interpreter construction plus one
/// forward pass — ~50-130 ms apiece on a Pixel 6, so the full chain
/// costs ~100-260 ms before the isolate is ready to serve its first
/// extract. On a single device this never changes outcome across cold
/// starts: GPU either works on this device or it doesn't, NNAPI either
/// agrees with the CPU golden or it doesn't.
///
/// This cache records the simple winning label (`gpu`, `nnapi`,
/// `xnnpack`, `cpu`) keyed by [_storageKey], scoped by the bundled
/// model's [FaceThresholds.modelVersion] and the device's
/// [Platform.operatingSystemVersion], with a 7-day TTL. On the next
/// cold start the host hands the cached label to the isolate as a
/// "start the chain here" hint; the isolate skips earlier tiers and
/// pays only the cost of validating the cached choice.
///
/// Falling back is safe by design — if the cached delegate now fails
/// validation (driver update broke FP fusion, etc.), the isolate falls
/// through to the remaining tiers exactly as it would on a cold cache,
/// and the host overwrites the cache with whatever ultimately won.
///
/// Threading: read/write happen on the host (main) isolate before/after
/// `EmbeddingIsolate.spawn`. The cache value itself is passed across as
/// a plain string in the spawn config.
class DelegateCache {
  DelegateCache({
    required SecureKeyValueStore storage,
    Duration ttl = const Duration(days: 7),
    String? osVersionOverride,
  })  : _storage = storage,
        _ttl = ttl,
        _osVersion = osVersionOverride ?? Platform.operatingSystemVersion;

  static const String _storageKey = 'emb_delegate_v1';

  /// Accepted simple labels. Any value the isolate returns that isn't
  /// in this set is treated as "no clean cache" — protects against the
  /// `"cpu(gpu-validation-fail:...|...)"` decorated labels accidentally
  /// being written back as a "preferred" hint and confusing the isolate.
  static const Set<String> validLabels = <String>{
    'gpu',
    'nnapi',
    'xnnpack',
    'cpu',
  };

  static final Logger _log = Logger('DelegateCache');

  final SecureKeyValueStore _storage;
  final Duration _ttl;
  final String _osVersion;

  /// Returns the cached simple delegate label for this device, or null
  /// when the cache is missing, stale, scoped to a different OS
  /// version, or scoped to a different model version. Failure modes
  /// (corrupt JSON, unparseable timestamp) are swallowed and treated
  /// as "no cache" — the isolate falls back to the full validation
  /// chain, which is exactly what we want.
  Future<String?> read({required int modelVersion}) async {
    try {
      final raw = await _storage.read(_storageKey);
      if (raw == null) return null;
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final cachedModelVersion = decoded['modelVersion'];
      if (cachedModelVersion is! int || cachedModelVersion != modelVersion) {
        return null;
      }
      final cachedOsVersion = decoded['osVersion'];
      if (cachedOsVersion is! String || cachedOsVersion != _osVersion) {
        return null;
      }
      final savedAtStr = decoded['savedAt'];
      if (savedAtStr is! String) return null;
      final savedAt = DateTime.tryParse(savedAtStr);
      if (savedAt == null) return null;
      if (DateTime.now().toUtc().difference(savedAt.toUtc()) > _ttl) {
        return null;
      }
      final label = decoded['label'];
      if (label is! String || !validLabels.contains(label)) return null;
      return label;
    } catch (e, st) {
      _log.warning('DelegateCache.read failed; falling back to no cache.', e, st);
      return null;
    }
  }

  /// Persists [label] as the validated choice for this device. Only
  /// accepts simple labels from [validLabels]; decorated labels
  /// (`"cpu(gpu-validation-fail:…|nnapi-validation-fail:…)"`) are
  /// reduced to their leading simple form by the caller before
  /// writing.
  Future<void> write({
    required String label,
    required int modelVersion,
  }) async {
    if (!validLabels.contains(label)) {
      _log.warning('DelegateCache.write rejected non-simple label "$label".');
      return;
    }
    try {
      final payload = json.encode(<String, dynamic>{
        'label': label,
        'modelVersion': modelVersion,
        'osVersion': _osVersion,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _storage.write(_storageKey, payload);
    } catch (e, st) {
      _log.warning('DelegateCache.write failed; ignoring.', e, st);
    }
  }

  /// Removes the cached entry. Used by tests; also a safe escape hatch
  /// when a field operator needs to force a full re-validation
  /// without waiting for the TTL.
  Future<void> clear() async {
    try {
      await _storage.delete(_storageKey);
    } catch (e, st) {
      _log.warning('DelegateCache.clear failed; ignoring.', e, st);
    }
  }

  /// Strips the `(after:…)` decoration the isolate appends when a
  /// downstream tier wins after upstream tiers failed. Returns null
  /// if the leading token isn't in [validLabels] — protects against
  /// `"cpu(xnnpack-validation-fail:…|gpu-construct-fail:…)"` getting
  /// written as a "preferred" hint that the isolate would then try
  /// to honour (it would just skip everything and fall to cpu, which
  /// is fine, but caching the *failures* serves no purpose).
  static String? simpleLabelOrNull(String fullLabel) {
    final paren = fullLabel.indexOf('(');
    final head = paren < 0 ? fullLabel : fullLabel.substring(0, paren);
    return validLabels.contains(head) ? head : null;
  }
}
