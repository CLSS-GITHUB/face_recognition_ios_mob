import 'dart:typed_data';

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
    );
  }
}
