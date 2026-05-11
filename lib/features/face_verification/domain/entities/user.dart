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

  /// True when the templates on this user were extracted by a model
  /// other than the one currently bundled. The active matching bank
  /// skips these users; the UI surfaces a re-enrol prompt instead of a
  /// silent verify failure.
  bool get requiresReEnroll => modelVersion != FaceThresholds.modelVersion;

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
    );
  }
}
