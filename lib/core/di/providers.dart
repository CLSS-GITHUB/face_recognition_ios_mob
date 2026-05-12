import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../constants/thresholds.dart';
import '../../data/database/app_database.dart';
import '../../features/face_verification/data/adapters/dao_last_verified_sink.dart';
import '../../features/face_verification/data/adapters/isolate_embedding_extractor.dart';
import '../../features/face_verification/data/adapters/isolate_pad_classifier.dart';
import '../../features/face_verification/data/repositories/user_repository_impl.dart';
import '../../features/face_verification/data/repositories/verification_log_repository_impl.dart';
import '../../features/face_verification/domain/ports/embedding_extractor.dart';
import '../../features/face_verification/domain/ports/last_verified_sink.dart';
import '../../features/face_verification/domain/ports/pad_classifier.dart';
import '../../features/face_verification/domain/repositories/user_repository.dart';
import '../../features/face_verification/domain/repositories/verification_log_repository.dart';
import '../../features/face_verification/domain/usecases/enroll_user.dart';
import '../../features/face_verification/domain/usecases/verify_user.dart';
import '../../services/face_detection_service.dart';
import '../../services/face_matching_service.dart';
import '../../services/face_recognition_service.dart';
import '../../services/liveness_state_machine.dart';
import '../../services/quality_assessor.dart';
import '../isolates/embedding_isolate.dart';
import '../isolates/pad_isolate.dart';
import '../platform/permission_check.dart';
import '../platform/rate_limiter.dart';
import '../platform/security_check.dart';
import '../platform/tts_announcer.dart';
import '../security/template_crypto.dart';

/// Application-lifetime database singleton.
final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final securityCheckProvider = Provider<SecurityCheck>((_) => const SecurityCheck());

final permissionCheckProvider =
    Provider<PermissionCheck>((_) => const PermissionCheck());

/// Resolves once per app launch. Watch via `.future`/`.value`.
final securityStatusProvider = FutureProvider<SecurityStatus>((ref) {
  return ref.read(securityCheckProvider).evaluate();
});

/// Reactive camera-permission status. Refreshed via `ref.invalidate` when
/// the user returns from the system permission dialog.
final cameraPermissionProvider = FutureProvider<bool>((ref) {
  return ref.read(permissionCheckProvider).isCameraGranted();
});

final templateCryptoProvider = Provider<TemplateCrypto>((_) => TemplateCrypto());

// ----------------------- Phase 2 face pipeline -----------------------------

/// ML Kit face detector — app-lifetime singleton. (Was autoDispose; that
/// caused the detector to get closed between frames during enrollment,
/// hanging every `processImage` call.)
final faceDetectionServiceProvider = Provider<FaceDetectionService>((ref) {
  final s = FaceDetectionService();
  ref.onDispose(s.dispose);
  return s;
});

final qualityAssessorProvider =
    Provider<QualityAssessor>((_) => const QualityAssessor());

/// One state machine instance, kept alive across frames. Was autoDispose;
/// since callers only `ref.read` it, autoDispose recreated the instance on
/// every read — `_hasSeenOpen`/`_isBlinking` reset every frame and the blink
/// step could never complete. The controller calls `.reset()` on retry, so a
/// shared instance is safe.
final livenessStateMachineProvider =
    Provider<LivenessStateMachine>((_) => LivenessStateMachine());

/// TFLite interpreter — one shared instance across screens. Closes on app
/// teardown. Wrapped in a FutureProvider because asset load is async.
///
/// **Used only by the (legacy) inline match path.** New verify flow goes
/// through [embeddingIsolateProvider] instead. Kept here while
/// `EnrollmentController` still uses it.
final faceRecognitionServiceProvider =
    FutureProvider<FaceRecognitionService>((ref) async {
  final s = await FaceRecognitionService.load();
  ref.onDispose(s.close);
  return s;
});

final faceMatchingServiceProvider =
    Provider<FaceMatchingService>((_) => const FaceMatchingService());

// ----------------------- Phase 3 repository + use cases ---------------------

final userRepositoryProvider = Provider<UserRepository>((ref) {
  final db = ref.watch(dbProvider);
  final crypto = ref.watch(templateCryptoProvider);
  return UserRepositoryImpl(db.userDao, crypto);
});

final enrollUserUseCaseProvider = Provider<EnrollUser>((ref) {
  final repo = ref.watch(userRepositoryProvider);
  final matcher = ref.watch(faceMatchingServiceProvider);
  return EnrollUser(repo, matcher);
});

/// F-4: monotonic revision of the active user bank. Bumped by every
/// mutation path (enrol, delete, toggleActive, rename) and read by the
/// verify controller to decide whether `_warmTemplates` needs to re-run
/// after a result dialog dismissal.
///
/// Why we care: `_warmTemplates` AES-GCM-decrypts every active user's
/// template blob. For a bank of 50 users that's ~30-120 ms. The verify
/// screen used to re-decrypt on every `dismissResult` even though the
/// bank cannot mutate while the result dialog is up (the dialog is
/// modal and the user cannot navigate to Manage Users / Enrol from
/// inside it). This revision counter lets us skip the redundant work
/// while still picking up legitimate changes the moment they happen.
final userBankRevisionProvider = StateProvider<int>((_) => 0);

// ----------------------- Verify Identity wiring -----------------------------
//
// See docs/verification/architecture_recommendations.md §2.3.

/// Long-lived TFLite isolate. `keepAlive` so the spawn cost (≈80 ms cold) is
/// paid once per app process, not per screen.
final embeddingIsolateProvider = FutureProvider<EmbeddingIsolate>((ref) async {
  final iso = await EmbeddingIsolate.spawn();
  ref.onDispose(iso.close);
  return iso;
});

/// Adapts [EmbeddingIsolate] to the domain port. The adapter awaits the
/// spawn future on each call — fast after the first.
final embeddingExtractorProvider = Provider<EmbeddingExtractor>((ref) {
  return IsolateEmbeddingExtractor(ref.watch(embeddingIsolateProvider.future));
});

/// F-10 scaffold: feature flag for the passive PAD (Presentation Attack
/// Detection) classifier. Off by default. When flipped on with
/// `--dart-define=PAD_ENABLED=true` AND a vetted checkpoint is bundled
/// at `assets/models/pad.tflite`, the verify controller's grant path
/// runs the PAD score after a successful match and denies if the score
/// exceeds `FaceThresholds.padSpoofThreshold`.
///
/// Without the flag set, OR if the checkpoint is missing / the isolate
/// fails to spawn, `padClassifierProvider` resolves to
/// `NoOpPadClassifier` — the verify pipeline behaves exactly as it did
/// pre-PAD-scaffold. See `docs/verification/ultra_fast_verification_analysis.md`
/// §9.4 for the security-model rationale.
const bool kPadEnabled =
    bool.fromEnvironment('PAD_ENABLED', defaultValue: false);

/// Decides whether a high PAD spoof score actually vetoes a granted
/// match, or whether the score is only logged for offline analysis.
///
/// - [enforce]: the F-10 scaffold's default. A score above
///   `FaceThresholds.padSpoofThreshold` downgrades a grant to a spoof
///   denial via `_denyForSpoof`. Strictly additive security.
/// - [shadow]: the calibration-study deployment mode. PAD runs and the
///   score lands in `verification_logs.pad_score`, but the controller
///   never short-circuits on it — the user-visible outcome is whatever
///   the rest of the pipeline decided. Lets a team ship a real
///   checkpoint to the field and collect FRR/FAR data on the
///   deployment population before flipping the gate live. Without this
///   step the only way to calibrate `padSpoofThreshold` is to deploy
///   the gate in enforce mode and hope the placeholder 0.5 doesn't
///   over-reject — exactly the trap audit doc §9.4 calls out.
enum PadPolicy { enforce, shadow }

/// Selected via `--dart-define=PAD_POLICY=<enforce|shadow>`. Default is
/// `enforce` so the scaffolded behaviour is preserved when the flag
/// isn't set. Resolved (and any unrecognised value warned about) on
/// first read via [kPadPolicy].
const String _kPadPolicyName = String.fromEnvironment(
  'PAD_POLICY',
  defaultValue: 'enforce',
);

/// Resolved [PadPolicy]. Read it from the controller's hot path —
/// resolution happens once, subsequent reads are a field load.
PadPolicy get kPadPolicy {
  final cached = _padPolicyCache;
  if (cached != null) return cached;
  for (final p in PadPolicy.values) {
    if (p.name == _kPadPolicyName) {
      return _padPolicyCache = p;
    }
  }
  Logger('PadPolicy').warning(
    'Unrecognised PAD_POLICY="$_kPadPolicyName"; falling back to enforce. '
    'Accepted: ${PadPolicy.values.map((p) => p.name).join(', ')}',
  );
  return _padPolicyCache = PadPolicy.enforce;
}

PadPolicy? _padPolicyCache;

/// Output-tensor contract for the bundled PAD checkpoint. Selected via
/// `--dart-define=PAD_MODEL_KIND=<name>`. Accepted values match
/// [PadModelKind] entries: `singleSigmoidScalar`, `binarySoftmax`,
/// `silentFaceThree`. Default is `silentFaceThree`, the audit doc §9.4
/// reference model (Silent-Face MiniFASNet). An unrecognised value
/// falls back to the default with a warning at provider build.
const String _kPadModelKindName = String.fromEnvironment(
  'PAD_MODEL_KIND',
  defaultValue: 'silentFaceThree',
);

/// Pixel normalisation applied inside the isolate. Selected via
/// `--dart-define=PAD_PIXEL_NORM=<name>`. Accepted values match
/// [PadNormalization] entries: `signedHalf`, `unitZeroOne`, `imagenet`.
/// Default is `imagenet`, the Silent-Face training pipeline. An
/// unrecognised value falls back to the default with a warning at
/// provider build.
const String _kPadPixelNormName = String.fromEnvironment(
  'PAD_PIXEL_NORM',
  defaultValue: 'imagenet',
);

PadModelKind _parsePadModelKind(String name, Logger log) {
  for (final k in PadModelKind.values) {
    if (k.name == name) return k;
  }
  log.warning(
    'Unrecognised PAD_MODEL_KIND="$name"; falling back to silentFaceThree. '
    'Accepted: ${PadModelKind.values.map((k) => k.name).join(', ')}',
  );
  return PadModelKind.silentFaceThree;
}

PadNormalization _parsePadNormalization(String name, Logger log) {
  for (final n in PadNormalization.values) {
    if (n.name == name) return n;
  }
  log.warning(
    'Unrecognised PAD_PIXEL_NORM="$name"; falling back to imagenet. '
    'Accepted: ${PadNormalization.values.map((n) => n.name).join(', ')}',
  );
  return PadNormalization.imagenet;
}

/// Resolves the [PadClassifier] used by the verify controller. Falls
/// through three layers in order:
///
/// 1. If [kPadEnabled] is false → [NoOpPadClassifier]. No isolate spawn
///    attempted. Telemetry label: `noop`.
/// 2. Flag on, isolate spawn succeeds → [IsolatePadClassifier] backed
///    by the bundled model. Telemetry label carries the model name.
/// 3. Flag on but spawn fails (checkpoint missing, etc.) → fall back to
///    [NoOpPadClassifier]. Telemetry label: `unavailable` so
///    `/debug/health` shows the field operator that PAD isn't really
///    running.
final padClassifierProvider = Provider<PadClassifier>((ref) {
  if (!kPadEnabled) {
    return const NoOpPadClassifier();
  }
  final log = Logger('PadClassifierProvider');
  final kind = _parsePadModelKind(_kPadModelKindName, log);
  final norm = _parsePadNormalization(_kPadPixelNormName, log);
  final spawnFuture = PadIsolate.spawn(kind: kind, normalization: norm);
  ref.onDispose(() async {
    try {
      final iso = await spawnFuture;
      await iso.close();
    } catch (_) {
      // Spawn failed; nothing to close.
    }
  });
  // The adapter awaits the spawn on every classify call. If spawn
  // ultimately fails the first call rethrows `PadUnavailableError`,
  // which the verify controller catches and treats as "no PAD vote".
  // Label is captured lazily — until the spawn future resolves we
  // report `pad: pending`.
  return IsolatePadClassifier(
    spawnFuture,
    label: 'isolate(pending kind=${kind.name} norm=${norm.name})',
  );
});

/// Adapts the existing UserDao.touchLastVerified to the small domain port.
final lastVerifiedSinkProvider = Provider<LastVerifiedSink>((ref) {
  return DaoLastVerifiedSink(ref.watch(dbProvider).userDao);
});

final verificationLogRepositoryProvider =
    Provider<VerificationLogRepository>((ref) {
  return VerificationLogRepositoryImpl(
    ref.watch(dbProvider).verificationLogDao,
  );
});

/// Cold-start sweep of `verification_logs`. Fires once per app launch
/// (the provider is keepAlive so subsequent `.read`s are no-ops) and
/// drops every row older than [FaceThresholds.verificationLogRetentionDays].
/// Bounds the local audit trail without losing the recent history the
/// Manage Users screen displays.
///
/// Splash calls this fire-and-forget — a maintenance hiccup must never
/// block routing. Errors are caught and surfaced as `0 rows purged`.
final verificationLogPurgeProvider = FutureProvider<int>((ref) async {
  ref.keepAlive();
  final log = Logger('VerificationLogPurge');
  try {
    final repo = ref.read(verificationLogRepositoryProvider);
    final cutoff = DateTime.now().toUtc().subtract(
          const Duration(days: FaceThresholds.verificationLogRetentionDays),
        );
    final removed = await repo.purgeOlderThan(cutoff);
    if (removed > 0) {
      log.fine('Purged $removed verification_log rows older than $cutoff.');
    }
    return removed;
  } catch (e, st) {
    log.warning('verification_log purge failed', e, st);
    return 0;
  }
});

/// Persistent rate limiter for verify attempts. Secure-storage backed so
/// adversaries can't reset by clearing application documents.
final secureStorageProvider = Provider<SecureKeyValueStore>((_) {
  return FlutterSecureStorageAdapter();
});

final rateLimiterProvider = Provider<RateLimiter>((ref) {
  return RateLimiter(storage: ref.watch(secureStorageProvider));
});

/// Spoken result. Best-effort — never throws on speak failures.
final ttsAnnouncerProvider = Provider<TtsAnnouncer>((ref) {
  final tts = FlutterTtsAnnouncer();
  ref.onDispose(tts.dispose);
  return tts;
});

final verifyUserUseCaseProvider = Provider<VerifyUser>((ref) {
  return VerifyUser(
    extractor: ref.watch(embeddingExtractorProvider),
    matcher: ref.watch(faceMatchingServiceProvider),
    userSink: ref.watch(lastVerifiedSinkProvider),
    logRepo: ref.watch(verificationLogRepositoryProvider),
  );
});

/// F-1: long-lived front-facing `CameraController`. The actual
/// `CameraController.initialize()` call dominates the cold tap → first
/// frame latency at ~250-500 ms on Android (camera2 driver open). Moving
/// the controller out of `CameraPreviewWidget` into a `keepAlive`
/// provider lets the verify-side prewarm pay that cost during the
/// home → /verify route transition (~250-300 ms) so the widget binds to
/// an already-initialised stream when it mounts.
///
/// Lifetime: the provider stays alive for the app session — the
/// `CameraPreviewWidget` only owns the image-stream subscription, not
/// the controller itself. The user explicitly accepted the ~3-5%
/// long-running battery cost in exchange for the latency win.
///
/// Failures during init surface as the FutureProvider's `error` state;
/// the widget falls back to its existing error-banner path.
final cameraControllerProvider =
    FutureProvider<CameraController>((ref) async {
  ref.keepAlive();
  final log = Logger('CameraControllerProvider');
  final cameras = await availableCameras();
  final camera = cameras.firstWhere(
    (c) => c.lensDirection == CameraLensDirection.front,
    orElse: () => cameras.first,
  );
  final controller = CameraController(
    camera,
    ResolutionPreset.medium,
    enableAudio: false,
    imageFormatGroup: Platform.isAndroid
        ? ImageFormatGroup.nv21
        : ImageFormatGroup.bgra8888,
  );
  await controller.initialize();
  ref.onDispose(() async {
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e, st) {
      log.warning('stopImageStream during provider dispose failed', e, st);
    }
    try {
      await controller.dispose();
    } catch (e, st) {
      log.warning('CameraController.dispose failed', e, st);
    }
  });
  return controller;
});

/// Pre-warms everything the Verify Identity screen needs so the first
/// camera frame is visible quickly after the user taps "Verify Identity"
/// (architecture §6.1: target ≤ 700 ms on Pixel 6).
///
/// Four tasks run in parallel:
///   1. `availableCameras()` — caches the camera list inside the camera
///      plugin so `cameraControllerProvider` doesn't re-query the OS.
///   2. **F-1: `cameraControllerProvider`** — pays the ~250-500 ms
///      `CameraController.initialize()` cost up-front, so the widget
///      mounts onto a hot controller.
///   3. `userRepository.activeFlatTemplates()` — performs the per-row
///      AES-GCM decrypt once; the controller's `_warmTemplates` will
///      hit the now-warm in-memory bank cheaply.
///   4. `embeddingIsolateProvider.future` — pays the ~80 ms isolate spawn
///      cost (model load + Interpreter.fromBuffer) up-front.
///
/// `keepAlive` so calling it twice is idempotent: the home-screen tap
/// fires it, and the verify screen re-reads it during boot — both resolve
/// instantly the second time.
///
/// Failures are caught and logged: a prewarm hiccup must not block the
/// route push; the verify screen will surface any real failure on its own
/// through the existing error paths.
final verifyPrewarmProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  final log = Logger('VerifyPrewarm');
  await Future.wait<void>([
    () async {
      try {
        await availableCameras();
      } catch (e, st) {
        log.warning('availableCameras prewarm failed', e, st);
      }
    }(),
    () async {
      try {
        await ref.read(cameraControllerProvider.future);
      } catch (e, st) {
        log.warning('cameraController prewarm failed', e, st);
      }
    }(),
    () async {
      try {
        await ref.read(userRepositoryProvider).activeFlatTemplates();
      } catch (e, st) {
        log.warning('templates prewarm failed', e, st);
      }
    }(),
    () async {
      try {
        await ref.read(embeddingIsolateProvider.future);
      } catch (e, st) {
        log.warning('embedding isolate prewarm failed', e, st);
      }
    }(),
  ]);
});
