import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'daos/user_dao.dart';
import 'tables/users_table.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Users], daos: [UserDao])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'face_verification_db'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // No upgrades yet. Add migration steps here as schemaVersion grows;
          // do not use destructive migrations — see docs/migration/05_database_migration.md.
        },
      );
}
