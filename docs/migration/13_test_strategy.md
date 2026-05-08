# 13 — Test Strategy

The Android source has no automated test coverage (only the Android Studio scaffold tests `ExampleUnitTest` / `ExampleInstrumentedTest`). The "100 % coverage" claim in `TEST_VALIDATION_REPORT.md` describes manual scenarios. The Flutter port should ship with a real automated suite, treating those manual scenarios as acceptance criteria.

## 13.1 Test pyramid

| Level | Volume target | Tools | Where in repo |
|---|---|---|---|
| Unit | 70 % of tests | `flutter_test`, `mocktail`, `drift` in-memory | `test/unit/` |
| Widget / golden | 20 % | `flutter_test`, `alchemist` (recommended) | `test/widget/` |
| Integration / E2E | 10 % | `integration_test`, real device when possible | `test/integration/` |

## 13.2 Functional testing — automated unit tests

**Threshold parity tests** (`test/unit/thresholds_parity_test.dart`):
Pin every numeric value in `core/constants/thresholds.dart`. A diff in any constant requires an explicit test update — the test exists to prevent silent behavior drift.

**`FaceTemplatesConverter` tests** (`test/unit/data/face_templates_converter_test.dart`):
- Encode + decode round-trip for sizes 0, 1, 5 templates.
- Decode of a corrupted blob (e.g., `[0xFF, 0xFF, 0xFF, 0xFF]` for listSize) returns `[]` — matches `Converters.kt` behavior.
- Decode of `arraySize > 10000` returns the templates parsed before the bad row, then stops — matches `Converters.kt`.
- A blob produced by the Android app (capture one during interop testing) must decode to the same `List<Float32List>`.

**`LivenessStateMachine` tests** (`test/unit/services/liveness_state_machine_test.dart`):
For each of the five steps, drive the state machine with synthetic `FaceData` and assert step transitions:
- BLINK: `(L=0.2, R=0.2) → (L=0.7, R=0.7)` advances to `MOUTH_OPEN`.
- MOUTH_OPEN: ratio enters > 0.85 then exits < 0.75; advances.
- TURN_LEFT: yaw > 15° advances.
- TURN_RIGHT: yaw < -15° advances.
- STILL: yaw < 5° AND pitch < 5° advances; null after.
Plus reset behavior, "all completed" callback firing exactly once.

**`QualityAssessor` tests** (`test/unit/services/quality_assessor_test.dart`):
Cover each rejection reason exactly once:
- `brightness = 30` → fails with "too dark".
- `face area = 0.02 * frameArea` → fails with "too small".
- centering offset `0.30` during BLINK step → fails; same offset during TURN_LEFT → passes (relaxed centering).
- yaw `35°` during STILL → fails; yaw `35°` during TURN_LEFT → passes.

**`FaceMatchingService` tests** (`test/unit/services/face_matching_service_test.dart`):
- Cosine of two identical L2-normalized vectors = 1.0 ± 1e-6.
- Cosine of orthogonal vectors = 0.
- `findBestMatch` against `[unit_e1, unit_e2, …, unit_e10]` returns index 3 when probe = `unit_e3`.
- `findBestMatch` returns `(-1, < threshold)` when no template clears 0.75.
- Benchmark: 100 / 1000 / 5000 templates × 192-D under 5 ms / 10 ms / 50 ms respectively (looser bounds in CI).

**`EnrollUser` use case tests** (`test/unit/domain/usecases/enroll_user_test.dart`):
- New user (no existing templates) → calls `repo.insert` once.
- Existing user matched by `userId` → calls `repo.update`, templates += new embedding.
- Existing user matched by face (similarity 0.86) → updates the matched user.
- Template dedup (similarity to existing 0.97) → skips insert/update; returns `dedup: true`.

## 13.3 API testing

There are no external APIs in this app. Treat the Drift `UserDao` as the API surface; all DAO methods are covered by unit tests using an in-memory `NativeDatabase.memory()` executor.

## 13.4 UI / widget testing

**Widget tests for cards & atoms** (`test/widget/`):
- `ActionCard` renders title + subtitle + icon, fires `onTap`.
- `InstructionCard` shows the right copy for each `LivenessStep`; shows error tint when quality is bad.
- `CircularProgressSegments` renders 5 arcs; `completedSteps` colors the right number of segments.
- `UserCard` shows fallback icon when `imagePath == null`; shows "Active" pill when `isActive == true`.

**Golden tests for screens**:
- `HomeScreen` (light + dark theme).
- `PermissionScreen`.
- `SecurityWarningScreen`.
- `UserManagementScreen` empty state.
- `UserManagementScreen` with 3 mocked users.

Use `alchemist` to make golden tests stable across CI hosts. Capture goldens once on Linux; CI runs only on Linux.

## 13.5 Validation testing

Pin every input-validation rule from the screens:
- `EnrollFormScreen`: "Complete Enrollment" button enabled only when both `userCode` and `userName` are non-blank.
- `RegistrationDialog` in `LiveEnrollmentScreen`: same.
- `userCode` is trimmed before insertion (test: leading/trailing whitespace stripped).
- `userName` is trimmed.
- Empty `userCode` falls back to `Uuid().v4()` only on the live-camera path that allows it (matches Android `EnrollmentScreen.kt` line 173).

## 13.6 Offline testing

The app is fully on-device. The only "online" requirement is the `INTERNET` permission, which we drop. Tests must run with **no network access** — enforce by spawning the integration test harness with `flutter test --no-pub --dart-define=OFFLINE=true` and asserting no `dio`/`http` initialization in test hooks. (Actual enforcement is by absence of those packages.)

## 13.7 Session handling

There are no logged-in user sessions — verification produces a transient `Access Granted` modal and returns. Tests:
- Verifying user A then user B: B's match returns user B, not user A (no stale session).
- Restarting the app does not retain in-memory `flattenedTemplates`; the next verify pre-warms again.

## 13.8 Background sync

Out of scope — no background work in v1. If `flutter_isolate` or `WorkManager`-equivalents are added later, add a separate tests doc.

## 13.9 Error handling

Each `FaceServiceError` subtype gets at least one test:
- `NoFaceDetectedError` → `InstructionCard` shows "No face detected".
- `MultipleFacesError` → "Multiple faces detected. Only one person allowed.".
- `QualityFailedError` → bullet-list of issues rendered.
- `EmbeddingFailedError` → retry counter increments, transitions to "Hold still... Frame X/150".
- `TFLiteUnavailableError` → user-visible "System error", logged at `WARNING`.

## 13.10 Device rotation

The Android source forces portrait. The Flutter port should match:

```dart
// In main()
await SystemChrome.setPreferredOrientations([
  DeviceOrientation.portraitUp,
]);
```

Test: rotate the device during the integration test; UI does not flip; camera preview keeps a stable orientation.

## 13.11 Performance testing

Run on **at least one** real device per platform per release:

| Metric | Tool | Pass criteria |
|---|---|---|
| Cold start to home screen | `flutter run --profile` + DevTools | ≤ 1 800 ms on Pixel 5 / iPhone 12 |
| First verification end-to-end | Stopwatch in integration test | ≤ 3 000 ms (warm cache) |
| Camera preview FPS | DevTools timeline | ≥ 28 fps sustained |
| Embedding extraction p95 | bench harness | ≤ 200 ms |
| Cosine match (1 000 templates) p95 | bench harness | ≤ 8 ms (Dart) |
| Memory after 20 verifications | DevTools memory | ≤ 320 MB resident |

## 13.12 Memory leak testing

Stress integration test: enroll → verify → enroll → verify, 10 iterations. Force a GC (`Isolate.current.kill()` of an inner isolate is not appropriate; use the dev tools "force GC"). Assert:
- TFLite interpreter count = 0 after teardown.
- No `Image` allocations linger (memory stable within ±20 MB across iterations).

## 13.13 Integration testing

Two integration tests baseline:

**`test/integration/enrollment_flow_test.dart`:**
1. Pump app with mocked `CameraService` that streams pre-recorded frames.
2. Drive the 5-step liveness via timestamped frame fixtures.
3. Confirm the registration dialog appears.
4. Submit user code + name, confirm DB row written.

**`test/integration/verification_flow_test.dart`:**
1. Seed the DB with a known user + 192-D template.
2. Stream a frame whose mocked embedding matches at 0.85 similarity.
3. Confirm the dialog says "Access Granted: <name>".

## 13.14 User acceptance testing

Run the manual scenarios from `MANUAL_TESTING_GUIDE.md` in the Android project, against the Flutter port. Acceptable variance:

| Scenario | Acceptable Flutter outcome |
|---|---|
| E1 baseline enrollment | Same flow, ≤ 90 s |
| E2 retry on blur | Same retry counter UI |
| E3 mouth open without landmarks | No crash; clear error |
| E4 conflicting instructions | Stable; falls back to current step |
| E5 multiple faces | Same rejection copy |
| V1 successful verify | Granted ≤ 5 s |
| V2 unknown face | Denied within 3 s |
| V3 multiple faces in verify | Rejected |
| Q1–Q5 quality boundaries | Each issue surfaces a corresponding string in `InstructionCard` |
| S1–S5 stress / orientation / permission revoke | No crashes; permission revoke returns to `PermissionScreen` |

## 13.15 CI matrix

GitHub Actions or equivalent:

```yaml
jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - flutter analyze --fatal-infos
  test:
    needs: analyze
    runs-on: ubuntu-latest
    steps:
      - flutter test --coverage
      - upload coverage to Codecov
  build_android:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - flutter build apk --split-per-abi
  build_ios:
    needs: test
    runs-on: macos-latest
    steps:
      - flutter build ios --no-codesign
  smoke_device:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - Firebase Test Lab Android matrix (Pixel 6 + Galaxy S22 + low-end e.g. Galaxy A21)
```

Coverage threshold: ≥ 70 % for `lib/services/`, `lib/data/`, `lib/core/utils/`. UI code is covered by goldens, not line coverage.

## 13.16 Test data fixtures

Create a small fixture set under `test/fixtures/`:
- `frames/blink_sequence.bin` — synthetic `FaceData` JSON for the blink step transition.
- `frames/turn_left_sequence.bin` — same for turn-left.
- `templates/user_a.bin` — known 192-D embedding.
- `templates/user_b.bin` — same.
- `golden_screens/*.png` — golden images checked into git.

Total fixture size budget: ≤ 5 MB.
