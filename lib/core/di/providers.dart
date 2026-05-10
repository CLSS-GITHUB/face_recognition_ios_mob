import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/app_database.dart';
import '../../features/face_verification/data/repositories/user_repository_impl.dart';
import '../../features/face_verification/domain/repositories/user_repository.dart';
import '../../features/face_verification/domain/usecases/enroll_user.dart';
import '../../services/face_detection_service.dart';
import '../../services/face_matching_service.dart';
import '../../services/face_recognition_service.dart';
import '../../services/liveness_state_machine.dart';
import '../../services/quality_assessor.dart';
import '../platform/permission_check.dart';
import '../platform/security_check.dart';
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
