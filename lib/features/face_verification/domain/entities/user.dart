import 'dart:typed_data';

import '../../../../core/constants/thresholds.dart';

/// Domain entity. The Drift `UserRow` lives in the data layer; this is the
/// shape the UI and use cases work with.
class User {
  const User({
    required this.userId,
    required this.name,
    required this.faceTemplates,
    required this.isActive,
    this.imagePath,
    this.enrolledAt,
    this.lastVerifiedAt,
    this.modelVersion = 0,
    this.lastEnrolledAt,
  });

  final String userId;
  final String name;
  final List<Float32List> faceTemplates;
  final bool isActive;
  final String? imagePath;

  /// Wall-clock at which the row was inserted (or migrated). Pre-v2 rows
  /// will have this `null` — see architecture_recommendations.md §5.1.
  final DateTime? enrolledAt;

  /// Last successful verification, or `null` if the user has never
  /// successfully verified. Updated by the VerifyUser use case.
  final DateTime? lastVerifiedAt;

  /// Face-recognition model version that produced this user's stored
  /// templates. Compared against [FaceThresholds.modelVersion] at match
  /// time — mismatches mean the templates live in a different feature
  /// space and must be re-captured before this user can verify again.
  /// `0` means "unknown / legacy" (rows migrated from schema v2).
  final int modelVersion;

  /// Wall-clock at which a template was most recently added for this
  /// user. Distinct from [enrolledAt] (fixed at row creation):
  /// EnrollUser updates this on every save, so the freshness check in
  /// [isStaleAsOf] keeps the bank usable for active re-enrollers and
  /// still defeats slow drift for inactive users. `null` for rows
  /// migrated up from schema v3; readers fall back to [enrolledAt].
  final DateTime? lastEnrolledAt;

  /// True when this user is unusable for matching as of [now], either
  /// because their templates were produced by a different face model
  /// (model-version mismatch) **or** because their last enrolment is
  /// older than [FaceThresholds.templateMaxAgeDays]. Callers that need
  /// determinism should pass an explicit clock; UI rendering uses the
  /// [requiresReEnroll] getter for convenience.
  bool isStaleAsOf(DateTime now) {
    if (modelVersion != FaceThresholds.modelVersion) return true;
    final last = lastEnrolledAt ?? enrolledAt;
    if (last == null) {
      // Rows with neither timestamp pre-date schema v2; their
      // model_version is 0 so the check above already handles them.
      // Returning false here is unreachable in practice; defensive.
      return false;
    }
    final age = now.difference(last);
    return age.inDays > FaceThresholds.templateMaxAgeDays;
  }

  /// True when the templates on this user are unusable for matching.
  /// Fires for *both* a model-version mismatch and a template-age
  /// exceedance — UI surfaces both via the same "Re-enroll" affordance
  /// because the remediation is identical (re-capture).
  bool get requiresReEnroll => isStaleAsOf(DateTime.now());

  User copyWith({
    String? userId,
    String? name,
    List<Float32List>? faceTemplates,
    bool? isActive,
    String? imagePath,
    DateTime? enrolledAt,
    bool clearEnrolledAt = false,
    DateTime? lastVerifiedAt,
    bool clearLastVerifiedAt = false,
    int? modelVersion,
    DateTime? lastEnrolledAt,
    bool clearLastEnrolledAt = false,
  }) {
    return User(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      faceTemplates: faceTemplates ?? this.faceTemplates,
      isActive: isActive ?? this.isActive,
      imagePath: imagePath ?? this.imagePath,
      enrolledAt: clearEnrolledAt ? null : (enrolledAt ?? this.enrolledAt),
      lastVerifiedAt:
          clearLastVerifiedAt ? null : (lastVerifiedAt ?? this.lastVerifiedAt),
      modelVersion: modelVersion ?? this.modelVersion,
      lastEnrolledAt: clearLastEnrolledAt
          ? null
          : (lastEnrolledAt ?? this.lastEnrolledAt),
    );
  }
}
