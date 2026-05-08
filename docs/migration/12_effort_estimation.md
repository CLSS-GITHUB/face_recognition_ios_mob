# 12 — Migration Effort Estimation

## 12.1 Methodology

Estimates are in **engineer-days for one full-time mid-senior Flutter engineer** with prior camera + on-device ML experience. Multiply by 1.4× for a junior, 0.8× for a senior with TFLite background. Estimates exclude design/QA cycles unless noted.

Each row contains:
- **Effort** (days)
- **Confidence** (H/M/L) — H means we've done it on a comparable project; L means there's a known risk (see `11_risks.md`).
- **Dependencies** — what must land first.

## 12.2 Module-by-module estimate

| # | Module / deliverable | Effort | Conf. | Dependencies |
|---|---|---|---|---|
| 1 | Project bootstrap: pubspec, lints, theme, folder structure, app routing skeleton | 0.5 d | H | — |
| 2 | Riverpod scaffold + Drift database with empty `Users` table | 1.0 d | H | 1 |
| 3 | `core/utils/byte_layout.dart` + `FaceTemplatesConverter` + parity unit tests against Android byte buffer | 0.5 d | H | 2 |
| 4 | Encrypted template wrapper (`flutter_secure_storage` + `package:cryptography` AES-GCM) | 0.5 d | M | 3 |
| 5 | `SecurityCheck` (`safe_device` + custom heuristics) + `PermissionScreen` + `SecurityWarningScreen` + router gates | 0.5 d | H | 1 |
| 6 | `HomeScreen` + `ActionCard` widget + golden test | 0.25 d | H | 1 |
| 7 | `EnrollFormScreen` (form fields, navigation to live enrollment) | 0.25 d | H | 1 |
| 8 | `CameraPreviewWidget` wrapping `camera` plugin with frame stream + back-pressure | 1.0 d | M | — |
| 9 | `cameraImageToInputImage` helper for ML Kit, golden-tested | 0.5 d | M | 8 |
| 10 | `FaceDetectionService` (ML Kit wrapper + `FaceProcessor` mapping) | 0.5 d | H | 9 |
| 11 | `QualityAssessor` (pure Dart) + parity unit tests against Android values | 0.75 d | H | 10 |
| 12 | `LivenessStateMachine` (5-step) + parity unit tests | 1.0 d | H | 11 |
| 13 | `FaceRecognitionService` (TFLite, MobileFaceNet) + isolate runner | 1.5 d | M | 1, R-01 |
| 14 | `FaceMatchingService` (pure Dart cosine + best-match) + benchmarks | 0.5 d | H | 13 |
| 15 | `BitmapUtils` (crop + save JPEG) + `image_processing` (alignment, histogram EQ) | 1.0 d | M | 13, R-07 |
| 16 | `FaceOverlay` widget (mirror for front camera, landmark dots) | 0.5 d | H | 10 |
| 17 | `CircularProgressSegments` widget + golden test | 0.25 d | H | 1 |
| 18 | `InstructionCard` widget | 0.25 d | H | 1 |
| 19 | `EnrollmentController` (3-stage state machine, full porting) | 2.0 d | M | 11–17 |
| 20 | `LiveEnrollmentScreen` UI + dialogs + retry logic | 1.0 d | H | 19 |
| 21 | `VerificationController` (pre-warm flatten templates, blink, match) | 1.5 d | M | 14, 15 |
| 22 | `VerificationScreen` UI + result dialog | 0.5 d | H | 21 |
| 23 | `UserRepository` + Drift DAO + `UserManagementController` | 0.75 d | H | 2 |
| 24 | `UserManagementScreen` + `UserCard` + delete dialog (incl. file deletion) | 0.5 d | H | 23 |
| 25 | iOS Info.plist + signing + first iOS build verification | 1.0 d | M | 8, 13, R-11 |
| 26 | Threshold parity test pinning every constant from `01_project_analysis.md §1.9` | 0.25 d | H | 11–14 |
| 27 | Unit-test suite for services (services + converter + state machine) | 1.5 d | H | 11–14 |
| 28 | Widget-test suite (golden tests for key screens & cards) | 1.0 d | H | 6, 17–18, 20, 22, 24 |
| 29 | Integration-test scenarios covering enroll → verify happy path | 1.0 d | M | 19–24 |
| 30 | Performance profiling pass (DevTools timeline, memory) + tuning | 1.0 d | M | 19–24 |
| 31 | Threshold re-tuning after iOS testing (R-02) | 1.0 d | L | 25, 30 |
| 32 | CI: GitHub Actions matrix (analyze + test + build APK + build IPA) | 0.5 d | H | — |
| 33 | Play Store + App Store metadata, privacy disclosures, screenshots | 0.5 d | M | 30 |

**Subtotal: 24.0 engineer-days.**
**Risk buffer (+15 %, per `11_risks.md`): +3.6 days.**
**Suggested allocation: 28 days = ~5.5 calendar weeks for one engineer.**

Two engineers in parallel can compress to ~3.5 weeks if work is split along these seams:
- Engineer A: 1, 2, 3, 4, 5, 6, 7, 23, 24, 27 (data + utility + management)
- Engineer B: 8, 9, 10, 11, 12, 13, 14, 15, 16, 19, 20, 21, 22 (camera + ML + screens)
- Either: 25–33 (cross-cutting)

## 12.3 Phase plan

### Phase 0 — Alignment (0.25 d, before coding)

- Review and approve this documentation set.
- Confirm encryption approach (per `10_security.md` §10.3).
- Confirm threshold values vs. Android baseline (any platform-specific deltas?).
- Confirm Riverpod over Bloc (or pivot).
- Confirm iOS support is in scope for v1.

### Phase 1 — Foundation (3 days)

Items 1, 2, 3, 4, 5, 6, 7. Output: app launches, routes between empty screens, security gate works, DB scaffolded with encrypted converter.

### Phase 2 — Camera + ML pipeline (5 days)

Items 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18. Output: a debug screen shows live camera + bounding boxes + quality + liveness step state, and we can extract one embedding into a `Float32List`.

### Phase 3 — Feature screens (5 days)

Items 19, 20, 21, 22, 23, 24. Output: the three live screens — Enroll, Verify, Manage — work end-to-end on Android against the local DB.

### Phase 4 — iOS bring-up (1.5 days)

Item 25. Output: signed iOS build runs on a real iPhone, camera + ML + TFLite all functional.

### Phase 5 — Quality bar (4 days)

Items 26, 27, 28, 29, 30, 31. Output: parity-pinning tests, unit + widget + integration coverage, perf budget met on both platforms.

### Phase 6 — Release prep (1 day)

Items 32, 33. Output: green CI, signed builds for both stores, store metadata authored.

## 12.4 Module weightings (relative cost)

| Module | % of total |
|---|---|
| ML / TFLite / matching pipeline | ~20 % |
| Live enrollment screen + controller | ~15 % |
| Camera plumbing | ~10 % |
| Database + encryption | ~10 % |
| Verification screen + controller | ~10 % |
| User management + repository | ~5 % |
| Tests | ~15 % |
| iOS bring-up + cross-platform polish | ~10 % |
| Bootstrapping + utility widgets | ~5 % |

Two-thirds of the work is the **frame loop and the screens that consume it**. Plan accordingly.

## 12.5 What is explicitly out of scope for v1

- Reintroducing gallery enrollment (`NewEnrollmentScreen` keeps the live-camera-only path).
- MediaPipe face landmarker and the dead `Advanced*` Kotlin classes.
- Native FFI cosine matcher (Phase 2 if profiling demands it).
- Anti-spoofing beyond active liveness.
- Backend / network features (Retrofit's spiritual replacement).
- Multi-language localization (defer until product team supplies copy).
- Tablet / landscape layouts (the Android app is portrait-only).
- A `pub.dev`-published reusable face-verification package.

## 12.6 Implementation milestones (suggested commit cadence)

1. **`feat: scaffold Flutter app, Riverpod, Drift, theme, router`** — Phase 1 done.
2. **`feat: implement security & permission gates`** — gates working.
3. **`feat: integrate camera plugin + ML Kit + face overlay`** — debug screen shows boxes.
4. **`feat: port quality assessor and liveness state machine`** — 5-step state visible on screen.
5. **`feat: integrate TFLite MobileFaceNet, Float32List embeddings`** — first embedding produced.
6. **`feat: pure-Dart cosine matcher + flat-template precompute`** — verify-flow runs.
7. **`feat: enrollment screen with 3-stage flow + dialogs`** — first user enrolls.
8. **`feat: verification screen + access granted/denied dialog`** — first verify.
9. **`feat: user management screen with toggle + delete`** — admin path complete.
10. **`feat: encrypted template storage`** — security release blocker resolved.
11. **`test: pin thresholds and add unit/widget/integration suites`** — quality bar.
12. **`build: iOS signing, Info.plist, first device run`** — iOS bring-up.
13. **`perf: profile and tune frame pipeline`** — perf budgets met.
14. **`chore: CI matrix + store metadata`** — release-ready.

## 12.7 Confirmation gate

Per the source prompt's instruction: **No Flutter implementation code has been written.** Awaiting your explicit go-ahead to begin Phase 1.

If approved, the next message will create:

1. The base `pubspec.yaml` additions.
2. The folder skeleton listed in `08_folder_structure.md` § 8.1.
3. The `core/constants/thresholds.dart` parity file.
4. The router + gates.
5. An empty Drift database with the encrypted converter.

…in that order, with checkpoints for review. Reply with the items in `12.3 Phase 0` either confirmed or amended, and we proceed.
