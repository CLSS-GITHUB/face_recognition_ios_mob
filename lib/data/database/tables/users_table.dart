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

  // v3 — face-recognition model version (FaceThresholds.modelVersion) that
  // produced the templates stored in `faceTemplates`. Existing rows get
  // 0 ("unknown / pre-v3"); the repo treats those as `requiresReEnroll`
  // and excludes them from the active matching bank so old templates
  // are never compared against a probe extracted with a different model.
  // SQLite ALTER TABLE ADD COLUMN with a constant default (0) is safe
  // and runs in O(1) — see app_database.dart `onUpgrade`.
  IntColumn get modelVersion =>
      integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {userId};

  @override
  String get tableName => 'users';
}
