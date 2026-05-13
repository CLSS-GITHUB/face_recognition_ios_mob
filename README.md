# face_ios_android

On-device face verification for Flutter — Android + iOS. Active
5-step liveness, AES-GCM template encryption, isolate-based
TFLite inference with a GPU/NNAPI/XNNPACK delegate chain, stacked
passive anti-spoof gates, rate limiting, and per-attempt audit
logging.

## Status

All planned phases shipped. See
[`docs/NATIVE_VS_FLUTTER_PHASES_SUMMARY.md`](docs/NATIVE_VS_FLUTTER_PHASES_SUMMARY.md)
for the close-out summary, or
[`docs/NATIVE_VS_FLUTTER_ANALYSIS.md`](docs/NATIVE_VS_FLUTTER_ANALYSIS.md)
for the full technical analysis.

| Phase | Commit | Scope |
|---|---|---|
| Analysis | `4a6770c` | End-to-end report comparing this project to KrishnaZyala/FaceRecognition |
| A — perf polish | `098c04a` | NNAPI tier, delegate cache, accurate enrolment detect, splash prewarm |
| B — anti-spoof | `f94723a` | Gabor texture gate; PAD procurement runbook + calibration helper |
| C — scale | `187549d` | Count-bounded log purge; FFI matcher design note deferred |
| D — close-out | (this) | Documentation: project relationships, README refresh, summary |

**Open follow-ups** (do not require code changes from this repo):

- Ship a vetted Silent-Face MiniFASNet `pad.tflite` checkpoint —
  runbook at [`docs/verification/pad_checkpoint_procurement.md`](docs/verification/pad_checkpoint_procurement.md).
- Run a ≥ 2-week shadow-mode field deployment to calibrate the
  PAD threshold using the `PadCalibration` helper.

## Project relationships

This Flutter project lives alongside two related Android projects
in the same workspace:

- **`D:\Development Projecrts\FaceRecognition`** — third-party
  reference code by KrishnaZyala (MIT). Used as a baseline for
  the comparative analysis. Demo-grade; ~2,330 LOC. Not
  first-party.
- **`D:\Development Projecrts\FaceVerfication`** — a separate
  first-party Android Face Verification project (production-ready
  per its own docs). Not analysed in this report; surfaced here
  so a future reader knows it exists.

`face_ios_android` (this repo) is the Flutter port + production
rewrite — not a one-to-one mirror of either Android project. See
the analysis report for the full mapping.

## First-time setup

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

The codegen step is required — Drift generates
`app_database.g.dart` from the `@DriftDatabase` and
`@DriftAccessor` annotations. Without it, the app will not
compile.

During active schema work, run a watcher instead:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

## Run

```bash
flutter run                      # debug
flutter run --release            # release
flutter test                     # unit + widget tests (288 currently)
flutter analyze                  # static analysis
```

### Build-time flags

The verify pipeline reads several `--dart-define` flags at build
time. Defaults are fine for development; production deployments
should set them deliberately.

| Flag | Default | Purpose |
|---|---|---|
| `PAD_ENABLED` | `false` | Wire the passive PAD classifier into the verify pipeline. Requires a `pad.tflite` checkpoint in `assets/models/`. |
| `PAD_POLICY` | `enforce` | `enforce` denies on high spoof score; `shadow` logs the score but doesn't short-circuit. Use `shadow` for calibration runs. |
| `PAD_MODEL_KIND` | `silentFaceThree` | Output-tensor reducer for the bundled PAD checkpoint. |
| `PAD_PIXEL_NORM` | `imagenet` | Pixel-normalisation strategy applied before inference. |
| `PER_FRAME_LOG` | `false` | Per-frame trace through `print` for the verify + enrolment controllers. Noisy. |

## Repository layout

```
lib/
├── app/                 MaterialApp + theme + GoRouter
├── core/
│   ├── constants/       FaceThresholds — every tunable
│   ├── di/              Riverpod providers
│   ├── diagnostics/     LatencyTracker, PadCalibration
│   ├── isolates/        EmbeddingIsolate, PadIsolate
│   ├── platform/        Camera perm, root/emulator gate, rate limiter
│   ├── security/        TemplateCrypto (AES-GCM)
│   └── storage/         DelegateCache
├── data/database/       Drift schema, DAOs, repos
├── features/
│   └── face_verification/
│       ├── data/        Repository implementations
│       ├── domain/      Entities, ports, use cases
│       └── presentation/
│           ├── controllers/  Verify + Enroll state
│           └── screens/      Splash, verify, enroll, debug-health
└── services/
    ├── face_detection_service.dart       ML Kit wrapper
    ├── face_matching_service.dart        Float32x4 cosine matcher
    ├── face_recognition_service.dart     Legacy on-thread extractor
    ├── liveness_state_machine.dart       5-step challenge
    ├── motion_variance_detector.dart     Bbox motion anti-spoof
    ├── device_motion_detector.dart       Accelerometer anti-spoof
    ├── screen_reflection_detector.dart   Saturation+luma anti-spoof
    ├── gabor_texture_detector.dart       Directional-energy anti-spoof
    └── quality_assessor.dart             Per-frame gating
```

## Assets

`assets/models/mobile_facenet.tflite` is the bundled face
embedder. The PAD checkpoint slot (`assets/models/pad.tflite`)
is empty by design — see the procurement runbook for what to
drop in.

## Documentation

| File | Purpose |
|---|---|
| `docs/NATIVE_VS_FLUTTER_ANALYSIS.md` | End-to-end technical analysis vs the KrishnaZyala reference project |
| `docs/NATIVE_VS_FLUTTER_PHASES_SUMMARY.md` | Close-out summary of Phases A/B/C/D |
| `docs/verification/architecture_recommendations.md` | Verify-pipeline design |
| `docs/verification/pad_checkpoint_procurement.md` | Runbook for B1: shipping the PAD model |
| `docs/verification/c1_ffi_matcher_design_note.md` | Why FFI matching is deferred |
| `docs/migration/` | Historical Android→Flutter migration plan |

## Tests

```bash
flutter test                                              # all 288 tests
flutter test test/unit                                    # unit tests only
flutter test test/widget                                  # widget tests
flutter test test/unit/services/gabor_texture_detector_test.dart   # one file
```
