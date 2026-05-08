# 07 — Architecture Recommendation

## 7.1 The recommendation in one paragraph

Use **Riverpod 2 + Clean-Lite** (a feature-folder layout with explicit `data/` / `domain/` / `presentation/` slices for the single feature `face_verification`, plus shared `core/` and `services/` folders). State is held in `Notifier`/`AsyncNotifier` controllers exposed via `Provider`s; routing is declarative via `go_router` with redirect-based gates that reproduce the Android `MainActivity` `if/else` ladder. Avoid full Clean Architecture (no use-case classes per query) since the project is small (5 screens, ~2 500 LOC equivalent).

## 7.2 Why Riverpod (and not Bloc / Provider / GetX)

| Criterion | Riverpod 2 | Bloc | Provider | GetX |
|---|---|---|---|---|
| Boilerplate at this scale | Low | High (event/state per screen) | Low | Lowest |
| Disposal of TFLite/Camera | First-class (`autoDispose` + `onDispose`) | Manual via `close()` | Manual | Implicit, opaque |
| Compile-time safety | Yes (no `BuildContext` lookups) | Partial | No (`Provider.of<T>`) | No |
| Test ergonomics | Excellent (`ProviderContainer`) | Excellent | Good | Awkward |
| Async streams (DAO `Flow`) | `StreamProvider` | `BlocStream` | `StreamBuilder` | Reactive `Rx` |
| Community + plugin support | Top-tier | Top-tier | Top-tier | Niche / contested |
| Recommendation | ✓ | Overkill here | Acceptable | Avoid |

The Android source uses Compose `remember { ... }` + `mutableStateOf` (essentially a thin StateFlow). Riverpod's `Notifier` is the closest mental model — same "state holder owned by a scope, disposed when the scope dies" semantics.

## 7.3 Layered architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                   Presentation (lib/features/.../presentation)     │
│   Screens, widgets, controllers (Notifier/AsyncNotifier)           │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ depends on
┌──────────────────────────────▼─────────────────────────────────────┐
│                       Domain (lib/features/.../domain)             │
│   Entities, repository interfaces, light use-cases (only where     │
│   they collapse multi-source orchestration, e.g. EnrollUser)       │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ depends on
┌──────────────────────────────▼─────────────────────────────────────┐
│                         Data (lib/features/.../data)               │
│   Repository implementations, Drift datasource, DTO mapping        │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ uses
┌──────────────────────────────▼─────────────────────────────────────┐
│                      Services (lib/services)                       │
│   FaceDetectionService, FaceRecognitionService,                    │
│   QualityAssessor, LivenessStateMachine, FaceMatchingService       │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ uses
┌──────────────────────────────▼─────────────────────────────────────┐
│                          Core (lib/core)                           │
│   constants, error types, DI providers, platform glue,             │
│   bitmap utils, FFI bindings (later)                               │
└────────────────────────────────────────────────────────────────────┘
```

`services/` holds the direct Kotlin-class equivalents (FaceDetector, FaceRecognizer, etc.) — pure functional services, not feature-specific. They sit *below* the domain layer because they are reusable infrastructure, not business rules.

## 7.4 State flow diagram (LiveEnrollmentScreen example)

```
CameraPlugin (camera)
   │  CameraImage
   ▼
CameraPreviewWidget
   │  onFrame(image, brightness)
   ▼
EnrollmentController (Notifier<EnrollmentState>)
   ├── FaceDetectionService    ─► google_mlkit_face_detection
   ├── QualityAssessor         ─► pure Dart
   ├── LivenessStateMachine    ─► pure Dart
   ├── FaceRecognitionService  ─► tflite_flutter
   ├── BitmapUtils             ─► image + path_provider
   └── UserRepository          ─► Drift
   │  state changes
   ▼
ConsumerWidget rebuilds:
   InstructionCard, CircularProgressSegments, FaceOverlay
```

Each service is a Riverpod `Provider`; the controller `ref.read`s them. Lifetimes:

- `cameraServiceProvider` — `autoDispose`, recreated per screen.
- `faceRecognizerProvider` — `autoDispose`, but **shared between EnrollmentController and VerificationController** via Riverpod's auto-dispose-on-zero-listeners; shipping with `keepAlive` on the family if cold-start cost dominates.
- `dbProvider` — application-wide singleton; `Provider` (no autoDispose).

## 7.5 Why not full Clean Architecture

Clean Architecture's strict use-case-per-query rule produces ~30+ files for this app (one per DAO method + one per service call). For a ~5-screen, single-domain app, that's pure ceremony.

Compromise: keep **explicit use-cases only for orchestrations that span ≥2 services**. Concretely:

- `EnrollUser` (uses face recognition + face matching + repository) — yes, write a use-case class.
- `VerifyUser` (uses face recognition + face matching + repository) — yes.
- `DeleteUser` (one repo call + one File.delete) — no use-case, controller calls repo directly.
- `ToggleUserStatus` (one repo call) — no use-case.
- `ListUsers` — no use-case, screen consumes `StreamProvider` directly.

## 7.6 Routing & gates

Routes mirror the Android `NavHost` plus the gate logic from `MainActivity`:

```dart
final router = GoRouter(
  initialLocation: '/',
  redirect: (ctx, state) async {
    final security = await ProviderScope.containerOf(ctx, listen: false)
        .read(securityProvider.future);
    if (security.rooted || security.emulator) {
      return state.uri.path == '/security' ? null : '/security';
    }
    final granted = await ProviderScope.containerOf(ctx, listen: false)
        .read(cameraPermissionProvider.future);
    if (!granted) return state.uri.path == '/permission' ? null : '/permission';
    return null;
  },
  routes: [
    GoRoute(path: '/',           builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/security',   builder: (_, __) => const SecurityWarningScreen()),
    GoRoute(path: '/permission', builder: (_, __) => const PermissionScreen()),
    GoRoute(path: '/enroll',     builder: (_, __) => const EnrollFormScreen()),
    GoRoute(path: '/enroll/live',builder: (_, __) => const LiveEnrollmentScreen()),
    GoRoute(path: '/verify',     builder: (_, __) => const VerificationScreen()),
    GoRoute(path: '/manage',     builder: (_, __) => const UserManagementScreen()),
  ],
);
```

Gating in the redirect (rather than in the home screen) ensures deep links are always re-checked.

## 7.7 Theming

Recreate the Compose theme using Material 3 in `MaterialApp`:

```dart
final lightScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF1E5AC8),  // copy hex from Android Color.kt
  brightness: Brightness.light,
);
final darkScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF1E5AC8),
  brightness: Brightness.dark,
);

MaterialApp.router(
  theme: ThemeData(useMaterial3: true, colorScheme: lightScheme, ...),
  darkTheme: ThemeData(useMaterial3: true, colorScheme: darkScheme, ...),
  themeMode: ThemeMode.system,
  routerConfig: router,
);
```

The Android `Color.kt` / `Theme.kt` palette must be opened to grab the actual seed color.

## 7.8 Logging

Two-tier logging:

```dart
// Domain / services use the standard `logging` package.
final _log = Logger('FaceRecognizer');
_log.fine('Embedding norm: $norm');

// Wire `logging` events to `logger` for color/emoji output during dev.
Logger.root.level = kReleaseMode ? Level.WARNING : Level.ALL;
Logger.root.onRecord.listen((rec) {
  final logger = Logger('app').level(rec.level);
  ...
});
```

In release builds, downgrade to `WARNING` to avoid leaking PII into device logs (the Android source logs user names — see `10_security.md`).

## 7.9 Component diagram (textual)

```
+---------------------+    +--------------------------+    +---------------+
| LiveEnrollmentScreen|    | VerificationScreen       |    | UserMgmtScrn  |
| (ConsumerWidget)    |    | (ConsumerWidget)         |    | (ConsumerW.)  |
+----------+----------+    +-------------+------------+    +-------+-------+
           |                             |                         |
           v                             v                         v
+---------------------+    +--------------------------+    +---------------+
| EnrollmentController|    | VerificationController   |    | UserMgmtCtrl  |
+----------+----------+    +-------------+------------+    +-------+-------+
           |                             |                         |
           +---------------+-------------+-----------+-------------+
                           |             |           |
                           v             v           v
              +---------------+ +-------------+ +---------------+
              | EnrollUser UC | | VerifyUser  | |     ─         |
              +-------+-------+ +------+------+ +---------------+
                      |                |
                      v                v
              +---------------+ +---------------+
              | UserRepo      | | UserRepo      |
              +-------+-------+ +-------+-------+
                      |                 |
                      v                 v
                 +-------------------------+
                 | UserDao (Drift)         |
                 +-------------------------+

   Services consumed by controllers and use-cases:
   [FaceDetectionService] [QualityAssessor] [LivenessStateMachine]
   [FaceRecognitionService] [FaceMatchingService] [BitmapUtils]
```

## 7.10 What stays out of scope

- No multi-module Dart packages. Single Flutter app, single `lib/` tree.
- No code generation beyond `drift_dev`, `freezed`, `json_serializable`. No riverpod_generator (manual `Provider` declarations are clearer at this size).
- No GetIt — Riverpod handles DI.
- No injectable — Riverpod handles DI.
- No router_generator — go_router supports declarative routes without it.
