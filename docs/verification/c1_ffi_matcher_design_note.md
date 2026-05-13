# C1 — FFI Matcher Design Note (Deferred)

**Status:** Deferred. Documented for future implementation.
**Trigger:** Single device with > 5000 enrolled templates.
**Effort:** ~3-5 engineer-days when triggered.
**Cross-refs:**
- `lib/services/face_matching_service.dart` — current pure-Dart implementation
- `docs/NATIVE_VS_FLUTTER_ANALYSIS.md` §9 Phase C
- `docs/migration/09_performance.md`

---

## Why this is deferred

The current `FaceMatchingService` uses `Float32x4` SIMD over
L2-normalised 192-D vectors in pure Dart. Measured cost:

| Templates | Pure-Dart SIMD |
|---|---|
| 10 | < 0.1 ms |
| 100 | 0.5-1 ms |
| 1000 | 2-4 ms |
| 5000 | 10-20 ms |

A verify attempt budgets ~150 ms for the embedding extract; match
cost up to a few ms is irrelevant. FFI's dispatch overhead is
~1-3 µs per call but it introduces a native-build dependency on
both Android and iOS, a fallback path when the native library
fails to load, and a deployment surface that doesn't exist today.

**There is no observed deployment in the 5000+ templates regime.**
The recommended-against-now scoping is documented here so a future
engineer doesn't waste two days re-deriving "yes we considered FFI
and chose against it."

---

## When this stops being deferred

Trigger the implementation when **either** of these is true on the
deployment:

1. **Hard signal:** a single device's `users` table has >5000 active
   (non-stale) rows. Surface via `/debug/health` (already shows
   `usersActiveBank` count) — operators on heavy-multi-tenant
   deployments (factories, schools, large secure facilities) hit
   this first.
2. **Soft signal:** `LatencyTracker` shows `match.cosine` events
   exceeding the budget — say > 50 ms p99 over a one-week window.
   The pure-Dart matcher will degrade gracefully under unexpected
   pressure (background isolate contention, low-end CPU); if it's
   genuinely > 50 ms the FFI cost is justified.

Don't trigger on hypothetical concerns. The matcher is not the
bottleneck — `_warmTemplates` (AES-GCM decryption) is the next
thing to look at if a Manage Users sheet feels slow.

---

## Design sketch when triggered

### Native side

A single `extern "C"` function, identical signature on Android
and iOS:

```c
// pad_match.c (or face_match.c — name TBD)
// Returns the index of the template with the highest cosine
// similarity against `probe`. Both vectors are L2-normalised on
// the Dart side, so the body reduces to a dot product. Writes the
// winning cosine into `*out_score`.
int32_t face_match_best(
    const float* probe,        // 192 floats
    const float* templates,    // count × 192 floats, row-major
    int32_t count,
    int32_t dim,               // always 192 for the v1 model
    float* out_score
);
```

Implementation: a simple SIMD loop using NEON intrinsics on ARM
(both Android arm64-v8a and iOS arm64) plus a scalar fallback for
x86_64 simulators. ~50 LOC.

### Build wiring

- Android: `android/app/CMakeLists.txt` + a small `face_match/` source
  tree. The `tflite_flutter` plugin already pulls native builds; we
  follow its CMake conventions.
- iOS: `ios/Runner/face_match/face_match.c` + an entry in
  `Runner.xcodeproj`. Linked statically.
- Symbol exposure: `extern "C"` so `dart:ffi` can `lookup` it by
  literal name across both platforms.

### Dart binding

Replace the body of `FaceMatchingService.findBestUser` with an FFI
call gated by:

```dart
final _lib = (() {
  try {
    return ffi.DynamicLibrary.open(
      Platform.isAndroid ? 'libface_match.so' : '<process>',
    );
  } catch (_) {
    return null;  // fall back to pure Dart
  }
})();
```

The pure-Dart implementation stays in tree as the fallback for:
- iOS simulator builds (x86_64; the native lib may not link)
- Test runs (`Platform.isAndroid` lookups fail in `flutter test`)
- Devices where the native lookup throws for any reason

This means the FFI path is strictly additive — no regression risk.

### Validation

Same contract as the embedding isolate's CPU-golden delegate
validation: at first invocation, run the FFI matcher and the
pure-Dart matcher on the same probe against the same flat bank,
compare the returned indices and within-ulps cosines. Persist
"FFI matcher validated" in `flutter_secure_storage` so subsequent
cold starts skip the double-run.

---

## What this note explicitly does **not** authorise

- Speculative native code. The native source files do not exist in
  the tree today and should not be added until the trigger above
  fires.
- New deployment targets (Linux, macOS, Windows desktop). Those
  builds use the pure-Dart matcher exclusively until someone proves
  it's slow there.
- A "let's prepare the FFI bindings now and turn them on later"
  half-measure. The bindings cost is not the work; the native build
  config + cross-platform validation is. Doing it now means
  carrying the maintenance surface for code that runs zero verify
  attempts.

The right move when the trigger fires is one focused 3-5 day
push that lands the whole thing — not a slow accretion of dead
scaffolding.
