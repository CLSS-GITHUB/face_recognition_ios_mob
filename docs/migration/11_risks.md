# 11 — Risks & Dependency Analysis

## 11.1 Risk register

Numbered for traceability in commit messages and PR descriptions. **Severity** combines impact (S = small / M = medium / H = high) and likelihood. Mitigations are concrete actions, not platitudes.

### R-01 — `tflite_flutter` GPU delegate brittleness · severity H

**Why it matters:** TFLite GPU delegate config has changed twice in the plugin's recent history; misconfigured delegates throw at interpreter creation rather than gracefully falling back. A CI build that passes on x86_64 emulators may crash on ARM Android 14.

**Mitigation:**
- Wrap `Interpreter.fromAsset(..., options: ...)` in a try/catch that retries with CPU + XNNPack on failure.
- Pin `tflite_flutter` to a specific patch version; do not auto-bump.
- Add a smoke integration test that runs one inference on a CI device farm (Firebase Test Lab Android matrix + iOS Simulator + a real-device step) before each release.

### R-02 — iOS embedding parity · severity H

**Why it matters:** ML Kit on iOS uses a different underlying detector than on Android. Bounding boxes, landmark coordinates, and Euler angles can shift by a few pixels / degrees. The 0.75 / 0.80 / 0.85 / 0.95 thresholds are tuned against the Android distribution; iOS may need re-tuning.

**Mitigation:**
- Run the same enrollment + verification corpus through both platforms.
- Capture per-device similarity histograms during a 1-week internal beta and verify FAR/FRR fall within ±20 % of the Android baseline.
- Be ready to ship platform-specific threshold offsets via a single `ThresholdProfile.fromPlatform()` factory.

### R-03 — Camera plugin frame format inconsistencies · severity M

**Why it matters:** `camera`'s `startImageStream` emits `CameraImage` with planes in YUV_420 on Android and BGRA8888 on iOS. ML Kit's `InputImage.fromBytes` requires platform-specific plane wiring (rotation, bytes-per-row). Wiring this wrong silently degrades detection accuracy (faces "found" but with off-by-90° rotation).

**Mitigation:**
- Encapsulate conversion in a single `cameraImageToInputImage(CameraImage)` helper, unit-tested with golden fixtures captured from each platform.
- Keep the helper isolated so a `tflite_flutter` or `google_mlkit_face_detection` major bump only changes one file.

### R-04 — Riverpod 2 → 3 churn · severity M

**Why it matters:** Riverpod 3 will be released during the migration window. The `Notifier`/`AsyncNotifier` API stays similar but `legacy provider` syntax is deprecated. A late upgrade can require rewrites across all controllers.

**Mitigation:**
- Use Riverpod 2's modern `Notifier`/`AsyncNotifier` API exclusively (avoid `StateNotifierProvider` / `ChangeNotifierProvider`).
- When Riverpod 3 ships, follow its migration guide in a single dedicated PR.

### R-05 — Drift schema evolution · severity M

**Why it matters:** The Android baseline uses `fallbackToDestructiveMigration` (data loss). Drift defaults to throwing on schema mismatch. If the team forgets to bump `schemaVersion` and write a migration step, the app will crash on first launch after the schema drifts.

**Mitigation:**
- Drift's `drift_dev` ships a `schema-verify` build target; wire it into CI.
- Document the migration policy in `data/database/README.md`: every schema change ⇒ `schemaVersion++` + migration step + a unit test seeded with the previous version.

### R-06 — Native FFI re-implementation cost (Phase 2) · severity M

**Why it matters:** Reusing `face_matcher.cpp` via `dart:ffi` requires building it for Android `armeabi-v7a / arm64-v8a / x86_64`, iOS `arm64`, plus signing rules. Some shops underestimate the iOS code-signing complexity for `.dylib`/`.framework`s embedded in a Flutter app.

**Mitigation:**
- Don't take this on in Phase 1.
- If Phase 2 is greenlit, allow 3 days of buffer for the iOS framework packaging step.
- Consider `package:ffigen` to autogenerate the Dart bindings from a `.h` header.

### R-07 — Image package CPU cost on low-end devices · severity M

**Why it matters:** `package:image`'s pure-Dart histogram equalization, Laplacian variance, and resize ops are 2–4× slower than `Bitmap.getPixels` + `RenderScript`. On a 2 GB-RAM phone the per-frame quality assessment can creep over 50 ms.

**Mitigation:**
- Sample sparsely (every 5th pixel for brightness, every 10th for blur).
- Move per-frame heavy ops to an isolate or skip every other frame.
- If a customer device class can't keep up, gate the enhancement step behind `Platform.isAndroid && devicePixelRatio > 2.5` (rough proxy for "modern hardware").

### R-08 — Unencrypted templates in current Android baseline · severity H

**Why it matters:** A v1 Flutter port that ships before solving §10.3's encryption design exposes biometric templates in clear-text on disk. This is a regulatory issue, not a UX one.

**Mitigation:**
- Encryption design (per `10_security.md`) **blocks v1 release**, not v1 development. Implement encryption alongside the database layer; do not "add later."

### R-09 — Test coverage gap inherited from Android · severity M

**Why it matters:** The Android project's "100 % test coverage" claim refers to manual scenarios, not automated tests. Migrating without writing a unit/widget/integration suite duplicates that gap.

**Mitigation:**
- Treat Android `MANUAL_TESTING_GUIDE.md` as acceptance criteria.
- Build automated tests during the migration, not after. See `13_test_strategy.md` for the matrix.

### R-10 — Compose-specific UI patterns that don't translate · severity S

**Why it matters:** Some Compose helpers (e.g., `Modifier.weight(1f)`, `Brush.verticalGradient`) have direct Flutter analogues but with different defaults. UI parity will require iteration on padding, font sizes, and gradient color stops.

**Mitigation:**
- Capture screen reference screenshots from the Android app at the start of the migration and golden-test them in Flutter (`alchemist` or `flutter_test`'s `matchesGoldenFile`).

### R-11 — `enableEdgeToEdge` on iOS · severity S

**Why it matters:** Android's `enableEdgeToEdge()` extends content under system bars. iOS handles this differently via `SafeArea` (which the Compose code explicitly opts out of via `WindowInsets.systemBars`).

**Mitigation:** Wrap screens in `SafeArea` by default; opt out only for the camera preview body to keep the circular preview centered.

### R-12 — Liveness false-rejects under glare / glasses · severity S

**Why it matters:** ML Kit's eye-open probability is degraded by glasses with strong reflections; the Android source has no glasses-specific tuning. A user with glasses may fail the BLINK step repeatedly.

**Mitigation:** Document as a known limitation; if support tickets pile up, add a "Wearing glasses?" toggle that relaxes blink thresholds (e.g., `eyeClosed = 0.30`, `eyeOpen = 0.55`).

### R-13 — App Store / Play Store biometric data policy · severity M

**Why it matters:** Both stores require explicit privacy disclosures for biometric data. Apple's App Privacy "Data Used to Track You" and Google's Data Safety section need the right answers, or the app gets rejected at review.

**Mitigation:** Coordinate with the PM/legal owner. The honest answer is: face data is collected, stored on-device, and not shared with third parties. Pre-fill the relevant checkboxes (see Play Store compatibility section).

### R-14 — Misleading folder names · severity S

**Why it matters:** The source repository is named `FaceVerficationFlutter` but is an Android Native project. The target Flutter project is at `face_ios_android`. New contributors will confuse them and may commit to the wrong tree.

**Mitigation:** Add a clear note to the root `README.md` of both projects pointing at the other; document the conventions in `CONTRIBUTING.md`.

## 11.2 Dependency-tree risks

| Package | Last published | Maintenance health | Risk |
|---|---|---|---|
| `tflite_flutter` | active | community-maintained | Medium — single maintainer; have a fork plan |
| `google_mlkit_face_detection` | active | maintained by `flutter_mlkit` org | Low |
| `camera` | active | first-party (flutter.dev) | Low |
| `drift` | active | well-maintained | Low |
| `flutter_riverpod` | active | first-party (riverpod.dev) | Low |
| `go_router` | active | first-party | Low |
| `safe_device` | quiet (last update ~6 mo) | community | Medium — keep an eye on `trust_fall` as a backup |
| `flutter_secure_storage` | active | community | Low |
| `image` | active | well-maintained | Low |
| `permission_handler` | active | community | Low |

## 11.3 What can derail the schedule

In rough order of probability:

1. **iOS code-signing surprises** during the first TFLite + ML Kit build. Allocate one day for "first iOS build runs on a real device".
2. **Camera plugin frame-format wiring**. Allocate two days of debugging once the ML Kit integration starts.
3. **Threshold re-tuning** after iOS testing (R-02). Half-day to capture histograms, half-day to roll deltas.
4. **Encryption migration** if added late instead of upfront (R-08). Avoid this by doing it early.

Total risk-buffer recommendation: **+15 %** on top of the effort estimate in `12_effort_estimation.md`.
