import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/security/template_crypto.dart';
import '../../../../core/utils/byte_layout.dart';
import '../../../../core/utils/template_meta_codec.dart';
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
    const perUserCap = FaceThresholds.maxTemplatesPerUserMatched;
    // Snapshot "now" once per warm so a long getActive() can't shift
    // age verdicts mid-loop. Same value used for every isStaleAsOf
    // check in this pass.
    final now = DateTime.now();

    // First pass: count only valid templates (right-sized **and** from
    // the current model version **and** still within the freshness
    // window). Stale users — by model OR by age — contribute zero
    // templates to the matching bank but remain visible via getActive()
    // so the UI can prompt re-enrolment. Newer templates win on the
    // per-user overflow cap (they are at the tail of the list —
    // EnrollUser appends).
    var total = 0;
    final perUserUsed = <int>[];
    for (final u in users) {
      if (u.isStaleAsOf(now)) {
        perUserUsed.add(0);
        continue;
      }
      var c = 0;
      // Iterate in reverse so we keep the newest `perUserCap` templates
      // when a user has been re-enrolled many times.
      for (var i = u.faceTemplates.length - 1; i >= 0 && c < perUserCap; i--) {
        if (u.faceTemplates[i].length == dim) c++;
      }
      perUserUsed.add(c);
      total += c;
    }

    if (total == 0) {
      // No usable templates — return the canonical empty bank so the
      // controller / use case can short-circuit cleanly without
      // allocating a zero-length buffer per pre-warm.
      return FlatTemplates.empty;
    }

    final flat = Float32List(total * dim);
    final map = <User>[];
    final userOf = Int32List(total);
    final uniqueUsers = <User>[];
    var off = 0;
    var slot = 0;

    for (var ui = 0; ui < users.length; ui++) {
      final u = users[ui];
      final budget = perUserUsed[ui];
      if (budget == 0) continue;
      uniqueUsers.add(u);
      final uIndex = uniqueUsers.length - 1;
      var c = 0;
      for (var i = u.faceTemplates.length - 1; i >= 0 && c < budget; i--) {
        final t = u.faceTemplates[i];
        if (t.length != dim) continue;
        flat.setRange(off, off + dim, t);
        map.add(u);
        userOf[slot] = uIndex;
        off += dim;
        slot++;
        c++;
      }
    }

    return FlatTemplates(
      flat: flat,
      map: map,
      userOf: userOf,
      uniqueUsers: uniqueUsers,
    );
  }

  // --- mapping ----------------------------------------------------------

  Future<User> _rowToUser(UserRow row) async {
    try {
      final raw = await _crypto.decrypt(row.faceTemplates);
      final templates = FaceTemplatesCodec.decode(raw);
      // templateMeta is its own encrypted blob, intentionally separate
      // from the embeddings so a future per-template metadata extension
      // (e.g. depth flag, capture device ID) doesn't churn the larger
      // templates payload. Failure to decrypt the meta blob is non-fatal
      // — we fall back to an empty list, treating every template as
      // glasses-off; the matcher does not care.
      final meta = await _decodeMeta(row.templateMeta);
      return User(
        userId: row.userId,
        name: row.name,
        faceTemplates: templates,
        isActive: row.isActive,
        imagePath: row.imagePath,
        enrolledAt: row.enrolledAt,
        lastVerifiedAt: row.lastVerifiedAt,
        modelVersion: row.modelVersion,
        lastEnrolledAt: row.lastEnrolledAt,
        templateMeta: meta,
      );
    } catch (e, st) {
      _log.warning('Failed to decrypt templates for ${row.userId}', e, st);
      return User(
        userId: row.userId,
        name: row.name,
        faceTemplates: const [],
        isActive: row.isActive,
        imagePath: row.imagePath,
        enrolledAt: row.enrolledAt,
        lastVerifiedAt: row.lastVerifiedAt,
        modelVersion: row.modelVersion,
        lastEnrolledAt: row.lastEnrolledAt,
      );
    }
  }

  /// Decrypt + decode the per-template metadata blob. Null / empty
  /// blobs (legacy rows from before the meta column was wired) return
  /// an empty list.
  Future<List<FaceTemplateMeta>> _decodeMeta(Uint8List? blob) async {
    if (blob == null || blob.isEmpty) {
      return const <FaceTemplateMeta>[];
    }
    try {
      final raw = await _crypto.decrypt(blob);
      return FaceTemplateMetaCodec.decode(raw);
    } catch (e, st) {
      _log.warning('Failed to decrypt templateMeta', e, st);
      return const <FaceTemplateMeta>[];
    }
  }

  Future<UsersCompanion> _userToCompanion(User user) async {
    final raw = FaceTemplatesCodec.encode(user.faceTemplates);
    final encrypted = await _crypto.encrypt(raw);
    // Encrypt the meta blob with the same crypto stack. Empty meta
    // lists encode to a 4-byte zero header which is fine to encrypt
    // — distinguishing "no meta yet" from "meta of length 0" doesn't
    // matter for any consumer.
    final metaRaw = FaceTemplateMetaCodec.encode(user.templateMeta);
    final metaEncrypted = await _crypto.encrypt(metaRaw);
    return UsersCompanion(
      userId: Value(user.userId),
      name: Value(user.name),
      faceTemplates: Value(encrypted),
      isActive: Value(user.isActive),
      imagePath: Value(user.imagePath),
      // `enrolledAt` is left absent on insert so the table's clientDefault
      // (DateTime.now().toUtc()) wins for new rows; an explicit value here
      // would also be respected for fixture imports / re-enrolment.
      enrolledAt: user.enrolledAt == null
          ? const Value.absent()
          : Value(user.enrolledAt),
      lastVerifiedAt: user.lastVerifiedAt == null
          ? const Value.absent()
          : Value(user.lastVerifiedAt),
      modelVersion: Value(user.modelVersion),
      lastEnrolledAt: user.lastEnrolledAt == null
          ? const Value.absent()
          : Value(user.lastEnrolledAt),
      templateMeta: Value(metaEncrypted),
    );
  }
}
