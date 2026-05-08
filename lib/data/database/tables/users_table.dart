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

  @override
  Set<Column> get primaryKey => {userId};

  @override
  String get tableName => 'users';
}
