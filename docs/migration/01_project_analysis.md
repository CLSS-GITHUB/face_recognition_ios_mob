# 01 — Complete Android Project Analysis

## 1.1 Project identity

| Attribute | Value |
|---|---|
| Folder | `D:\Development Projecrts\FaceVerficationFlutter` |
| Gradle root project name | `FaceVerfication` (typo retained from upstream) |
| Application ID | `com.thanaraj.faceverfication` |
| App label | `Face Verification` (`@string/app_name`) |
| Min SDK / Target SDK / Compile SDK | 24 / 36 / 36.1 |
| Kotlin / AGP | 2.2.10 / 9.1.1 |
| Build features enabled | `compose = true`, `viewBinding = true`, `mlModelBinding = true` |
| Native build | CMake 3.22.1, `face_matcher` shared library, ARM NEON SIMD, 16 KB page-size compatible |
| ProGuard | Configured but `isMinifyEnabled = false` for release |
| Backup config | `data_extraction_rules.xml` + `backup_rules.xml` (default scaffold) |

## 1.2 Components declared in `AndroidManifest.xml`

- **Activities (1):** `MainActivity` — single-activity architecture, `screenOrientation = "portrait"`, launcher.
- **Services:** none.
- **Broadcast receivers:** none.
- **Content providers:** none.
- **Permissions:** `INTERNET` (declared, never used), `CAMERA`, `READ_EXTERNAL_STORAGE` (≤ API 32), `READ_MEDIA_IMAGES`.
- **Features:** `android.hardware.camera` (required), `android.hardware.camera.autofocus` (optional).

## 1.3 Screens (Jetpack Compose)

The app uses Compose `NavHost` inside `MainActivity` with five composable destinations:

| Route | Composable | File | Role |
|---|---|---|---|
| `main` | `MainScreen` | `MainActivity.kt` | Dashboard with three action cards (Enroll / Verify / Manage) |
| `enroll` | `NewEnrollmentScreen` | `ui/screens/NewEnrollmentScreen.kt` | Pre-camera form (employee ID + name); gallery option commented out for security; only pathway forward is "Live Camera Enrollment" |
| `live_enroll` | `EnrollmentScreen` | `ui/screens/EnrollmentScreen.kt` | The actual 3-stage enrollment with liveness, embedding capture, and registration dialog |
| `verify` | `VerificationScreen` | `ui/screens/VerificationScreen.kt` | 1:N face match against active users with mandatory blink liveness |
| `manage` | `UserManagementScreen` | `ui/screens/UserManagementScreen.kt` | List/toggle/delete users, observes DB via `Flow` |

Additional helper composables in `MainActivity.kt`: `PermissionScreen` and `SecurityWarningScreen`.

There is also a standalone `LivenessScreen.kt` in `ui/screens/` that is **not wired into `NavHost`** — it appears to be a developer test harness for the liveness state machine.

## 1.4 Enrollment flow (3 stages)

State machine in `EnrollmentScreen.kt`:

```
LIVENESS_ENROLL → VERIFY_ENROLLMENT → REGISTRATION
```

1. **LIVENESS_ENROLL** — runs the 5-step `LivenessDetector` sequence.
   - Steps in order: `BLINK → MOUTH_OPEN → TURN_LEFT → TURN_RIGHT → STILL`.
   - On all-steps-completed: face must be neutral (`|yaw| < 5°`, `|pitch| < 10°`); crop face with 25% margin; run `FaceRecognizer.extractEmbedding(faceBitmap, primaryFace)` (full path: align + enhance).
   - Embedding validity check: non-empty AND any element ≠ 0.
   - Retry: up to **150** attempts on extraction failure (`"Hold still... Frame X/150"`); on overflow, reset liveness.
   - Saves crop to `filesDir/user_faces/user_<UUID>.jpg` (JPEG quality 90).
2. **VERIFY_ENROLLMENT** — secondary blink + similarity check against the just-captured embedding.
   - Mandatory blink (`L && R < 0.25` then `L && R > 0.6`).
   - Re-extract embedding using `fastPath = true` (alignment only, no enhancement). *(See note in `09_performance.md` about the Fast Path/Full Path asymmetry.)*
   - Threshold: similarity ≥ **0.80** to pass; else show "Verification Failed" dialog with retry options.
3. **REGISTRATION** — `AlertDialog` collects `userCode` + `userName`, then:
   - **Duplicate-by-ID:** if `userCode` matches existing `userId`, treat as the same user.
   - **Duplicate-by-face:** if any existing template gives similarity > **0.85**, treat as the same user.
   - **Template dedup:** if the new embedding is > **0.95** similar to any existing template of the matched user, skip insert.
   - Otherwise append the new embedding to the user's `faceTemplates` list and re-activate the user.

## 1.5 Verification flow

- Pre-warm: `LaunchedEffect` loads active users via `userDao.getActiveUsers()`, flattens all 192-D templates into a single `FloatArray(N*192)`, and builds a parallel `List<UserEntity>` index for back-mapping.
- Frame loop:
  1. Reject if multiple faces or no face.
  2. Run `QualityAssessor` (strict centering, no movement step context).
  3. **Mandatory blink liveness** before any matching.
  4. Crop face (25% margin) → extract embedding via `fastPath = false` (this disagrees with the `FaceRecognizer` "fastPath" naming — see comment in source: *"USE STANDARD PATH FOR VERIFICATION TO MATCH ENROLLMENT (ALIGNMENT + ENHANCEMENT)"*).
  5. `FaceMatcher.findBestMatch(embedding, flattenedTemplates, count)` → JNI call to native `findBestMatchNative` (NEON-optimized).
  6. Threshold: similarity > **0.75** AND `bestIndex != -1` ⇒ `Access Granted`.

## 1.6 SDK module map

```
com.thanaraj.faceverfication/
├── MainActivity.kt                   (Compose + NavHost + permission + security gate)
├── camera/
│   ├── CameraPreview.kt              (Composable wrapping AndroidView<PreviewView>)
│   ├── FaceAnalyzer.kt               (ImageAnalysis.Analyzer, ML Kit FAST mode, brightness sample-by-5)
│   └── FaceOverlay.kt                (Composable Canvas; mirrors front camera; cyan box, red landmarks)
├── sdk/
│   ├── data/
│   │   ├── AppDatabase.kt            (Room v4, fallbackToDestructiveMigration, singleton)
│   │   ├── UserDao.kt                (suspend CRUD + Flow<List<UserEntity>>)
│   │   ├── UserEntity.kt             (userId PK, name, faceTemplates: List<FloatArray>, isActive, imagePath)
│   │   └── Converters.kt             (List<FloatArray> ↔ ByteArray, little-endian, size-guarded)
│   ├── detection/
│   │   └── MediaPipeDetector.kt      (Tasks Vision face_landmarker; NOT wired to any screen — experimental)
│   ├── liveness/
│   │   ├── LivenessDetector.kt       (USED — 5-step state machine)
│   │   └── AdvancedLivenessDetector.kt (DEAD — confidence/progress variant)
│   ├── model/
│   │   └── FaceData.kt               (immutable VO mirroring ML Kit Face)
│   ├── processor/
│   │   ├── FaceDetector.kt           (ML Kit ACCURATE + ALL landmarks/classifications, min 0.15)
│   │   └── FaceProcessor.kt          (Face → FaceData)
│   ├── quality/
│   │   ├── QualityAssessor.kt        (USED — fast gates)
│   │   ├── EnhancedQualityAssessor.kt (DEAD — sharpness + occlusion + EAR)
│   │   ├── ImageQualityEngine.kt     (Used inside FaceRecognizer for enhance + alignment + blur metric)
│   │   └── StaticImageValidator.kt   (Used in NewEnrollmentScreen for gallery image validation)
│   ├── recognition/
│   │   ├── FaceRecognizer.kt         (USED — TFLite MobileFaceNet 112×112 → 192-D)
│   │   ├── FaceEmbedder.kt           (DEAD — references missing facenet_128.tflite)
│   │   ├── FaceMatcher.kt            (USED — wraps NativeFaceMatcher)
│   │   ├── NativeFaceMatcher.kt      (USED — JNI to libface_matcher.so)
│   │   └── AdvancedFaceMatcher.kt    (DEAD — pure-Kotlin alternative with threshold presets)
│   └── utils/
│       ├── BitmapUtils.kt            (USED — cropFace 25% margin, saveBitmapToInternalStorage JPEG q90)
│       ├── AdvancedBitmapUtils.kt    (DEAD — superset with rotate/flip/enhance/thumbnail)
│       ├── SecurityUtils.kt          (USED — isRooted via su paths + which su; isEmulator via Build properties)
│       └── ImageLoader.kt            (USED — URI → Bitmap, ImageDecoder on API 29+ else MediaStore)
└── ui/
    ├── fragments/                    (DEAD — XML/View-based parallel implementation, never inflated)
    │   ├── MainFragment.kt
    │   └── EnrollmentFragment.kt
    ├── views/                        (DEAD custom Views, used only by the dead Fragment path)
    │   ├── FaceOverlayView.kt
    │   └── CircularProgressSegmentsView.kt
    ├── screens/                      (LIVE Compose screens — see §1.3)
    └── theme/
        ├── Color.kt
        ├── Theme.kt
        └── Type.kt
```

## 1.7 Native module

- **Path:** `app/src/main/cpp/`
- **Files:** `CMakeLists.txt`, `face_matcher.cpp` (~130 LOC).
- **JNI surface:**
  - `cosineSimilarityNative(FloatArray, FloatArray): Float`
  - `findBestMatchNative(probe: FloatArray, templates: FloatArray, count: Int, dim: Int): Int`
  - `getBestSimilarityNative(probe: FloatArray, templates: FloatArray, count: Int, dim: Int): Float`
- **Algorithm:** ARM NEON `vmlaq_f32` fused multiply-accumulate, processes 4 floats per instruction; `vaddvq_f32` reduction on aarch64. Scalar fallback compiled when `__ARM_NEON` is undefined.
- **Memory:** `GetFloatArrayElements` / `ReleaseFloatArrayElements` with `JNI_ABORT` (no copy-back).
- **`UnsatisfiedLinkError`** is caught in `NativeFaceMatcher.kt` so the app does not crash on platforms without the library.

## 1.8 Models, assets, and resources

- **`assets/mobile_facenet.tflite`** — MobileFaceNet, 112×112 RGB input, 192-D output. *(Only model actually loaded; `FaceEmbedder.kt` references a non-existent `facenet_128.tflite` and is dead code.)*
- **`res/`** — standard mipmaps + Material icons + colors/strings/themes. There is also a `nav_graph.xml` and `fragment_*.xml` set for the dead Fragment path.

## 1.9 Constants & thresholds (single-source-of-truth list)

| Domain | Constant | Value | Source |
|---|---|---|---|
| Detector | ML Kit min face size | 0.15 | `FaceDetector.kt` |
| Detector | ML Kit FaceAnalyzer min size | 0.20 | `FaceAnalyzer.kt` |
| Embedding | Input size | 112×112 | `FaceRecognizer` |
| Embedding | Dimension | 192 | `FaceRecognizer`, `NativeFaceMatcher` |
| Embedding | Norm | L2 | `FaceRecognizer` |
| Embedding | Pixel normalization | `(p - 127.5) / 127.5` | `FaceRecognizer` |
| TFLite | Threads | 4 | `FaceRecognizer` |
| TFLite | XNNPack | enabled | `FaceRecognizer` |
| Quality | Brightness | 45–245 | `QualityAssessor` |
| Quality | Centering offset | 0.20 (0.40 during turns) | `QualityAssessor` |
| Quality | Yaw / pitch (non-turn step) | ±25° | `QualityAssessor` |
| Liveness | Eye closed threshold | < 0.25 | `LivenessDetector` |
| Liveness | Eye open threshold | > 0.60 | `LivenessDetector` |
| Liveness | Yaw turn | > 15° | `LivenessDetector` |
| Liveness | Mouth ratio enter | > 0.85 | `LivenessDetector` |
| Liveness | Mouth ratio exit | < 0.75 | `LivenessDetector` |
| Liveness | Still angles | yaw/pitch < 5° | `LivenessDetector` |
| Crop | Margin | 25% | `BitmapUtils.cropFace` |
| Storage | JPEG quality | 90 | `BitmapUtils.saveBitmapToInternalStorage` |
| Match | Verification threshold | 0.75 | `VerificationScreen` |
| Match | Re-enroll verification threshold | 0.80 | `EnrollmentScreen` (stage 2) |
| Match | Duplicate-by-face | 0.85 | `EnrollmentScreen` (stage 3) |
| Match | Template dedup | 0.95 | `EnrollmentScreen` (stage 3) |
| Retry | Extraction failures | 150 | `EnrollmentScreen` |

## 1.10 Code smells and dead code

1. **Three quality assessors** with overlapping responsibilities. Only `QualityAssessor` is used by screens. `EnhancedQualityAssessor` (richer metrics) and `ImageQualityEngine` (with enhancement) appear to be parallel R&D.
2. **Two liveness detectors** — `LivenessDetector` is used; `AdvancedLivenessDetector` is unused.
3. **Two bitmap utilities** — `BitmapUtils` is used; `AdvancedBitmapUtils` is unused.
4. **Two embedding implementations** — `FaceRecognizer` (192-D MobileFaceNet) is used; `FaceEmbedder` (128-D FaceNet) references a missing model file.
5. **Two matchers** — `FaceMatcher` (native) is used; `AdvancedFaceMatcher` (pure Kotlin) is unused.
6. **Dead Fragment path** — `MainFragment` / `EnrollmentFragment` + `nav_graph.xml` + custom Views never referenced.
7. **Unused dependencies** — Retrofit, OkHttp, Moshi, MediaPipe, Yoonit Facefy, Play Services Location, DataStore Preferences are declared in Gradle but never instantiated in source.
8. **Threading on UI thread** — `EnrollmentScreen` and `VerificationScreen` perform `extractEmbedding` and DB calls **inside the camera analyzer callback** without explicit `withContext(Dispatchers.Default)` for the embedding step in some branches; they rely on the analyzer thread provided by CameraX. This works but is fragile when porting.
9. **`fastPath` naming inversion** — `VerificationScreen.kt` line 218 explicitly passes `fastPath = false` and comments that the "Fast Path" was previously skipping alignment, causing accuracy issues. The flag name is misleading.
10. **`fallbackToDestructiveMigration`** — schema bumps wipe all enrollments. Acceptable for v1 but must change before rolling more users.
11. **Templates stored unencrypted** — see `10_security.md`.
12. **Camera bitmap allocation per frame** — `FaceAnalyzer` converts `ImageProxy → Bitmap` on every frame; expensive vs. YUV-direct.

## 1.11 Test footprint in the Android project

- `test/` and `androidTest/` directories exist but contain only the Android Studio default scaffold tests (`ExampleUnitTest`, `ExampleInstrumentedTest`). The 100% coverage claim in `README.md` and `TEST_VALIDATION_REPORT.md` refers to **manual** test scenarios, not automated tests. The Flutter port should treat manual scenarios as acceptance criteria but build automated coverage from scratch (see `13_test_strategy.md`).

## 1.12 What is genuinely portable to Flutter

- The whole face pipeline is reproducible cross-platform (ML Kit + TFLite + Camera plugins exist for Flutter).
- Native NEON matcher is reproducible via `dart:ffi` if performance demands it; for ≤ 1000 templates a pure Dart loop on `Float32List` is sufficient.
- All thresholds, the 5-step liveness state machine, the 3-stage enrollment, and the byte-buffer template format are platform-agnostic and should be ported verbatim to keep behavioral parity.
