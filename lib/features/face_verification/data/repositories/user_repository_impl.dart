import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/security/template_crypto.dart';
import '../../../../core/utils/byte_layout.dart';
import '../../../../data/database/app_database.dart';
import '../../../../data/database/daos/user_dao.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/user_repository.dart';

/// Wraps UserDao with the encryption + byte-codec layers documented in
/// docs/migration/05_database_migration.md and 10_security.md.
class UserRepositoryImpl implements UserRepository {
  UserRepositoryImpl(this._dao, this._crypto);

  static final Logger _log = Logger('UserRepository');

  final UserDao _dao;
  final TemplateCrypto _crypto;

  @override
  Future<User?> getById(String id) async {
    final row = await _dao.getUserById(id);
    return row == null ? null : await _rowToUser(row);
  }

  @override
  Future<List<User>> getAll() async {
    final rows = await _dao.getAllUsers();
    return Future.wait(rows.map(_rowToUser));
  }

  @override
  Future<List<User>> getActive() async {
    final rows = await _dao.getActiveUsers();
    return Future.wait(rows.map(_rowToUser));
  }

  @override
  Stream<List<User>> watchAll() {
    return _dao.watchAllUsers().asyncMap(
          (rows) => Future.wait(rows.map(_rowToUser)),
        );
  }

  @override
  Future<void> upsert(User user) async {
    await _dao.insertUser(await _userToCompanion(user));
  }

  @override
  Future<void> delete(User user) async {
    final row = await _dao.getUserById(user.userId);
    if (row != null) await _dao.deleteUser(row);
  }

  @override
  Future<FlatTemplates> activeFlatTemplates() async {
    final users = await getActive();
    const dim = FaceThresholds.embeddingDim;
    final total = users.fold<int>(0, (acc, u) => acc + u.faceTemplates.length);
    final flat = Float32List(total * dim);
    final map = <User>[];
    var off = 0;
    for (final u in users) {
      for (final t in u.faceTemplates) {
        if (t.length == dim) {
          flat.setRange(off, off + dim, t);
          off += dim;
          map.add(u);
        }
      }
    }
    return FlatTemplates(flat: flat, map: map);
  }

  // --- mapping ----------------------------------------------------------

  Future<User> _rowToUser(UserRow row) async {
    try {
      final raw = await _crypto.decrypt(row.faceTemplates);
      final templates = FaceTemplatesCodec.decode(raw);
      return User(
        userId: row.userId,
        name: row.name,
        faceTemplates: templates,
        isActive: row.isActive,
        imagePath: row.imagePath,
      );
    } catch (e, st) {
      _log.warning('Failed to decrypt templates for ${row.userId}', e, st);
      return User(
        userId: row.userId,
        name: row.name,
        faceTemplates: const [],
        isActive: row.isActive,
        imagePath: row.imagePath,
      );
    }
  }

  Future<UsersCompanion> _userToCompanion(User user) async {
    final raw = FaceTemplatesCodec.encode(user.faceTemplates);
    final encrypted = await _crypto.encrypt(raw);
    return UsersCompanion(
      userId: Value(user.userId),
      name: Value(user.name),
      faceTemplates: Value(encrypted),
      isActive: Value(user.isActive),
      imagePath: Value(user.imagePath),
    );
  }
}
