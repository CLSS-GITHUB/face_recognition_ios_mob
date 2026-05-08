import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../../core/di/providers.dart';
import '../../domain/entities/user.dart';

/// Stream of users for the UserManagementScreen. Mirrors
/// `UserDao.getAllUsersFlow().collectAsState()` from the Android source.
final usersStreamProvider = StreamProvider.autoDispose<List<User>>((ref) {
  return ref.watch(userRepositoryProvider).watchAll();
});

class UserManagementController extends AutoDisposeNotifier<void> {
  static final Logger _log = Logger('UserManagementController');

  @override
  void build() {}

  Future<void> toggleActive(User user) async {
    await ref
        .read(userRepositoryProvider)
        .upsert(user.copyWith(isActive: !user.isActive));
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
  }
}

final userManagementControllerProvider =
    AutoDisposeNotifierProvider<UserManagementController, void>(
        UserManagementController.new);
