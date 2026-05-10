import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/users_table.dart';

part 'user_dao.g.dart';

@DriftAccessor(tables: [Users])
class UserDao extends DatabaseAccessor<AppDatabase> with _$UserDaoMixin {
  UserDao(super.db);

  Future<int> insertUser(UsersCompanion user) =>
      into(users).insertOnConflictUpdate(user);

  Future<bool> updateUser(UsersCompanion user) =>
      update(users).replace(user);

  Future<UserRow?> getUserById(String id) =>
      (select(users)..where((t) => t.userId.equals(id))).getSingleOrNull();

  Future<List<UserRow>> getAllUsers() => select(users).get();

  Stream<List<UserRow>> watchAllUsers() => select(users).watch();

  Future<List<UserRow>> getActiveUsers() =>
      (select(users)..where((t) => t.isActive.equals(true))).get();

  Future<int> deleteUser(UserRow user) =>
      (delete(users)..where((t) => t.userId.equals(user.userId))).go();

  /// Stamps `lastVerifiedAt = when` on the user. Used by the verify use case
  /// after a successful match. Returns the number of rows affected (0 if the
  /// user no longer exists).
  Future<int> touchLastVerified(String userId, DateTime when) {
    return (update(users)..where((t) => t.userId.equals(userId)))
        .write(UsersCompanion(lastVerifiedAt: Value(when)));
  }
}
