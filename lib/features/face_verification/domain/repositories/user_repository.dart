import 'dart:typed_data';

import '../entities/user.dart';

/// Holds active templates flattened into a contiguous Float32List, plus
/// two parallel indices:
///
/// - `map[i]`           — owner of the template at `flat[i*embeddingDim]`.
/// - `userOf[i]`        — unique-user index (0-based) for the same slot.
/// - `uniqueUsers[u]`   — the User for unique-user index `u`.
///
/// `map` is kept for backward compatibility with callers that just need
/// to recover the owner of a single template. The verify use case uses
/// the `(userOf, uniqueUsers)` pair to group similarities by user and
/// run an open-set margin check — see FaceMatchingService.findBestUser.
class FlatTemplates {
  const FlatTemplates({
    required this.flat,
    required this.map,
    required this.userOf,
    required this.uniqueUsers,
  });

  /// Convenience factory: builds [userOf] and [uniqueUsers] from a [map]
  /// in O(N) using a userId-keyed lookup. Used by unit-test fixtures.
  factory FlatTemplates.fromMap({
    required Float32List flat,
    required List<User> map,
  }) {
    final uniqueUsers = <User>[];
    final byId = <String, int>{};
    final userOf = Int32List(map.length);
    for (var i = 0; i < map.length; i++) {
      final u = map[i];
      final existing = byId[u.userId];
      if (existing != null) {
        userOf[i] = existing;
      } else {
        final idx = uniqueUsers.length;
        byId[u.userId] = idx;
        uniqueUsers.add(u);
        userOf[i] = idx;
      }
    }
    return FlatTemplates(
      flat: flat,
      map: map,
      userOf: userOf,
      uniqueUsers: uniqueUsers,
    );
  }

  /// Empty bank singleton — used when no users are enrolled.
  static final FlatTemplates empty = FlatTemplates(
    flat: Float32List(0),
    map: const <User>[],
    userOf: Int32List(0),
    uniqueUsers: const <User>[],
  );

  final Float32List flat;
  final List<User> map;
  final Int32List userOf;
  final List<User> uniqueUsers;

  int get count => map.length;
  bool get isEmpty => map.isEmpty;
  int get uniqueUserCount => uniqueUsers.length;
}

abstract class UserRepository {
  Future<User?> getById(String id);
  Future<List<User>> getAll();
  Future<List<User>> getActive();
  Stream<List<User>> watchAll();
  Future<void> upsert(User user);
  Future<void> delete(User user);

  /// Flattened active templates ready for FaceMatchingService.findBestUser.
  Future<FlatTemplates> activeFlatTemplates();
}
