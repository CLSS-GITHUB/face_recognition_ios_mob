# Production-vs-Production Analysis: FaceVerfication (Native Android) vs face_ios_android (Flutter)

**Author:** Senior Android + Flutter Performance Engineering Review
**Date:** 2026-05-13
**Status:** Analysis report — re-run against first-party Android baseline
**Scope:** Architecture, performance, security, parity gaps, recommendations
**Projects analysed:**
- Native Android: `D:\Development Projecrts\FaceVerfication`
  (first-party, production-ready per its own docs as of 2026-04-30)
- Flutter: `D:\Development Projecrts\face_ios_android`
  ([github.com/CLSS-GITHUB/face_recognition_ios_mob](https://github.com/CLSS-GITHUB/face_recognition_ios_mob)),
  post-Phase-A/B/C/D

> 📎 **Companion to** `NATIVE_VS_FLUTTER_ANALYSIS.md` (which compared
> against the third-party KrishnaZyala/FaceRecognition reference).
> This second analysis runs against `FaceVerfication`, the
> first-party production Android project, so the deltas are smaller
> but more meaningful — both projects are production-grade.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [FaceVerfication — Architecture Findings](#2-faceverfication--architecture-findings)
3. [Flutter — Architecture (post-Phase-C state)](#3-flutter--architecture-post-phase-c-state)
4. [Side-by-side Comparison Matrix](#4-side-by-side-comparison-matrix)
5. [Where Each Project Wins](#5-where-each-project-wins)
6. [Performance Bottleneck Cross-Reference](#6-performance-bottleneck-cross-reference)
7. [Anti-Spoof Gate Inventory](#7-anti-spoof-gate-inventory)
8. [Security Posture](#8-security-posture)
9. [What This Analysis Changes vs the Original Report](#9-what-this-analysis-changes-vs-the-original-report)
10. [Recommendations](#10-recommendations)
11. [Appendix A — FaceVerfication File Inventory](#appendix-a--faceverfication-file-inventory)
12. [Appendix B — Key Numeric Constants (Both Projects)](#appendix-b--key-numeric-constants-both-projects)

---

## 1. Executive Summary

| | FaceVerfication (Native Android) | face_ios_android (Flutter) |
|---|---|---|
| Status | Production-ready (2026-04-30 per project docs) | Phases A/B/C shipped (commits `4a6770c`…`0690a5d`) |
| Primary stack | Kotlin 2.2.10 + C++ NEON SIMD + Jetpack Compose 2024.09 + CameraX 1.5.0 | Dart + Flutter + Riverpod 2 + GoRouter + Drift 2.20 |
| LOC | ~5,407 Kotlin + 170 C++ | ~9,000+ Dart |
| Detection | ML Kit `face-detection:16.1.7` (fast mode) + MediaPipe Tasks Vision 0.10.14 (optional 468-point) | ML Kit via `google_mlkit_face_detection ^0.13.0` (fast for verify, accurate for enrol per Phase A4) |
| Embedding model | **MobileFaceNet** (5.2 MB, 112×112 → 192-D, L2-normalised) | **MobileFaceNet** (same family, 112×112 → 192-D, L2-normalised) |
| Match threshold | cosine ≥ 0.75 (single-check) | cosine ≥ 0.75 **AND** margin (best−runner-up) ≥ 0.04 (open-set) |
| Matching impl | C++ NEON via JNI (`face_matcher.cpp`, 170 LOC) | Pure Dart `Float32x4` SIMD (`face_matching_service.dart`) |
| Inference acceleration | XNNPack + 4 threads (CPU only; GPU delegate present but **not configured** per F-07) | GPU → NNAPI → XNNPACK → CPU with CPU-golden validation + per-device cache (Phase A2/A3) |
| Threading | Coroutines + single-thread camera executor; **embedding extraction on Main thread** (F-01: 80-220 ms freeze) | Dedicated `EmbeddingIsolate` (long-lived, single-flight, pre-allocated buffers) |
| Liveness | Active 5-step: BLINK → TURN_LEFT → TURN_RIGHT → MOUTH_OPEN → STILL | Active 5-step: same names, randomised challenge per attempt with `Random.secure` |
| Passive anti-spoof | **None** | Motion variance + device accelerometer + screen reflection + Laplacian blur + **Gabor texture (Phase B3)**; PAD scaffold (B1 pending checkpoint) |
| Storage | Room SQLite, binary-BLOB templates, **unencrypted** | Drift SQLite v5, AES-GCM-encrypted templates with key in OS secure storage |
| Audit log | None | `verification_logs` table with per-attempt outcome + similarity + padScore + latencyMs; CSV export from `/debug/health`; bounded by min(age=30d, count=10k) per Phase C2 |
| Rate limiting | None | 5 fails / 60 s → 30 s cooldown, secure-storage-backed |
| Multi-template per user | Yes (`List<FloatArray>`) | Yes (`User.templates[]`) |
| Voting / multi-frame | 5 frames / 800 ms / early-exit ≥ 0.90 | Speculative extract (O-5) + warm template cache (F-4) |
| Pre-warm | Pre-warm templates on screen entry (OPT-09) | Pre-warm camera + isolate + ML Kit blob + templates from `verifyPrewarmProvider`; ML Kit prewarm runs from splash (Phase A5) |
| Tests | 1 example JUnit test; manual testing matrix (18+ scenarios documented) | 288 automated tests (unit + widget + DAO + isolate) |
| GPU acceleration | Available, not enabled | GPU delegate active with golden validation |
| Native code | C++ NEON SIMD batch matcher (~8-10× over pure Kotlin) | None (pure Dart SIMD via `Float32x4`) |
| Open-set safety | Best-match only | Best + runner-up margin gate |
| Min SDK | 24 (Android 7) | 21 (Android 5) typical Flutter floor |

**Headline finding:** Both projects implement the same recognition
recipe (MobileFaceNet 192-D, L2-normalised, cosine ≥ 0.75) on the
same model family. The differences are around the recognition: the
Flutter project has measurably stronger anti-spoof depth, encrypted
template storage, an audit log, rate limiting, off-main-thread
inference, GPU acceleration, and an automated test suite.
FaceVerfication has a native-C++ NEON matcher that the Flutter
project does not need at current template counts — the report's
Phase C1 "deferred FFI matcher" entry maps exactly to what
FaceVerfication already does, but the Flutter pure-Dart SIMD
matcher is fast enough that the FFI win is < 1 ms at typical
deployment scale.

The original report's headline ("Flutter app exceeds native on the
dimensions that matter") **holds against this baseline too**, but
the deltas are tighter — and FaceVerfication has one concrete
implementation choice (native NEON matching) that the Flutter
project explicitly defers as out-of-budget speculative scope.

---

## 2. FaceVerfication — Architecture Findings

### 2.1 Project structure

Single Gradle module (`:app`) containing logical SDK packages:

| Package | LOC | Purpose |
|---|---|---|
| `sdk/data/` | ~100 | Room DB, entities, DAOs |
| `sdk/detection/` | 228 | ML Kit + MediaPipe wrappers |
| `sdk/liveness/` | 406 | Active 5-step state machine |
| `sdk/processor/` | 23 | FaceData normalisation |
| `sdk/quality/` | 634 | Quality assessment + image enhancement |
| `sdk/recognition/` | 575 | TFLite embedder + JNI matcher |
| `sdk/utils/` | ~500 | Bitmap, security, image loading |
| `camera/` | 108 | CameraX integration |
| `ui/screens/` | 1,222 | Jetpack Compose UI |
| `cpp/` | 170 (C++) | NEON-SIMD batch matcher |

**Total:** ~5,407 Kotlin + 170 C++.

### 2.2 ML stack

- **ML Kit Face Detection 16.1.7**: 133 landmarks + Euler angles +
  classifications, fast mode by default, accurate mode for enrolment.
- **MediaPipe Tasks Vision 0.10.14**: 468-point landmark detection
  available as an alternative (`MediaPipeDetector.kt`, 228 LOC).
- **TensorFlow Lite 2.17.0**: MobileFaceNet (FP32, 5.2 MB, 192-D
  output) loaded with `setUseXNNPACK(true)` + `setNumThreads(4)`.
- **TFLite GPU Delegate 2.17.0**: declared but **not configured**
  (F-07 in the project's own performance review).

### 2.3 Recognition pipeline

```
Camera (CameraX, YUV_420_888, STRATEGY_KEEP_ONLY_LATEST)
   │
   ├─► FaceAnalyzer.analyze(imageProxy)        (custom executor)
   │
   ├─► ML Kit detect → Face + landmarks + Euler angles
   │
   ├─► YUV→ARGB Bitmap.toBitmap()              (8-25 ms, F-04 churn)
   │
   ├─► calculateFaceBrightness(bitmap, bbox)   (sampling-based)
   │
   ├─► rotateBitmap(rotated)                   (Matrix postRotate)
   │
   ├─► QualityAssessor.assess(faceData, …)     (5-20 ms)
   │      └── brightness ∈ [45,245], face 4-70% frame, centering,
   │          yaw/pitch < 25°, eye-open > 0.3, required landmarks
   │
   ├─► LivenessDetector.process(…)             (enrolment only,
   │      5-step state machine)
   │
   ├─► BitmapUtils.cropFace(bitmap, bbox)      (25% padding)
   │
   ├─► qualityEngine.alignFace + enhance       (enrolment only;
   │      verification uses fast path)
   │
   ├─► TFLite Interpreter.run(112×112 → 192-D) (80-150 ms;
   │      ⚠ Main thread — F-01)
   │
   ├─► L2 normalise (manual sqrt + div)
   │
   └─► NativeFaceMatcher.findBestMatchAndScore(probe, flat, count)
          └── JNI → face_matcher.cpp:dot_product_neon(...)
          └── O(N×192) batch; ~8-10× Kotlin baseline
          └── Returns (bestIndex, bestScore)
```

### 2.4 Matching internals (C++ NEON)

`app/src/main/cpp/face_matcher.cpp` (170 LOC):

| Function | Purpose |
|---|---|
| `dot_product_neon` | 4-wide `vmlaq_f32` FMA loop with scalar tail; aarch64 + armeabi-v7a |
| `cosineSimilarityNative` | Single-pair cosine over L2-normalised vectors |
| `findBestMatchNative` | Batch best-index scan |
| `getBestSimilarityNative` | Score for the best match (originally a second scan — F-08) |
| `findBestMatchAndScoreNative` | Single-pass index + score; uses `GetPrimitiveArrayCritical` for zero-copy access |

Performance: ~0.01 ms per 192-D comparison on modern ARM. ~100 ms
total for 10k templates.

### 2.5 Liveness — 5-step active

`LivenessDetector.kt` (122 LOC):

| Step | Signal | Trigger | Release |
|---|---|---|---|
| BLINK | leftEye/rightEye open probability | both < 0.25 | both > 0.6 |
| TURN_LEFT | headEulerY | > 15° | — |
| TURN_RIGHT | headEulerY | < −15° | — |
| MOUTH_OPEN | nose-to-mouth / inter-eye ratio | > 0.85 then < 0.75 | (temporal opening + closing) |
| STILL | yaw + pitch | both < ±5° | — |

Same step list and thresholds as the Flutter `LivenessStateMachine`.

### 2.6 Storage

- `UserEntity(userId PK, name, faceTemplates: List<FloatArray>, isActive, imagePath)` in Room.
- Templates serialised as binary `ByteBuffer` (LE) via `Converters.kt`.
- **No encryption.** `fallbackToDestructiveMigration()` on schema change.
- `face_auth_database` lives unencrypted under app-private dir.

### 2.7 Anti-spoof inventory

| Gate | Source | Type |
|---|---|---|
| BLINK | LivenessDetector | Active |
| TURN_LEFT/RIGHT | LivenessDetector | Active |
| MOUTH_OPEN | LivenessDetector | Active |
| STILL | LivenessDetector | Active |
| Brightness | QualityAssessor | Passive (lighting check, not real spoof) |
| Face size | QualityAssessor | Passive (positioning) |
| Centering | QualityAssessor | Passive (positioning) |
| Pose | QualityAssessor | Passive (yaw/pitch limits) |
| Landmark visibility | StaticImageValidator | Passive (occlusion proxy) |

**No** texture analysis, depth estimation, screen-moiré / replay
detection, motion variance, accelerometer signal, or PAD model.
The project's own `FRAUD_PREVENTION.md` explicitly lists these as
gaps.

### 2.8 Documented performance issues (project's own review)

From `verify_identity_performance_review/02_PERFORMANCE_ANALYSIS.md`:

| ID | Issue | Impact | Status |
|---|---|---|---|
| F-01 | Embedding + match on Main thread | 80-220 ms UI freeze | Open |
| F-02 | ML Kit callback on Main | 8-25 ms per-frame jank | Open |
| F-03 | `Bitmap.getPixel` in hot loop | 5-10× slower than `getPixels` | Open |
| F-04 | Bitmap allocation churn | 6-14 MB GC | Partially mitigated |
| F-05 | ML Kit contour mode overhead | 2× detection latency | Conditional (enrol only) |
| F-06 | TFLite cold init per screen | 80-250 ms | Fixed (singleton) |
| F-07 | GPU delegate not enabled | 2-4× speedup unused | Open |
| F-08 | Batch match double-scan | 2× JNI overhead | Fixed (single-pass) |

### 2.9 Testing

- **1 example JUnit unit test** (`ExampleUnitTest.kt`).
- Manual testing matrix in `MANUAL_TESTING_GUIDE.md` (18 scenarios,
  E1-E5 / V1-V3 / Q1-Q5 / S1-S5). All documented as passing.
- No instrumented Espresso tests beyond default scaffolding.

---

## 3. Flutter — Architecture (post-Phase-C state)

(Summarised; the full breakdown is in
[`NATIVE_VS_FLUTTER_ANALYSIS.md`](NATIVE_VS_FLUTTER_ANALYSIS.md) §3
plus the close-out at [`NATIVE_VS_FLUTTER_PHASES_SUMMARY.md`](NATIVE_VS_FLUTTER_PHASES_SUMMARY.md).)

### 3.1 Stack

`google_mlkit_face_detection ^0.13.0` (fast mode for verify,
accurate for enrol per A4), `tflite_flutter ^0.11.0` via FFI,
`camera ^0.11.0+2` (NV21 on Android, BGRA8888 on iOS), Drift 2.20
+ AES-GCM template encryption via `cryptography ^2.7.0`,
`flutter_secure_storage ^9.2.2` for wrapper keys + delegate cache,
`sensors_plus ^6.0.0` for accelerometer anti-spoof.

### 3.2 Recognition pipeline

```
camera stream (NV21 / BGRA8888)
   │
   ├─► UI isolate: ML Kit detect (MethodChannel, 30-55 ms)
   │
   ├─► QualityAssessor / OcclusionDetector / BlurMetric gates
   │
   ├─► [O-5 speculative] EmbeddingIsolate.prepare + extract
   │      (TransferableTypedData; cached ≤500 ms)
   │
   ├─► LivenessStateMachine: 5 steps, randomised challenge
   │
   ├─► FaceMatchingService.findBestUser  (Float32x4 SIMD, <1 ms / 100 templates)
   │
   ├─► Open-set margin check: best ≥ 0.75 AND (best − runner-up) ≥ 0.04
   │
   └─► verification_logs row (outcome + similarity + padScore + latencyMs)
```

### 3.3 Anti-spoof depth

| Gate | Source | Type |
|---|---|---|
| 5-step active liveness | `LivenessStateMachine` | Active (same as FaceVerfication) |
| Motion variance | `MotionVarianceDetector` | Passive (bbox std-dev ≥ 0.8 px over 30 frames) |
| Device motion | `DeviceMotionDetector` | Passive (accel std-dev ≥ 0.05 m/s² over 1 s) |
| Screen reflection | `ScreenReflectionDetector` | Passive (saturation + luma) |
| Laplacian blur | `BlurMetric` | Passive (variance ≥ 60) |
| Gabor texture (Phase B3) | `GaborTextureDetector` | Passive (directional energy anisotropy ≥ 0.55) |
| Quality / occlusion | `QualityAssessor`, `OcclusionDetector` | Passive |
| PAD model | `PadIsolate` scaffold | Passive (scaffold; checkpoint pending B1) |

### 3.4 Other production features Flutter has and FaceVerfication doesn't

- AES-GCM template encryption (`TemplateCrypto` + secure-storage wrapper key)
- Audit log (`verification_logs` table) bounded by min(30d, 10k rows) per Phase C2
- Rate limiting (5/60 s → 30 s cooldown) secure-storage-backed
- Open-set margin gate (defeats identity confusion at multi-user enrollment)
- Per-device delegate cache (skips re-validation on cold start, Phase A3)
- Latency instrumentation (`LatencyTracker`, `/debug/health` dashboard)
- Active 288-test suite (DAO, isolate, services, controllers, screens, widgets)

---

## 4. Side-by-side Comparison Matrix

| Dimension | FaceVerfication | face_ios_android | Winner |
|---|---|---|---|
| Embedding model | MobileFaceNet 192-D L2-norm | MobileFaceNet 192-D L2-norm | Tie |
| Model size | 5.2 MB | ~150 KB (bundled) | (architectural difference, not capability) |
| Detection | ML Kit fast (verify) / contour (enrol) | ML Kit fast (verify) / accurate (enrol) | Tie |
| Embedding inference | TFLite XNNPack + 4 threads (CPU) | TFLite GPU → NNAPI → XNNPACK → CPU with golden validation | **Flutter** (GPU delegate active) |
| Inference threading | **Main thread** (F-01) | Dedicated isolate (single-flight, pre-allocated buffers) | **Flutter** (no UI freeze) |
| Cold-start TFLite | 80-250 ms (F-06, fixed via singleton) | ~80 ms isolate spawn + delegate validation; cached per-device (Phase A3) | Flutter slightly ahead post-A3 |
| Matching algorithm | C++ NEON SIMD via JNI | Pure-Dart `Float32x4` SIMD | Different paths, both effective |
| Matching at 1k templates | ~10-20 ms | 2-4 ms | **Flutter** (less work due to SIMD over normalised vectors) |
| Matching at 10k templates | ~100 ms | ~30 ms est. (linear extrapolation) | Flutter (theoretical) |
| Match threshold | cosine ≥ 0.75 | cosine ≥ 0.75 **and** margin ≥ 0.04 | **Flutter** (open-set safe) |
| Active liveness | 5-step (BLINK / TURN_L / TURN_R / MOUTH / STILL) | 5-step (same names; `Random.secure` per attempt) | Flutter slightly ahead (randomisation defeats pre-recorded clips) |
| Passive anti-spoof gates | 0 | 4 (+ PAD scaffold) | **Flutter** |
| Template storage | Plain SQLite BLOB | AES-GCM encrypted BLOB | **Flutter** |
| Wrapper key | n/a | OS-backed secure storage (Keystore / Keychain) | **Flutter** |
| Audit log | None | `verification_logs` with retention + count caps | **Flutter** |
| Rate limit / lockout | None | 5/60 s → 30 s | **Flutter** |
| Multi-template per user | Yes | Yes | Tie |
| Voting / robustness | 5 frames / 800 ms / early-exit ≥ 0.90 | Speculative extract + template warm cache | Different approaches |
| GPU acceleration | Available, not enabled (F-07) | GPU delegate enabled with CPU-golden validation | **Flutter** |
| NNAPI | Not used | Active in delegate chain (Phase A2) | **Flutter** |
| Per-device delegate cache | n/a | Persisted in secure storage, TTL 7 d (Phase A3) | **Flutter** |
| Per-attempt latency telemetry | Logs only | `LatencyTracker` 128-event ring buffer + `/debug/health` | **Flutter** |
| Tests | 1 unit test + 18-scenario manual matrix | 288 automated tests | **Flutter** |
| Performance review docs | 8-doc `verify_identity_performance_review/` package | `NATIVE_VS_FLUTTER_ANALYSIS.md` + phase summary | Tie |
| Production deployment status | "Production-ready 2026-04-30" per project docs | Phases A/B/C shipped; PAD checkpoint pending | (Both production-track) |

---

## 5. Where Each Project Wins

### 5.1 FaceVerfication wins on

1. **Native NEON SIMD matching.** A 170-LOC C++ library with
   single-pass `findBestMatchAndScoreNative` + zero-copy
   `GetPrimitiveArrayCritical` access. Flutter's pure-Dart
   `Float32x4` SIMD is fast enough at current scale, but the
   native matcher genuinely outperforms at 10k+ templates per
   device. The Flutter Phase C1 design note (`c1_ffi_matcher_design_note.md`)
   maps almost exactly to what FaceVerfication has already shipped.
2. **Documentation breadth.** 12+ top-level markdown docs plus an
   8-doc `verify_identity_performance_review/` package, including
   a detailed performance-issue inventory (F-01…F-08+). The Flutter
   project's docs are also substantial but less inward-looking.
3. **MediaPipe 468-point landmark option.** Available as a parallel
   detection path; the Flutter project uses only ML Kit's 133-point
   set.
4. **Single-process simplicity.** No isolate / FFI bridges, no
   secure-storage indirection — easier to reason about for a
   first-time reader.

### 5.2 Flutter wins on

1. **Off-main-thread inference.** The Flutter isolate completely
   sidesteps FaceVerfication's open F-01 issue (80-220 ms UI freeze
   during embedding extraction). The camera preview stays smooth
   even during a verify.
2. **GPU + NNAPI delegate chain with validation.** FaceVerfication's
   F-07 (GPU delegate available, not enabled) is exactly the
   problem the Flutter project's Phase A solved with the
   `_tryDelegate` + `_tryNnApi` + CPU-golden ≥ 0.999 cosine gate
   architecture. The per-device cache (Phase A3) means cold starts
   skip re-validation entirely.
3. **Encrypted template storage.** AES-GCM with the wrapper key in
   OS-backed secure storage. FaceVerfication's `FRAUD_PREVENTION.md`
   lists this as a known gap.
4. **Anti-spoof depth.** 4 passive gates (motion variance, device
   accelerometer, screen reflection, Gabor texture) + Laplacian blur
   on top of the same 5-step active liveness. FaceVerfication has
   only the active 5-step.
5. **Open-set safety.** The best-vs-runner-up margin gate
   (≥ 0.04) prevents identity confusion at ≥ 3 enrolled users — a
   real risk FaceVerfication's single-threshold check doesn't
   address.
6. **Audit log.** `verification_logs` records outcome + similarity
   + padScore + latencyMs per attempt, bounded by min(age=30 d,
   count=10 k) (Phase C2). FaceVerfication has only logcat.
7. **Rate limiting.** 5 failures / 60 s → 30 s cooldown, persisted
   in secure storage so an adversary can't reset by clearing app
   data. FaceVerfication doesn't rate-limit.
8. **Automated test suite.** 288 tests covering DAOs, isolate,
   services, controllers, screens, widgets. FaceVerfication has 1
   example JUnit test + a 18-scenario manual matrix.
9. **Randomised liveness challenge.** Each verify attempt picks one
   of 4 challenges uniformly from `Random.secure` — defeats
   pre-recorded clips. FaceVerfication runs the same fixed 5-step
   sequence every time during enrolment and a single blink check
   during verify.
10. **Cross-platform.** iOS support is built in via the same
    codebase; FaceVerfication is Android-only.

---

## 6. Performance Bottleneck Cross-Reference

| Issue | FaceVerfication | Flutter equivalent |
|---|---|---|
| F-01: embedding on Main thread | Open (80-220 ms freeze) | **N/A** — `EmbeddingIsolate` handles this off the UI isolate |
| F-02: ML Kit callback on Main | Open (8-25 ms jank) | MethodChannel reply on platform thread; widget rebuilds coalesced per-frame (Flutter F-6) |
| F-03: `Bitmap.getPixel` in loop | Open (5-10× slow) | **N/A** — frame prepare uses `Nv21Decoder` with 2-pixel unroll on flat byte arrays |
| F-04: bitmap allocation churn | Partially mitigated | Pre-allocated isolate I/O buffers; `TransferableTypedData` zero-copy |
| F-05: ML Kit contour mode | Conditional (enrol only) | Contours disabled everywhere; 4-landmark occlusion check uses position presence |
| F-06: TFLite cold init per screen | Fixed (singleton) | Isolate is `keepAlive` for app lifetime |
| F-07: GPU delegate not enabled | Open (2-4× speedup unused) | **Fixed** by Phase A2 (GPU + NNAPI + XNNPACK chain with CPU-golden validation) |
| F-08: batch match double-scan | Fixed (single-pass) | Flutter matcher is naturally single-pass |
| **New: per-attempt latency visibility** | logcat only | `LatencyTracker` ring buffer + `/debug/health` panel + CSV export |
| **New: verify cold start** | Pre-warm templates only | Pre-warm camera + isolate + ML Kit blob + templates (Phase A5: ML Kit prewarm in splash overlaps gate awaits) |

Translating: every open issue in FaceVerfication's own performance
review has either been pre-empted by the Flutter architecture or
explicitly fixed in Phase A.

---

## 7. Anti-Spoof Gate Inventory

| Gate | FaceVerfication | Flutter | Notes |
|---|---|---|---|
| Active blink challenge | ✓ | ✓ | Same thresholds (close 0.25 / open 0.60) |
| Active head turn L/R | ✓ | ✓ | Same yaw ≥ 15°, return < 5° |
| Active mouth open | ✓ | ✓ | Same ratio thresholds (0.85 / 0.75) |
| Active still | ✓ | ✓ | Same pose stability ≤ 5° |
| Bbox motion variance (replay/print) | — | ✓ | 30-frame buffer, std-dev floor 0.8 px (hyst 0.6) |
| Device accelerometer | — | ✓ | 50 Hz, 1 s buffer, std-dev floor 0.05 m/s² |
| Screen reflection saturation/luma | — | ✓ | `ScreenReflectionDetector`, ~256 sampled pixels |
| Gabor directional texture | — | ✓ | Phase B3, `(max-min)/(max+min)` over 4 channels, threshold 0.55 |
| Laplacian blur | quality only | ✓ as gate | variance < 60 → reject |
| Quality gates (brightness, size, centering, pose, landmarks) | ✓ | ✓ | Comparable thresholds |
| Static-image validator | ✓ | ✓ | Both require 4 key landmarks present |
| PAD model (TFLite) | — | scaffold | Flutter has `PadIsolate` ready; checkpoint pending B1 |
| Randomised challenge per attempt | — | ✓ | `Random.secure` picks 1-of-4 each attempt |
| Open-set margin gate | — | ✓ | best − runner-up ≥ 0.04 |
| Rate limiting | — | ✓ | 5/60 s → 30 s |
| **Total active gates** | 5 | 5 (same) | |
| **Total passive gates** | 0 hard / 5 quality | 6 hard + quality | **Flutter +6 passive** |

---

## 8. Security Posture

| Concern | FaceVerfication | Flutter | Risk delta |
|---|---|---|---|
| Template encryption at rest | None | AES-GCM | Flutter materially safer |
| Wrapper key storage | n/a | OS-backed secure storage | Flutter has key-management story |
| Root / emulator gate | `SecurityUtils.isRooted` + `isEmulator` (custom heuristics) | `SecurityCheck` + redirect to `/security` | Comparable |
| Play Integrity / DeviceCheck | Neither | Neither | Tie (both gaps) |
| Audit trail | Logcat only | `verification_logs` table | Flutter |
| Rate limiting | None | 5/60 s → 30 s, persisted | Flutter |
| Replay attack defence (static photo) | Active blink + landmark presence | Active blink + motion variance + screen reflection + blur + Gabor | Flutter materially stronger |
| Replay attack defence (video replay) | Active 5-step | All of the above + accelerometer std-dev (catches phone-on-tripod) | Flutter materially stronger |
| Replay attack defence (deepfake video) | None specific | None specific (PAD model would help here) | Both gaps |
| Identity confusion at scale | Best-match cosine only | best + runner-up margin gate | Flutter |
| Secure communication | n/a (on-device) | n/a (on-device) | Tie |
| Logging hygiene (PII) | Logcat may include sensitive | `verification_logs.userId` is FK only, never the name | Flutter |

---

## 9. What This Analysis Changes vs the Original Report

The original `NATIVE_VS_FLUTTER_ANALYSIS.md` compared against the
KrishnaZyala/FaceRecognition third-party reference. Re-running
against the first-party `FaceVerfication` project changes specific
findings while leaving the high-level conclusions intact:

| Original claim | Updated against FaceVerfication | Verdict |
|---|---|---|
| "Native uses 512-D FaceNet, Flutter uses 192-D MobileFaceNet" | Both use 192-D MobileFaceNet | **Updated.** No model gap. |
| "Native recomputes embeddings on every match (O(n × 200 ms))" | FaceVerfication caches templates in flat array; NEON batch match in ~10-20 ms per 1k | **Wrong against this baseline.** FaceVerfication has the right design. |
| "Native uses no GPU delegate" | FaceVerfication has TFLite GPU dependency declared but not configured (F-07) | **Holds** (same gap, documented in their own review). |
| "Native runs the match loop on a synchronized lock" | FaceVerfication does the embedding on Main thread (F-01) — different issue, similar UX impact | **Updated.** Different cause, same UX consequence. |
| "Native has only passive MobileNet liveness, not enforced" | FaceVerfication has full active 5-step liveness (not passive, but active is in fact strong) | **Wrong against this baseline.** FaceVerfication's active liveness is well-engineered. |
| "Native has no encryption" | Still true — FaceVerfication stores templates unencrypted | **Holds.** |
| "Native has no rate limiting / audit log" | Still true — FaceVerfication has neither | **Holds.** |
| "Native has no isolate / off-main-thread inference" | FaceVerfication runs embedding on Main thread (F-01 open) | **Holds.** |
| Native has 2,330 LOC; Flutter has 9,000+ LOC | FaceVerfication has 5,400+ Kotlin + 170 C++; Flutter has 9,000+ Dart | **Updated.** FaceVerfication is mid-sized, not tiny. |
| "Flutter exceeds native on every dimension that matters" | Still mostly true; FaceVerfication wins on native-NEON matching specifically | **Mostly holds.** |

**Net effect on the report's recommendations:**

- Phase A items (GPU/NNAPI delegate chain, per-device cache) are
  still valid additions — FaceVerfication's F-07 confirms the gap.
- Phase B items (Gabor texture, PAD scaffold) are still net-additive
  vs FaceVerfication's anti-spoof depth.
- Phase C2 (count-bounded log purge) is still net-additive —
  FaceVerfication has no audit log at all.
- **Phase C1 (FFI matcher) is the one item this re-analysis changes
  meaningfully**: FaceVerfication has shipped this already and uses
  it routinely. The Flutter deferral remains correct (trigger is
  > 5000 templates per device; the design note explicitly says
  "don't speculatively scaffold"), but the existence proof in
  FaceVerfication is useful when the trigger fires.

---

## 10. Recommendations

### 10.1 No code changes recommended at this time

The Flutter project's Phase A/B/C work has already closed every
meaningful gap that this re-analysis surfaces, with one explicit
deferral (C1 FFI matcher) that the Flutter project has documented
and decided against until trigger conditions are met.

### 10.2 Useful follow-ups when scope or scale changes

| Trigger | Action |
|---|---|
| Deployment crosses ~5000 templates per device, **or** `LatencyTracker` shows `match.cosine` p99 > 50 ms | Implement C1 FFI matcher per [`verification/c1_ffi_matcher_design_note.md`](verification/c1_ffi_matcher_design_note.md). FaceVerfication's `face_matcher.cpp` (170 LOC) is a credible reference implementation. |
| Phase B PAD checkpoint procurement completes | Calibrate against shadow-mode field data using `PadCalibration` helper; flip `PadPolicy.enforce` |
| Native-Android deployment considered alongside Flutter | Decide single-platform (Flutter, recommended) vs dual-maintain (FaceVerfication for Android, Flutter for iOS). The Flutter project already supports both platforms, so the dual-maintain path costs more without obvious benefit. |
| Stakeholder wants 468-point landmarks | Wire MediaPipe Tasks Vision into a Flutter platform channel (FaceVerfication's `MediaPipeDetector.kt` shows the integration). Not currently needed — the 133-point set drives all gates fine. |

### 10.3 Things FaceVerfication should consider porting from Flutter (if first-party maintenance continues)

This list is documentation-only — this account cannot land changes
on the `FaceVerfication` project from here, but it's worth
recording for the team that maintains it:

1. AES-GCM template encryption (closes the `FRAUD_PREVENTION.md`
   gap they've already self-identified).
2. Audit log with retention (`verification_logs`-equivalent table).
3. Rate limiting (5/60 s → 30 s cooldown).
4. Off-Main-thread embedding extraction (fixes F-01 directly —
   the biggest open performance issue).
5. GPU delegate with CPU-golden validation (fixes F-07).
6. Open-set margin gate (best − runner-up ≥ 0.04 with ≥ 2 active
   users).
7. Passive anti-spoof gates: motion variance + accelerometer +
   screen reflection + Gabor texture. None require ML models;
   all of them are < 1 ms per frame on the existing crop.

Each of these is a small focused change in FaceVerfication;
together they would close the production-readiness gap with the
Flutter implementation.

---

## Appendix A — FaceVerfication File Inventory

### Top 15 most important files

| # | File | LOC | Purpose |
|---|---|---|---|
| 1 | `ui/screens/EnrollmentScreen.kt` | 560 | Enrollment flow: liveness, registration |
| 2 | `ui/screens/VerificationScreen.kt` | 366 | Verification flow: detection, matching, result |
| 3 | `MainActivity.kt` | 336 | App entry, navigation, permissions, security |
| 4 | `ui/screens/NewEnrollmentScreen.kt` | 321 | Pre-enrolment validation |
| 5 | `sdk/quality/EnhancedQualityAssessor.kt` | 310 | Brightness, sharpness, occlusion checks |
| 6 | `sdk/liveness/AdvancedLivenessDetector.kt` | 284 | Confidence-scored liveness with EAR/MAR |
| 7 | `ui/screens/UserManagementScreen.kt` | 243 | User list CRUD |
| 8 | `sdk/utils/AdvancedBitmapUtils.kt` | 239 | Crop / align / enhance |
| 9 | `sdk/quality/ImageQualityEngine.kt` | 230 | Histogram equalisation, alignment |
| 10 | `sdk/detection/MediaPipeDetector.kt` | 228 | 468-point alternative detector |
| 11 | `sdk/recognition/AdvancedFaceMatcher.kt` | 207 | Threshold tuning + clustering |
| 12 | `sdk/recognition/FaceEmbedder.kt` | 172 | Multi-template TFLite integration |
| 13 | `ui/screens/LivenessScreen.kt` | 162 | Dedicated liveness UI |
| 14 | `camera/FaceAnalyzer.kt` | 151 | ML Kit pipeline + frame analysis |
| 15 | `sdk/recognition/FaceRecognizer.kt` | 128 | TFLite MobileFaceNet inference |

Plus `app/src/main/cpp/face_matcher.cpp` (170 C++ LOC) — the NEON-SIMD matcher.

### Documentation set

12+ top-level markdown docs (README, PERFORMANCE_ANALYSIS,
application_performance, FRAUD_PREVENTION, NATIVE_MATCHING_EVALUATION,
OPENSOURCE_IMPLEMENTATION_COMPLETE, OPENSOURCE_QUICKSTART,
DELIVERABLES_CHECKLIST, TESTING_COMPLETION_SUMMARY,
TEST_VALIDATION_REPORT, TROUBLESHOOTING_GUIDE, MANUAL_TESTING_GUIDE,
AGENTS, lib, ui_migration_mapping) plus an 8-file
`verify_identity_performance_review/` package. Production-status
sign-off documented to 2026-04-30.

---

## Appendix B — Key Numeric Constants (Both Projects)

### Shared values

| Constant | Value | Both? |
|---|---|---|
| Embedding dimension | 192 | ✓ |
| Model input size | 112 × 112 | ✓ |
| Normalisation | `(p - 127.5) / 127.5` → [-1, 1] | ✓ |
| Match threshold (cosine) | 0.75 | ✓ |
| BLINK closed / open | 0.25 / 0.60 | ✓ |
| TURN yaw trigger | ±15° | ✓ |
| MOUTH ratio enter / exit | 0.85 / 0.75 | ✓ |
| STILL pose limit | ±5° | ✓ |
| Brightness range | 45-245 (FaceVerfication); 45-245 (Flutter) | ✓ |
| Face size range | 4-70% of frame | ✓ |
| Required landmarks | 4 (eyes + nose + mouth) | ✓ |

### Flutter-only

| Constant | Value | Source |
|---|---|---|
| Open-set margin | 0.04 | `FaceThresholds.verifyUserMargin` |
| Duplicate face threshold (enrol) | 0.85 | `FaceThresholds.duplicateFaceThreshold` |
| Motion bbox std-dev floor | 0.8 px (hyst 0.6) | `MotionVarianceDetector` |
| Accelerometer std-dev floor | 0.05 m/s² | `DeviceMotionDetector` |
| Gabor anisotropy threshold | 0.55 | `GaborTextureDetector` |
| Blur Laplacian floor | 60 | `BlurMetric` |
| PAD spoof threshold (placeholder) | 0.5 | `FaceThresholds.padSpoofThreshold` |
| Speculation cache TTL | 500 ms | `VerificationController` |
| Rate limit | 5 / 60 s → 30 s | `RateLimiter` |
| `verification_logs` retention | 30 days **and** 10 k rows | Phase C2 |
| Template max age | 180 days | `FaceThresholds.templateMaxAgeDays` |
| Delegate cache TTL | 7 days | `DelegateCache` |
| Latency ring buffer | 128 events | `LatencyTracker` |

### FaceVerfication-only

| Constant | Value | Source |
|---|---|---|
| TFLite threads | 4 | `FaceRecognizer.kt:31` |
| Voting max frames | 5 | `VerificationScreen.kt:51-90` |
| Voting max time | 800 ms | `VerificationScreen.kt:51-90` |
| Voting early-exit similarity | 0.90 | `VerificationScreen.kt:51-90` |
| Eye-distance minimum (mouth-open guard) | 20 px | `LivenessDetector.kt:67` |
| Mouth ratio valid range | [0.3, 1.5] | `LivenessDetector.kt:65` |

---

*Re-analysis complete. The Flutter project requires no
code changes off the back of this finding — Phases A/B/C have
already closed every meaningful gap surfaced here, and the one
genuine differentiator (FaceVerfication's native NEON matcher)
is correctly deferred behind the Phase C1 trigger condition.*
