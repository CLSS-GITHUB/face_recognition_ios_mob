import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../services/face_matching_service.dart';
import '../entities/enrollment_result.dart';
import '../entities/user.dart';
import '../repositories/user_repository.dart';

/// Reproduces the registration-stage logic from EnrollmentScreen.kt:
/// 1. If userCode matches an existing user → that user.
/// 2. Else if any existing template has cosine > 0.85 with the new embedding
///    → that user.
/// 3. Else → new user.
/// 4. When updating an existing user, dedup the template at cosine > 0.95.
class EnrollUser {
  EnrollUser(this._repo, this._matcher, [Uuid? uuid])
      : _uuid = uuid ?? const Uuid();

  final UserRepository _repo;
  final FaceMatchingService _matcher;
  final Uuid _uuid;

  Future<EnrollmentResult> call({
    required String userCode,
    required String userName,
    required Float32List embedding,
    String? imagePath,
  }) async {
    final trimmedId = userCode.trim();
    final trimmedName = userName.trim();

    final all = await _repo.getAll();
    User? existing;

    for (final u in all) {
      if (trimmedId.isNotEmpty && u.userId == trimmedId) {
        existing = u;
        break;
      }
      for (final t in u.faceTemplates) {
        if (t.length == embedding.length &&
            _matcher.cosine(embedding, t) >
                FaceThresholds.duplicateFaceThreshold) {
          existing = u;
          break;
        }
      }
      if (existing != null) break;
    }

    if (existing != null) {
      // If the existing user was enrolled under a previous model, drop
      // their old (incompatible) templates rather than appending a new
      // one alongside them — mixing feature spaces in `faceTemplates`
      // poisons the matching bank. The current embedding becomes the
      // sole template under the current model version.
      final isReEnrol = existing.modelVersion != FaceThresholds.modelVersion;
      if (!isReEnrol) {
        final isNewTemplate = existing.faceTemplates.every(
          (t) =>
              t.length != embedding.length ||
              _matcher.cosine(embedding, t) <=
                  FaceThresholds.templateDedupThreshold,
        );
        if (!isNewTemplate) {
          return DuplicateTemplateSkipped(existing);
        }
      }
      final updated = existing.copyWith(
        faceTemplates: isReEnrol
            ? <Float32List>[embedding]
            : [...existing.faceTemplates, embedding],
        isActive: true,
        // Stamp the current model so the row migrates out of the
        // "needs re-enrolment" bucket on this write.
        modelVersion: FaceThresholds.modelVersion,
      );
      await _repo.upsert(updated);
      return TemplateAddedToExisting(updated);
    }

    final id = trimmedId.isEmpty ? _uuid.v4() : trimmedId;
    final user = User(
      userId: id,
      name: trimmedName,
      faceTemplates: [embedding],
      isActive: true,
      imagePath: imagePath,
      modelVersion: FaceThresholds.modelVersion,
    );
    await _repo.upsert(user);
    return NewUserEnrolled(user);
  }
}
