import 'package:drift/drift.dart';

/// Mirrors `UserEntity` in the Android source. The `faceTemplates` column
/// stores the encrypted output of
/// `TemplateCrypto.encrypt(FaceTemplatesCodec.encode(...))`.
/// Encryption + codec are applied in the repository layer, not in Drift, so
/// the table holds an opaque BLOB.
@DataClassName('UserRow')
class Users extends Table {
  TextColumn get userId => text()();
  TextColumn get name => text()();
  BlobColumn get faceTemplates => blob()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get imagePath => text().nullable()();

  // v2 — added in schemaVersion 2 for the Verify Identity flow. See
  // docs/verification/architecture_recommendations.md §5.1.
  //
  // `enrolledAt` is nullable rather than NOT NULL with a SQL default because
  // SQLite's `ALTER TABLE ADD COLUMN` rejects non-constant defaults
  // (`CURRENT_TIMESTAMP` / `strftime('now')`), which we need at migration
  // time. New rows always get a value through `clientDefault` at the Dart
  // boundary; pre-v2 rows stay NULL ("unknown enrolment time").
  DateTimeColumn get enrolledAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc()).nullable()();
  DateTimeColumn get lastVerifiedAt => dateTime().nullable()();
  BlobColumn get templateMeta => blob().nullable()();

  @override
  Set<Column> get primaryKey => {userId};

  @override
  String get tableName => 'users';
}
