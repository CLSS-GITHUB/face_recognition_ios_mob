# 04 — API Integration Mapping

## 4.1 External APIs

**The Android project does not call any external network API.** Retrofit, OkHttp, and Moshi are declared in `gradle/libs.versions.toml` and pulled into `app/build.gradle.kts` but never imported in any source file (`grep` for `retrofit`, `OkHttp`, `Moshi`, `interceptor` returns zero matches under `app/src/main`). The `INTERNET` permission in the manifest is also unused.

Therefore there is no REST contract, no Firebase project, no remote authentication, and no backend to mirror in the Flutter port.

If/when a backend is introduced (e.g., for centralized enrollment or audit logging), use:

| Concern | Recommended Flutter package | Note |
|---|---|---|
| HTTP client | `dio: ^5.4` | Interceptors, retry, multipart |
| JSON modeling | `freezed: ^2.5` + `json_serializable: ^6.7` | Mirror Moshi codegen ergonomics |
| Auth headers | `dio` request interceptor | Token from `flutter_secure_storage` |
| Logging | `dio_logger` or a custom interceptor | Same scope as Android's `logging-interceptor` |

This document instead maps the **internal SDK API** — the Kotlin classes that screens treat as a "service layer" — to the corresponding Flutter service classes.

## 4.2 Internal SDK API map

Each row is one Kotlin class that screens call. The Flutter column shows the Dart class to create, the package(s) it sits on, and the call signature parity contract.

| Kotlin class | Flutter class | Backed by | Public contract to preserve |
|---|---|---|---|
| `sdk.processor.FaceDetector` | `FaceDetectionService` | `google_mlkit_face_detection` | `Future<List<DetectedFace>> detectFaces(Uint8List rgba, Size frame)` |
| `sdk.processor.FaceProcessor` | inline transformation in `FaceDetectionService` | n/a | `_toFaceData(Face)` private helper |
| `sdk.quality.QualityAssessor` | `QualityAssessor` (pure Dart) | n/a | `QualityResult assess(FaceData face, Size frame, {LivenessStep? currentStep, double brightness})` |
| `sdk.quality.ImageQualityEngine` | `ImageEnhancer` (pure Dart) | `image: ^4.3` | `Future<EnhancedFace> enhance(img.Image source, FaceData face)` returning aligned + (optionally) histogram-equalized bitmap |
| `sdk.liveness.LivenessDetector` | `LivenessStateMachine` (pure Dart) | n/a | `LivenessStep? get currentStep`, `void process(FaceData)`, `void reset()`, callbacks via `Stream<LivenessEvent>` |
| `sdk.recognition.FaceRecognizer` | `FaceRecognitionService` | `tflite_flutter` | `Future<Float32List> extractEmbedding(img.Image faceCrop, FaceData meta, {bool fastPath = false})`, `double calculateSimilarity(Float32List a, Float32List b)`, `Future<void> close()` |
| `sdk.recognition.FaceMatcher` | `FaceMatchingService` | pure Dart (Phase 1) or FFI (Phase 2) | `Future<MatchResult> findBestMatch(Float32List probe, Float32List flattened, int count)` returning `(int index, double similarity)` |
| `sdk.utils.BitmapUtils` | top-level Dart functions in `core/utils/bitmap_utils.dart` | `image: ^4.3`, `path_provider: ^2.1` | `img.Image cropFace(img.Image src, Rect bbox, {double margin = 0.25})`, `Future<String?> saveToInternal(img.Image, String fileName)` |
| `sdk.utils.SecurityUtils` | `SecurityCheck` | `safe_device: ^1.1` (+ supplementary checks) | `Future<bool> isRooted()`, `Future<bool> isEmulator()` |
| `sdk.data.AppDatabase` | `AppDatabase` (Drift) | `drift: ^2.20` + `drift_flutter` + `path_provider` | Singleton, lazy init, exposes `userDao` |
| `sdk.data.UserDao` | `UserDao` (Drift) | `drift` | Mirrors Kotlin DAO; see `05_database_migration.md` |

## 4.3 Service initialization order

The Android app implicitly initializes services on first use inside Compose `remember { ... }` blocks. The Flutter port should be explicit. In `lib/core/di/providers.dart`:

```dart
final securityProvider = FutureProvider<SecurityStatus>((ref) async {
  final s = SecurityCheck();
  return SecurityStatus(rooted: await s.isRooted(), emulator: await s.isEmulator());
});

final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.instance();
  ref.onDispose(db.close);
  return db;
});

final faceDetectorProvider = Provider.autoDispose<FaceDetectionService>((ref) {
  final s = FaceDetectionService();
  ref.onDispose(s.dispose);
  return s;
});

final faceRecognizerProvider = Provider.autoDispose<FaceRecognitionService>((ref) {
  final s = FaceRecognitionService.fromAssets('assets/models/mobile_facenet.tflite');
  ref.onDispose(s.close);
  return s;
});

final qualityAssessorProvider = Provider<QualityAssessor>((_) => QualityAssessor());
final livenessProvider = Provider.autoDispose<LivenessStateMachine>((ref) {
  final l = LivenessStateMachine();
  ref.onDispose(l.dispose);
  return l;
});
final faceMatcherProvider = Provider<FaceMatchingService>((_) => FaceMatchingService());
```

Screens consume these via `ref.watch(...)` instead of inline `remember { ... }` calls.

## 4.4 Error model

Kotlin code returns empty lists / null / boolean false on errors. The Flutter port should be more disciplined:

```dart
sealed class FaceServiceError implements Exception {
  const FaceServiceError(this.message);
  final String message;
}
class NoFaceDetectedError extends FaceServiceError { const NoFaceDetectedError() : super('No face detected'); }
class MultipleFacesError extends FaceServiceError { const MultipleFacesError() : super('Multiple faces detected'); }
class QualityFailedError extends FaceServiceError { const QualityFailedError(this.issues) : super('Quality failed'); final List<String> issues; }
class EmbeddingFailedError extends FaceServiceError { const EmbeddingFailedError() : super('Embedding extraction failed'); }
class TFLiteUnavailableError extends FaceServiceError { const TFLiteUnavailableError() : super('TFLite interpreter unavailable'); }
```

Controllers map errors to user-visible strings using the same wording as the Android UI (e.g., "No face detected", "Multiple faces detected. Only one person allowed.").

## 4.5 Threading contract

Android: ML Kit calls return `Task<T>` awaited via `kotlinx-coroutines-play-services`. TFLite inference is synchronous on the analyzer thread.

Flutter:
- ML Kit Flutter bindings return `Future<List<Face>>` — already off the UI isolate.
- TFLite inference is synchronous and CPU-bound. **Run via `compute()` or a long-lived `Isolate`** to avoid jank during the 80–150 ms inference window. Pass `Float32List` cleanly across isolates (transferable on Dart 3+).
- Database calls via Drift are async and isolated by default (Drift uses an isolate worker).

## 4.6 Frame back-pressure

The Android `CameraX` config uses `STRATEGY_KEEP_ONLY_LATEST`, which drops queued frames. The Flutter `camera` plugin in `startImageStream` produces frames as fast as the platform can deliver — the controller must implement equivalent back-pressure:

```dart
bool _busy = false;
void onCameraImage(CameraImage img) {
  if (_busy) return;          // emulate KEEP_ONLY_LATEST
  _busy = true;
  _process(img).whenComplete(() => _busy = false);
}
```

`isProcessingFrame` in the Android screens is the same idea. Reproduce it.

## 4.7 No public SDK / library boundary

The Android project bundles the face SDK inside the app module under `com.thanaraj.faceverfication.sdk.*`; it is not published as a library. The Flutter port should keep the same intra-app boundary (services live under `lib/services/`); do not extract a `face_verification` package on pub.dev unless a second consumer appears.
