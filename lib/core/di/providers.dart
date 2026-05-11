import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../constants/thresholds.dart';
import '../../data/database/app_database.dart';
import '../../features/face_verification/data/adapters/dao_last_verified_sink.dart';
import '../../features/face_verification/data/adapters/isolate_embedding_extractor.dart';
import '../../features/face_verification/data/repositories/user_repository_impl.dart';
import '../../features/face_verification/data/repositories/verification_log_repository_impl.dart';
import '../../features/face_verification/domain/ports/embedding_extractor.dart';
import '../../features/face_verification/domain/ports/last_verified_sink.dart';
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

/// Pre-warms everything the Verify Identity screen needs so the first
/// camera frame is visible quickly after the user taps "Verify Identity"
/// (architecture §6.1: target ≤ 700 ms on Pixel 6).
///
/// Three tasks run in parallel:
///   1. `availableCameras()` — caches the camera list inside the camera
///      plugin so `CameraPreviewWidget._bootstrap` doesn't need to query
///      the OS again.
///   2. `userRepository.activeFlatTemplates()` — performs the per-row
///      AES-GCM decrypt once; the controller's `_warmTemplates` will
///      hit the now-warm in-memory bank cheaply.
///   3. `embeddingIsolateProvider.future` — pays the ~80 ms isolate spawn
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
