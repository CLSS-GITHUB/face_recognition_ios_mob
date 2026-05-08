# 03 — Screen-by-Screen Migration

For each Compose screen in the Android app, this document specifies:
1. The destination Flutter route + widget,
2. The state contract (controller / Notifier),
3. The widget tree at a glance,
4. Concrete behavior the controller must reproduce.

## 3.1 Routing summary

Replace `androidx.navigation.compose.NavHost` with `go_router`:

```
GoRouter routes:
  /            → SplashGate (does security + permission check, redirects)
  /security    → SecurityWarningScreen   (root/emulator detected)
  /permission  → PermissionScreen        (camera not granted)
  /home        → HomeScreen              (was MainScreen)
  /enroll      → EnrollFormScreen        (was NewEnrollmentScreen)
  /enroll/live → LiveEnrollmentScreen    (was EnrollmentScreen)
  /verify      → VerificationScreen
  /manage      → UserManagementScreen
```

`SplashGate` runs the same logic as `MainActivity.onCreate`'s `LaunchedEffect`:

```dart
// Pseudocode
final secure = await ref.read(securityCheckProvider.future);
if (!secure) return router.go('/security');
final granted = await ref.read(cameraPermissionProvider.future);
if (!granted) return router.go('/permission');
return router.go('/home');
```

## 3.2 HomeScreen (was `MainScreen`)

| Element | Compose | Flutter |
|---|---|---|
| Container | `Column` w/ vertical gradient | `Container` `decoration: BoxDecoration(gradient: LinearGradient(...))` |
| Hero icon | `Box` 160 dp circle + `Icons.Rounded.Fingerprint` | `Container` w/ `BoxDecoration(shape: BoxShape.circle)` + `Icon(Icons.fingerprint_rounded, size: 80)` |
| Action card | `Card { onClick }` w/ icon + title + subtitle + `ArrowForwardIos` | Custom `ActionCard` widget; ink ripple via `InkWell` |
| Cards (3) | Enroll / Verify / Manage Users | Same labels; `context.go('/enroll' \| '/verify' \| '/manage')` |

State: stateless. No controller needed.

## 3.3 EnrollFormScreen (was `NewEnrollmentScreen`)

The Android source has the gallery picker *commented out for security*; the only forward action is "Live Camera Enrollment". Preserve that behavior — do not surface gallery enrollment in v1.

| Element | Compose | Flutter |
|---|---|---|
| TopAppBar | `TopAppBar` + back IconButton | `AppBar(title: Text('New Face Enrollment'), leading: BackButton())` |
| Form fields | Two `TextField`s — Employee ID, Full Name | Two `TextFormField`s; same labels |
| CTA | "Live Camera Enrollment" Button | `FilledButton.icon(icon: Icon(Icons.add_a_photo), onPressed: () => context.push('/enroll/live'))` |
| Validation | `Button enabled` only when both fields non-blank | `ValueListenableBuilder` on both controllers, or local `setState` |

This screen does **not** create the user yet. It hands the entered ID/name to `LiveEnrollmentScreen` via a `GoRouterState.extra` bag, mirroring the pattern of holding `userCode`/`userName` outside the camera analyzer in the Android version.

## 3.4 LiveEnrollmentScreen (was `EnrollmentScreen`)

This is the most complex screen. State is large enough to warrant a controller.

### 3.4.1 Controller contract

```dart
sealed class EnrollmentStage { liveness; verifyEnrollment; registration; }

class EnrollmentState {
  EnrollmentStage stage;
  LivenessStep? currentStep;          // BLINK, MOUTH_OPEN, TURN_LEFT, TURN_RIGHT, STILL, null
  int completedSteps;                 // 0..5
  String status;                      // "Position your face", "Hold still... Frame X/150", etc.
  QualityResult? quality;
  Float32List? capturedEmbedding;
  String? capturedImagePath;
  int extractionRetryCount;
  bool isProcessingFrame;
  // Verification stage
  bool verificationBlinkDetected;
  bool isVerificationBlinking;
  String verificationStatus;
  // Dialog state
  bool showVerificationFailed;
  bool showRegistrationDialog;
}

abstract class EnrollmentController {
  Stream<EnrollmentState> get state;
  void onFrame(CameraFrame frame, List<DetectedFace> faces);
  Future<void> register({required String userCode, required String userName});
  void retry();
  void cancel();
}
```

### 3.4.2 Stage handlers (Dart pseudocode)

The branches inside `CameraPreview.onFacesDetected` map cleanly to controller methods. Reproduce the exact thresholds in `01_project_analysis.md` §1.9.

```dart
void _handleLivenessEnroll(DetectedFace face, CameraFrame frame, double brightness) {
  if (capturedEmbedding != null) return;
  final activeStep = liveness.currentStep;
  final q = quality.assess(face, frame.width, frame.height,
      currentStep: activeStep, brightness: brightness);
  emit(state.copyWith(quality: q));
  if (!q.isGood) return;

  liveness.process(face);
  emit(state.copyWith(currentStep: liveness.currentStep));

  if (liveness.currentStep == null && !state.isProcessingFrame) {
    final isNeutral = face.headEulerY.abs() < 5 && face.headEulerX.abs() < 10;
    if (!isNeutral) return emit(state.copyWith(status: "Hold Still & Look Straight"));

    emit(state.copyWith(isProcessingFrame: true, status: "Capturing Biometrics..."));
    final cropped = await BitmapUtils.cropFace(frame.bitmap, face.boundingBox);
    final embedding = await recognizer.extractEmbedding(cropped, face);
    final ok = embedding.isNotEmpty && embedding.any((v) => v != 0);
    if (ok) {
      final path = await BitmapUtils.saveToInternal(cropped, "user_${uuid.v4()}");
      emit(state.copyWith(capturedEmbedding: embedding, capturedImagePath: path,
          stage: EnrollmentStage.verifyEnrollment, isProcessingFrame: false));
    } else {
      final next = state.extractionRetryCount + 1;
      if (next > 150) {
        liveness.reset();
        emit(state.copyWith(extractionRetryCount: 0, completedSteps: 0,
            status: "Extraction failed. Restarting.", isProcessingFrame: false));
      } else {
        emit(state.copyWith(extractionRetryCount: next,
            status: "Hold still... Frame $next/150", isProcessingFrame: false));
      }
    }
  }
}
```

The `_handleVerifyEnrollment` and `_handleRegistration` methods reproduce the equivalent branches verbatim, with the **same numeric thresholds** (0.25 / 0.6 blink, 0.80 verification, 0.85 duplicate-face, 0.95 template-dedup).

### 3.4.3 Widget tree

```
Scaffold
└── SafeArea
    └── Column
        ├── Text("Face Enrollment", headlineLarge, bold)
        ├── SizedBox(height: 48)
        ├── SizedBox(width: 300, height: 300)  // outer ring
        │   └── Stack
        │       ├── CircularProgressSegments(completed, total: 5)
        │       └── ClipOval(SizedBox(240×240, child: Stack(
        │             [CameraPreviewWidget(onFrame: controller.onFrame),
        │              FaceOverlay(faces, frame)])))
        ├── SizedBox(height: 32)
        ├── Text("Move your head slowly to complete the circle.")
        ├── SizedBox(height: 24)
        ├── InstructionCard(stage, step, status, quality, onRetry)
        ├── Spacer()
        ├── TextButton("Accessibility Options")
        └── FilledButton("Cancel")  // pops route
```

Plus two dialogs (driven by state flags):
- `RegistrationDialog` — `AlertDialog` with two `TextField`s and confirm/dismiss buttons; on confirm runs the duplicate / dedup logic.
- `VerificationFailedDialog` — `AlertDialog` with "Retry Verification" and "Restart Enrollment" actions.

## 3.5 VerificationScreen

### 3.5.1 Controller contract

```dart
class VerificationState {
  String status;                 // "Scanning face...", "Blink to verify...", "Matching Identity..."
  QualityResult? quality;
  bool isVerifying;
  UserEntity? matchedUser;
  bool showResult;
  bool blinkDetected;
  bool isBlinking;
  // Pre-warmed templates
  Float32List flattenedTemplates;   // length = N * 192
  List<UserEntity> templateToUserMap;
  bool isDatabaseReady;
}
```

### 3.5.2 Pre-warm flow

In `initState` (Riverpod `build()` of an `AsyncNotifier`):

```dart
final users = await db.userDao.getActiveUsers();
final flat = Float32List(users.fold(0, (acc, u) => acc + u.faceTemplates.length) * 192);
final map = <UserEntity>[];
var off = 0;
for (final u in users) {
  for (final t in u.faceTemplates) {
    if (t.length == 192) {
      flat.setRange(off, off + 192, t);
      off += 192;
      map.add(u);
    }
  }
}
emit(state.copyWith(flattenedTemplates: flat, templateToUserMap: map, isDatabaseReady: true));
```

### 3.5.3 Frame handler

Reproduce the Android branch order:
1. `> 1` faces → `quality = bad("Multiple faces detected.")`.
2. `0` faces → `quality = bad("No face detected")`.
3. Otherwise → run `QualityAssessor`. If bad, surface issues; do not advance.
4. If good and **not** yet blinked → blink-only liveness.
5. If blinked and not verifying → crop + embed (with **alignment + enhancement** path; in Android this is `extractEmbedding(..., fastPath = false)`).
6. `findBestMatch(probe, flat, map.length)` → `(int index, double similarity)`. Pure Dart implementation by default; FFI later.
7. Threshold: `> 0.75 && index != -1` → `matchedUser = map[index]`.
8. `showResult = true` → `AlertDialog` with `Access Granted` / `Access Denied`.

### 3.5.4 Widget tree

```
Scaffold
└── Column
    ├── Text("Identity Verification", headlineMedium, primary)
    ├── Text("Verify your identity with secure face matching", bodyMedium, secondary)
    ├── SizedBox(height: 32)
    ├── Container(280×280, decoration: BoxDecoration(shape: circle, border: 4dp))
    │   └── ClipOval(Stack([CameraPreviewWidget, FaceOverlay]))
    ├── SizedBox(height: 32)
    └── InstructionCard(step: null, status, quality)
```

## 3.6 UserManagementScreen

| Element | Compose | Flutter |
|---|---|---|
| AppBar | `TopAppBar` w/ back | `AppBar(leading: BackButton())` |
| Empty state | `Box.center { Column [Icon, Text "No users enrolled yet"] }` | Same, with `Center(Column(...))` |
| List | `LazyColumn { items(users) { UserCard } }` | `ListView.separated` |
| Reactive source | `db.userDao().getAllUsersFlow().collectAsState(initial = emptyList())` | `StreamProvider` over Drift's `watchAll()` |
| Toggle active | `Switch` → `db.update(user.copy(isActive = !active))` | `Switch.adaptive` → controller.toggle(user) |
| Delete | `IconButton(Delete)` → confirm dialog → delete file + DB row | Same. Delete file via `dart:io File(path).delete()`. |

`UserCard` widget renders:
- Circular avatar (face crop from `imagePath` via `Image.file`, fallback `Icon(Icons.person)`).
- Name (titleMedium bold), `ID: <userId>`, `Templates: <faceTemplates.length>`.
- Status pill (Active green / Inactive red).
- Switch + Delete IconButton.

## 3.7 PermissionScreen

Trivial. `Icon(Icons.security_rounded, size: 120)` + headline + body + `FilledButton("Grant Permission")` calling `permission_handler`'s `Permission.camera.request()`.

## 3.8 SecurityWarningScreen

Trivial. Red error container with `Icon(Icons.security_rounded, size: 120, color: error)` + headline + body. **No back button** — the user cannot proceed; matches Android behavior of returning early from the NavHost.

## 3.9 Shared widgets to extract

- `ActionCard` — used 3× on `HomeScreen`.
- `InstructionCard` — used by `LiveEnrollmentScreen` and `VerificationScreen`.
- `CircularProgressSegments` — used by `LiveEnrollmentScreen` and (potentially) by future liveness probes.
- `FaceOverlay` — used by `LiveEnrollmentScreen` and `VerificationScreen`.
- `CameraPreviewWidget` — wraps the `camera` plugin's `CameraPreview` and bridges `CameraImage` → controller callback.

## 3.10 Lifecycle & disposal parity

Compose `DisposableEffect(Unit) { onDispose { faceRecognizer.close() } }` →

In Flutter, the equivalent is `Riverpod`:

```dart
final faceRecognizerProvider = Provider.autoDispose<FaceRecognizer>((ref) {
  final r = FaceRecognizer.instance();
  ref.onDispose(r.close);
  return r;
});
```

Camera and DAO providers follow the same pattern. `autoDispose` ensures TFLite interpreters and camera controllers are released as soon as the screen is popped — equivalent to the Compose `DisposableEffect`.
