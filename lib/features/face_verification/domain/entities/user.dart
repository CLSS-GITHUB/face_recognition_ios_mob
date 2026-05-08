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
  });

  final String userId;
  final String name;
  final List<Float32List> faceTemplates;
  final bool isActive;
  final String? imagePath;

  User copyWith({
    String? userId,
    String? name,
    List<Float32List>? faceTemplates,
    bool? isActive,
    String? imagePath,
  }) {
    return User(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      faceTemplates: faceTemplates ?? this.faceTemplates,
      isActive: isActive ?? this.isActive,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}
