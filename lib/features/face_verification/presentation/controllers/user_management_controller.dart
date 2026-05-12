import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../../core/di/providers.dart';
import '../../domain/entities/user.dart';
import '../view_models/user_management_row_vm.dart';

/// Stream of users for the UserManagementScreen. Mirrors
/// `UserDao.getAllUsersFlow().collectAsState()` from the Android source.
final usersStreamProvider = StreamProvider.autoDispose<List<User>>((ref) {
  return ref.watch(userRepositoryProvider).watchAll();
});

/// Joined feed of `users` + per-user aggregates from `verification_logs`.
/// Re-emits whenever either underlying table changes — see
/// `docs/verification/architecture_recommendations.md` §4.2.
final userManagementRowsProvider =
    StreamProvider.autoDispose<List<UserManagementRowVm>>((ref) {
  final db = ref.watch(dbProvider);
  final repo = ref.watch(userRepositoryProvider);

  final usersTrigger = repo.watchAll();
  final logsTrigger = db.select(db.verificationLogs).watch();

  // We want a re-emit whenever either source changes. Both streams emit
  // immediately on subscribe, so the merged stream rebuilds the VM list as
  // soon as the screen mounts.
  return StreamGroup.merge<dynamic>([usersTrigger, logsTrigger])
      .asyncMap((_) async {
    final users = await repo.getAll();
    final dayStart = _startOfLocalDay(DateTime.now());
    return Future.wait(
      users.map((u) async {
        final today = await db.verificationLogDao
            .countSince(u.userId, dayStart);
        final last = await db.verificationLogDao.latestForUser(u.userId);
        return UserManagementRowVm(
          user: u,
          verificationsToday: today,
          lastOutcome: last?.outcome,
          lastVerificationAt: last?.at,
        );
      }),
    );
  });
});

class UserManagementController extends AutoDisposeNotifier<void> {
  static final Logger _log = Logger('UserManagementController');

  /// Reject names outside this range — see architecture §4.4. The lower
  /// bound rejects empty/whitespace-only edits; the upper bound matches
  /// MGR-007.
  static const int minNameLength = 1;
  static const int maxNameLength = 80;

  @override
  void build() {}

  Future<void> toggleActive(User user) async {
    await ref
        .read(userRepositoryProvider)
        .upsert(user.copyWith(isActive: !user.isActive));
    // F-4: bump the bank revision so the verify screen picks up the
    // active/inactive change on its next entry (or its next
    // dismissResult, if it's already open).
    ref.read(userBankRevisionProvider.notifier).update((v) => v + 1);
  }

  Future<void> deleteUser(User user) async {
    final imagePath = user.imagePath;
    if (imagePath != null) {
      try {
        final file = File(imagePath);
        if (file.existsSync()) await file.delete();
      } catch (e, st) {
        _log.warning('Failed to delete face image $imagePath', e, st);
      }
    }
    await ref.read(userRepositoryProvider).delete(user);
    ref.read(userBankRevisionProvider.notifier).update((v) => v + 1);
  }

  /// Renames a user. Validates the new name (1–80 chars, trimmed). The
  /// underlying DAO call only writes the `name` column, so the encrypted
  /// templates blob is untouched — no re-encryption on a name edit.
  ///
  /// Throws [ArgumentError] when the name is invalid; the UI should disable
  /// the save button so this path is unreachable, but the assertion guards
  /// against a misconfigured caller.
  Future<void> renameUser(User user, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.length < minNameLength || trimmed.length > maxNameLength) {
      throw ArgumentError(
        'Name must be between $minNameLength and $maxNameLength '
        'characters; got "${trimmed.length}".',
      );
    }
    if (trimmed == user.name) return; // no-op
    final db = ref.read(dbProvider);
    await db.userDao.updateName(user.userId, trimmed);
    // F-4: rename doesn't affect match (templates unchanged) but the
    // verify-success dialog shows the user's name. Bumping the revision
    // keeps the displayed name fresh after a rename + re-verify.
    ref.read(userBankRevisionProvider.notifier).update((v) => v + 1);
  }
}

DateTime _startOfLocalDay(DateTime now) {
  return DateTime(now.year, now.month, now.day);
}

final userManagementControllerProvider =
    AutoDisposeNotifierProvider<UserManagementController, void>(
        UserManagementController.new);
