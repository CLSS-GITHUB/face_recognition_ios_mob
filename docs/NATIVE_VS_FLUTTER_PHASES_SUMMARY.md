# Native-vs-Flutter Phases A/B/C/D — Close-Out Summary

**Date:** 2026-05-13
**Status:** All four phases closed.
**Parent doc:** [`NATIVE_VS_FLUTTER_ANALYSIS.md`](NATIVE_VS_FLUTTER_ANALYSIS.md)

---

## One-paragraph version

The analysis report compared this Flutter project to a third-party
Android reference (KrishnaZyala/FaceRecognition) and proposed four
phases of work. Phase A shipped the perf polish; Phase B shipped
the active anti-spoof additions and the procurement infrastructure
for a passive PAD classifier; Phase C bounded the audit-log table
and explicitly deferred the FFI matcher; Phase D was re-framed
when it became clear the native project is not first-party. The
verify pipeline now runs with five stacked anti-spoof gates,
delegate-cached TFLite inference, accurate-mode ML Kit on the
enrolment path, splash-overlapped prewarm, and bounded
`verification_logs`. The two open follow-ups (ship a real PAD
checkpoint; calibrate threshold against ≥ 2 weeks of field data)
cannot be executed from this repo alone.

---

## Per-phase outcome

### Phase A — Performance polish

**Commit:** `098c04a` "Phase A: NNAPI tier, delegate cache,
accurate enrol, splash prewarm"

| Item | Status | Notes |
|---|---|---|
| A1 — pin camera resolution | Already in place | `providers.dart:385` uses `ResolutionPreset.medium`. Report claim was incorrect. |
| A2 — NNAPI delegate | Shipped | New `_tryNnApi` sibling to `_tryDelegate` in `embedding_isolate.dart`. Validation gate (CPU golden, cosine ≥ 0.999) identical to GPU/XNNPACK. Position: GPU → NNAPI → XNNPACK → CPU. |
| A3 — delegate cache | Shipped | New `lib/core/storage/delegate_cache.dart` persists the winning tier per `Platform.operatingSystemVersion` + `modelVersion`. TTL 7d. Host hint passed to isolate via `spawn(preferredDelegate: …)` skips earlier-tier trials. Decorated labels pruned to simple form before write. |
| A4 — accurate ML Kit for enrolment | Shipped | New autoDispose `enrollmentFaceDetectionServiceProvider`. Enrolment uses accurate mode; verify keeps fast mode. |
| A5 — splash prewarm | Shipped | `FaceDetectionService.prewarm()` fires in `SplashScreen.initState` postFrame alongside the log purge, overlapping the security + permission gate awaits. |

**Validation:** flutter analyze clean; flutter test 249/249 pass.

### Phase B — Anti-spoof hardening

**Commit:** `f94723a` "Phase B: Gabor texture gate (B3) + PAD
procurement and calibration prep (B1)"

| Item | Status | Notes |
|---|---|---|
| B1 — PAD checkpoint procurement | Staged | Runbook at [`verification/pad_checkpoint_procurement.md`](verification/pad_checkpoint_procurement.md). Calibration helper at `lib/core/diagnostics/pad_calibration.dart`. `PadIsolate` scaffold (existing) loads any matching checkpoint via `--dart-define=PAD_ENABLED=true`. **Remaining work:** drop the real `.tflite` file into `assets/models/pad.tflite` and pin its SHA-256. |
| B2 — shadow → enforce flip | Planned | Documented in runbook §6. Cannot be executed without field calibration data. The `PadPolicy.shadow` mode already exists and logs scores to `verification_logs.pad_score`. |
| B3 — Gabor texture gate | Shipped | New `lib/services/gabor_texture_detector.dart`. Pure Dart, sub-millisecond. `(max - min) / (max + min)` anisotropy on four directional-energy channels. Threshold 0.55. Wired into verify controller at both speculation and live-match positions, same enforcement as `ScreenReflectionDetector`. |

**Validation:** flutter analyze clean; flutter test 279/279 pass (+30 from Phase A baseline: +9 Gabor, +21 PAD calibration).

### Phase C — Storage & scale

**Commit:** `187549d` "Phase C: count-bounded verification_logs
purge (C2) + C1 design note"

| Item | Status | Notes |
|---|---|---|
| C1 — FFI matcher | Deferred (documented) | Design note at [`verification/c1_ffi_matcher_design_note.md`](verification/c1_ffi_matcher_design_note.md). Trigger: > 5000 templates per device OR `match.cosine` p99 > 50 ms. Current pure-Dart Float32x4 matcher: 2-4 ms at 1000 templates, ~10-20 ms at 5000. Deferral is explicit, not accidental — re-opening before the trigger fires is speculative scope. |
| C2 — count-bounded log purge | Shipped | `FaceThresholds.verificationLogMaxRows = 10000`. New `purgeBeyondCount(int)` on the domain port + DAO + impl. `verificationLogPurgeProvider` runs both age + count passes with independent error isolation. |
| C3 — template versioning + 180-day recapture | Already complete | Verified in tree: `templateMaxAgeDays = 180`, `User.isStaleAsOf`, `UserRepositoryImpl.activeFlatTemplates` filters stale users, `EnrollUser` refreshes `lastEnrolledAt`, Re-enroll UI banner + CTA already ship behind passing widget tests. |

**Validation:** flutter analyze clean; flutter test 288/288 pass (+9 from Phase B baseline: C2 DAO + provider tests).

### Phase D — Native-side parity (re-framed)

**Commit:** this commit. Documentation only.

The original "deprecate the native Android project" recommendation
assumed first-party ownership. Inspection of the native project's
git remote (`KrishnaZyala/FaceRecognition.git`) and README
(authored by KrishnaZyala) showed it is third-party reference code.
A separate first-party Android project exists at
`D:\Development Projecrts\FaceVerfication` (production-ready per
its own documentation) but was not analysed in this iteration.

Phase D outputs:

| Item | Status | Notes |
|---|---|---|
| D1 — Re-frame analysis report | Shipped | Header note + revised §9 + updated §11 roadmap. |
| D2 — Refresh Flutter README | Shipped | Out-of-date "Phase 1 complete" claim removed; current state, build flags, project layout, and project-relationship clarification added. |
| D3 — This close-out doc | Shipped | The file you're reading. |

**Explicitly NOT done in Phase D:**

- Modifications to `KrishnaZyala/FaceRecognition` (different
  owner; cannot be touched from this account).
- Re-analysis against `FaceVerfication` (out of scope; would
  need a separate session).
- Parity-up implementation on any Android project.

---

## What's still open after Phase D

These cannot be closed from inside this repo alone — they require
either external assets or field-deployment time.

| Open item | Blocker | Where to act |
|---|---|---|
| Bundle Silent-Face MiniFASNet PAD checkpoint | Procurement: download, license capture, PyTorch→TFLite conversion, hash pin | Runbook [`verification/pad_checkpoint_procurement.md`](verification/pad_checkpoint_procurement.md) |
| Calibrate `padSpoofThreshold` | ≥ 2 weeks of shadow-mode field data | Deploy with `--dart-define=PAD_ENABLED=true --dart-define=PAD_POLICY=shadow`, then run `PadCalibration.sweepThresholds` on the CSV export |
| Flip `PadPolicy.enforce` | Calibration result above | One `--dart-define` change in the release build |
| Optional: re-analyse against `FaceVerfication` | Decision: is it worth a production-vs-production comparison? | New analysis session |

---

## Test inventory

| Phase | Tests added | Cumulative pass count |
|---|---|---|
| Pre-Phase A baseline | — | 249 |
| Phase A | 0 (no regressions; existing 249 still pass) | 249 |
| Phase B | +9 Gabor, +21 PAD calibration | 279 |
| Phase C | +5 DAO purgeBeyondCount, +4 provider sum/isolation | 288 |
| Phase D | 0 (documentation only) | 288 |

---

## Files added across all phases

```
docs/
├── NATIVE_VS_FLUTTER_ANALYSIS.md                 (Phase A)
├── NATIVE_VS_FLUTTER_PHASES_SUMMARY.md           (Phase D, this file)
└── verification/
    ├── pad_checkpoint_procurement.md             (Phase B)
    └── c1_ffi_matcher_design_note.md             (Phase C)

lib/
├── core/
│   ├── diagnostics/pad_calibration.dart          (Phase B)
│   └── storage/delegate_cache.dart               (Phase A)
└── services/gabor_texture_detector.dart          (Phase B)

test/
├── unit/
│   ├── core/diagnostics/pad_calibration_test.dart  (Phase B)
│   └── services/gabor_texture_detector_test.dart   (Phase B)
```

Plus modifications to: `lib/core/constants/thresholds.dart`,
`lib/core/di/providers.dart`,
`lib/core/isolates/embedding_isolate.dart`,
`lib/data/database/daos/verification_log_dao.dart`,
`lib/features/face_verification/data/repositories/verification_log_repository_impl.dart`,
`lib/features/face_verification/domain/repositories/verification_log_repository.dart`,
`lib/features/face_verification/presentation/controllers/enrollment_controller.dart`,
`lib/features/face_verification/presentation/controllers/verification_controller.dart`,
`lib/features/face_verification/presentation/screens/splash_screen.dart`,
plus three updated test files.
