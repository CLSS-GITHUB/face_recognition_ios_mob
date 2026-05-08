# 02 — Android-to-Flutter Feature Mapping

Each Android subsystem is paired with the Flutter package or technique that should replace it. "Stays native" means the feature must be implemented behind a method channel or FFI (custom platform-specific work), not just by a pub.dev plugin.

## 2.1 At-a-glance table

| Subsystem | Android implementation | Flutter implementation | Stays native? |
|---|---|---|---|
| Camera preview & frames | CameraX 1.5 + `Preview` + `ImageAnalysis` (YUV_420_888, KEEP_ONLY_LATEST) | `camera: ^0.11` (uses CameraX on Android, AVFoundation on iOS) | No |
| Face detection | Google ML Kit Face Detection 16.1.7 | `google_mlkit_face_detection: ^0.13` | No |
| Face landmarker (mesh) | MediaPipe Tasks Vision (declared, unused) | Drop. Re-add via `mediapipe_flutter` only if mesh becomes required | N/A |
| TFLite inference | TF Lite 2.17 + GPU + XNNPack, MobileFaceNet | `tflite_flutter: ^0.11` (TFLite 2.16) + GPU/XNNPack delegates | No (plugin handles native) |
| Native NEON matcher | C++ via JNI | **Phase 1:** Dart `Float32List` dot product. **Phase 2:** `dart:ffi` to a small C library reusing `face_matcher.cpp` | Optional FFI |
| Liveness state machine | `LivenessDetector` Kotlin | Pure Dart class; same 5 steps, same thresholds | No |
| Quality assessment | `QualityAssessor` Kotlin | Pure Dart class; same gates | No |
| Image enhancement (alignment + histogram EQ) | `ImageQualityEngine` + `Bitmap` ops | `image: ^4.3` for histogram EQ; transformation-matrix rotation via `dart:ui` Image; native FFI only if profiling demands | No initially |
| Bitmap crop & save | `BitmapUtils` | `image` package + `path_provider` for `getApplicationDocumentsDirectory()` | No |
| Local DB | Room 2.7 (1 entity, 1 DAO) | `drift: ^2.20` (Room-like ergonomics, reactive streams, TypeConverters) | No |
| Schema migration | Room `fallbackToDestructiveMigration` | Drift's manual migration callbacks; preserve template format compat | No |
| Float-array serialization | `Converters.kt` little-endian ByteBuffer | Dart `ByteData` with `Endian.little` + same byte layout | No |
| Image I/O (gallery) | `ImageDecoder` / `MediaStore` | `image_picker: ^1.1` | No |
| Permission flow | Accompanist Permissions | `permission_handler: ^11.3` | No |
| Root / emulator detection | `SecurityUtils.kt` (su paths + Build properties) | `safe_device: ^1.1` for both checks (combine with manual `Platform.environment` for fingerprints if needed) | No |
| Internal file storage | `context.filesDir/user_faces` | `path_provider.getApplicationDocumentsDirectory()` + `dart:io File` | No |
| Preferences (DataStore declared, unused) | DataStore Preferences | Skip. If needed later: `shared_preferences` (plain) or `flutter_secure_storage` (encrypted) | No |
| Networking (Retrofit declared, unused) | Retrofit + OkHttp + Moshi | Skip. If needed later: `dio: ^5.4` + `freezed` + `json_serializable` | No |
| Image loading (Coil) | Coil 2.7 | `Image.file` + `cached_network_image` (only if remote URLs added) | No |
| Navigation | `androidx.navigation.compose` `NavHost` | `go_router: ^14.2` (declarative, deep-link friendly) | No |
| State management | Compose `remember` + `mutableStateOf` | `flutter_riverpod: ^2.5` with `StateNotifier` / `Notifier` | No |
| DI / singletons | Manual `remember { ... }` and `AppDatabase` singleton | Riverpod providers (no get_it needed) | No |
| Theming | Material 3 Compose theme | Material 3 in `MaterialApp` + `ThemeData.from(colorScheme: ColorScheme.fromSeed(...))` | No |
| Edge-to-edge / system bars | `enableEdgeToEdge()` | `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` | No |
| Lifecycle (DisposableEffect) | Compose `DisposableEffect` | `ConsumerStatefulWidget` `dispose()` + Riverpod `onDispose` | No |
| Logging | `android.util.Log` | `package:logging` + `package:logger` for emoji-friendly dev logs | No |
| Background work | None used | `flutter_isolate` / `compute()` for embedding extraction | No |

## 2.2 Choices that need brief justification

**Drift over Sqflite/Isar.** Drift gives:
- Compile-time SQL safety, the closest analogue to Room's `@Query` with KSP.
- First-class `TypeConverter`s for `List<Float32List>` ↔ `Uint8List` — direct port of `Converters.kt` byte layout.
- Reactive `Stream<List<UserEntity>>` for `UserManagementScreen` (the Android side uses `Flow`).
- Cross-platform (sqflite_common_ffi works on desktop test runs, helpful for unit tests).

Isar 4 is faster but its query API and binary format are proprietary, which makes future raw-SQLite operations harder. Sqflite is fine but loses Room ergonomics.

**Riverpod over Bloc/Provider.**
- Project size: ~5 screens, single feature domain; Bloc's event/state classes are excessive boilerplate here.
- Riverpod handles disposal of camera + TFLite resources cleanly via `ref.onDispose`.
- AsyncNotifier covers the verification "load templates → run match" flow with one-call ergonomics.
- Provider is fine but lacks Riverpod's `family` and `autoDispose` modifiers we'll use for per-screen camera lifecycle.

**`go_router` over Navigator 1/`auto_route`.**
- Built-in deep-link & redirect support is useful for the security-warning gate and permission gate (mirrors `MainActivity`'s `if/else` ladder declaratively).
- No code generation step, lower friction.

**`dart:ffi` deferred.** A 1000-template, 192-D cosine search in pure Dart on a `Float32List` is < 5 ms on mid-range Android. Adding FFI doubles the build matrix (Android `.so` + iOS `.dylib`/static lib + macOS for tests). Defer until profiling justifies it.

## 2.3 Features that have NO Flutter equivalent today

- `mlModelBinding = true` (Gradle) — Android-only TFLite metadata code-gen. Replaced by manual TFLite Interpreter setup.
- ARM NEON intrinsics — must be reimplemented in C if FFI'd; iOS uses Accelerate.framework's `vDSP_dotpr`.
- `viewBinding = true` — irrelevant; Flutter has no XML.

## 2.4 Method-channel candidates

If/when these become necessary, expose them as method channels rather than full plugins:

1. **High-throughput batch matcher** — only if Dart matching is profiled too slow. Reuse the existing `face_matcher.cpp` on Android, write a small Accelerate-backed implementation for iOS.
2. **Custom YUV → tensor pipeline** — if the camera plugin's frame conversion costs dominate; otherwise stay in Dart with `tflite_flutter`'s YUV helpers.
3. **Hardware-backed Keystore wrap of templates** — Android Keystore + iOS Keychain via `flutter_secure_storage`; if more granular control is needed, a thin channel over `EncryptedSharedPreferences` + iOS `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

## 2.5 Features deliberately dropped

- **MediaPipe face landmarker** — declared but never imported into a screen. Drop. Re-introduce only if you need 468-point mesh occlusion checks that ML Kit can't provide.
- **Yoonit Facefy** — third-party JitPack lib, declared, unused. Drop.
- **Play Services Location** — declared, never used. Drop.
- **`AdvancedLivenessDetector`, `EnhancedQualityAssessor`, `AdvancedFaceMatcher`, `AdvancedBitmapUtils`, `FaceEmbedder`** — dead Kotlin code. Do not port.
- **Fragment-based UI path** (`MainFragment`, `EnrollmentFragment`, `nav_graph.xml`, custom Views) — dead path. Do not port.

## 2.6 Behavioral-parity guarantees

The migration must preserve, with **identical numeric values**:

- All thresholds in §1.9 of `01_project_analysis.md`.
- The exact 5-step liveness order: `BLINK → MOUTH_OPEN → TURN_LEFT → TURN_RIGHT → STILL`.
- Embedding format: 192 floats, L2-normalized, derived from a 112×112 RGB face crop with `(pixel − 127.5) / 127.5` normalization.
- Storage format: little-endian `ByteBuffer` layout `[int32 list_size][int32 array_size][float32 × array_size]…` — so a database written by the Android app could in principle be read by the Flutter port (deferred goal; not required for v1 since the user base is empty).
- Similarity metric: cosine similarity (dot product of L2-normalized vectors).
