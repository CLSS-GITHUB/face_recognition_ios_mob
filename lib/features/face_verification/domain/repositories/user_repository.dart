import 'dart:typed_data';

import '../entities/user.dart';

/// Holds active templates flattened into a contiguous Float32List, plus a
/// parallel index back to the owning user. Mirrors VerificationScreen.kt's
/// pre-warming step. Each row in `flat` at offset `i * embeddingDim` belongs
/// to `map[i]`.
class FlatTemplates {
  const FlatTemplates({required this.flat, required this.map});

  final Float32List flat;
  final List<User> map;

  int get count => map.length;
  bool get isEmpty => map.isEmpty;
}

abstract class UserRepository {
  Future<User?> getById(String id);
  Future<List<User>> getAll();
  Future<List<User>> getActive();
  Stream<List<User>> watchAll();
  Future<void> upsert(User user);
  Future<void> delete(User user);

  /// Flattened active templates ready for FaceMatchingService.findBestMatch.
  Future<FlatTemplates> activeFlatTemplates();
}
