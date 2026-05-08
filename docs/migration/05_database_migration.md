# 05 — Database Migration

## 5.1 Source schema

`AppDatabase` (Room v4, `fallbackToDestructiveMigration`):

```kotlin
@Entity(tableName = "users")
data class UserEntity(
    @PrimaryKey val userId: String,           // String (UUID or user-provided code)
    val name: String,
    val faceTemplates: List<FloatArray>,      // serialized via Converters
    val isActive: Boolean = true,
    val imagePath: String? = null
)
```

`UserDao`:
```kotlin
@Insert(onConflict = REPLACE) suspend fun insertUser(u: UserEntity)
@Update                       suspend fun updateUser(u: UserEntity)
@Query("SELECT * FROM users WHERE userId = :userId")
                              suspend fun getUserById(userId: String): UserEntity?
@Query("SELECT * FROM users") suspend fun getAllUsers(): List<UserEntity>
@Query("SELECT * FROM users") fun getAllUsersFlow(): Flow<List<UserEntity>>
@Query("SELECT * FROM users WHERE isActive = 1")
                              suspend fun getActiveUsers(): List<UserEntity>
@Delete                       suspend fun deleteUser(u: UserEntity)
```

`Converters`:

```
encode List<FloatArray> → ByteArray  (little-endian)
  put int32 listSize
  for each array:
    put int32 arraySize
    put float32 × arraySize

decode ByteArray → List<FloatArray>
  read int32 listSize       (must be in 0..1000 else return [])
  for i in 0..listSize:
    read int32 arraySize    (must be in 0..10000 and remaining ≥ arraySize*4 else break)
    read arraySize float32s
```

## 5.2 Target schema (Drift)

`lib/data/database/app_database.dart`:

```dart
class Users extends Table {
  TextColumn get userId => text()();
  TextColumn get name => text()();
  // Stored as a single BLOB using the same encoding as the Kotlin Converters,
  // so the byte format is portable and (in principle) backward-compatible.
  BlobColumn get faceTemplates => blob().map(const FaceTemplatesConverter())();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get imagePath => text().nullable()();

  @override Set<Column> get primaryKey => {userId};
  @override String get tableName => 'users';
}

@DriftDatabase(tables: [Users])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);
  @override int get schemaVersion => 1;
}
```

A Drift `TypeConverter` replicates the byte layout exactly:

```dart
class FaceTemplatesConverter extends TypeConverter<List<Float32List>, Uint8List> {
  const FaceTemplatesConverter();

  static const int _maxList = 1000;
  static const int _maxArray = 10000;

  @override
  Uint8List toSql(List<Float32List> value) {
    final size = 4 + value.fold<int>(0, (acc, a) => acc + 4 + a.lengthInBytes);
    final bytes = ByteData(size);
    var off = 0;
    bytes.setInt32(off, value.length, Endian.little); off += 4;
    for (final a in value) {
      bytes.setInt32(off, a.length, Endian.little); off += 4;
      for (var i = 0; i < a.length; i++, off += 4) {
        bytes.setFloat32(off, a[i], Endian.little);
      }
    }
    return bytes.buffer.asUint8List();
  }

  @override
  List<Float32List> fromSql(Uint8List blob) {
    if (blob.length < 4) return const [];
    final data = ByteData.sublistView(blob);
    var off = 0;
    final n = data.getInt32(off, Endian.little); off += 4;
    if (n < 0 || n > _maxList) return const [];
    final out = <Float32List>[];
    for (var i = 0; i < n; i++) {
      if (blob.length - off < 4) break;
      final m = data.getInt32(off, Endian.little); off += 4;
      if (m < 0 || m > _maxArray || (blob.length - off) < m * 4) break;
      final arr = Float32List(m);
      for (var j = 0; j < m; j++, off += 4) {
        arr[j] = data.getFloat32(off, Endian.little);
      }
      out.add(arr);
    }
    return out;
  }
}
```

The behavior matches `Converters.kt` exactly: same magic numbers (1000 / 10000), same endian, same per-record structure, same defensive truncation on corruption.

## 5.3 DAO mapping

| Kotlin DAO | Drift DAO method | Implementation |
|---|---|---|
| `insertUser(u)` REPLACE | `insertUser(UserCompanion u)` | `into(users).insertOnConflictUpdate(u)` |
| `updateUser(u)` | `updateUser(UserCompanion u)` | `update(users).replace(u)` |
| `getUserById(id): UserEntity?` | `getUserById(String id) → Future<User?>` | `(select(users)..where((t)=> t.userId.equals(id))).getSingleOrNull()` |
| `getAllUsers(): List` | `getAllUsers() → Future<List<User>>` | `select(users).get()` |
| `getAllUsersFlow(): Flow` | `watchAllUsers() → Stream<List<User>>` | `select(users).watch()` |
| `getActiveUsers(): List` | `getActiveUsers() → Future<List<User>>` | `(select(users)..where((t)=> t.isActive.equals(true))).get()` |
| `deleteUser(u)` | `deleteUser(User u)` | `delete(users).delete(u)` |

## 5.4 Migration strategy

The Android project uses `fallbackToDestructiveMigration`, meaning **enrolled users are wiped on every schema change**. We will not preserve that behavior — instead start at Drift `schemaVersion = 1` and use `onUpgrade` callbacks for any future column additions:

```dart
@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (m) => m.createAll(),
  onUpgrade: (m, from, to) async {
    if (from < 2) {
      // Example: await m.addColumn(users, users.lastVerifiedAt);
    }
  },
);
```

For the v1 launch, the Flutter app starts with an empty database. There is **no data** to migrate from the Android app — the Android v1 has not shipped to production users (per the documentation status).

## 5.5 File-system data migration

`UserEntity.imagePath` points to JPEG files saved via `BitmapUtils.saveBitmapToInternalStorage(context, bitmap, "user_<UUID>")` which lands in `context.filesDir/user_faces/`.

In Flutter:

```dart
Future<String> saveFaceImage(img.Image bitmap, String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  final faces = Directory('${dir.path}/user_faces');
  if (!faces.existsSync()) faces.createSync(recursive: true);
  final f = File('${faces.path}/$fileName.jpg');
  f.writeAsBytesSync(img.encodeJpg(bitmap, quality: 90));
  return f.path;
}
```

The `getApplicationDocumentsDirectory()` (path_provider) is the cross-platform analogue of `context.filesDir`. Cleanup on user delete uses `File(user.imagePath!).delete()`.

## 5.6 Encryption (recommended addition)

The Android implementation stores templates **unencrypted**. See `10_security.md` for the full plan; database-side, we recommend wrapping Drift's executor with **`drift_sqlcipher`** (SQLCipher-backed) or using a per-template encryption layer with a key stored in `flutter_secure_storage`. The chosen approach should be settled before v1 since changing the on-disk format later is destructive.

## 5.7 Sample queries you'll need

```dart
// Active users only, with their templates flattened — used by VerificationScreen
Future<({Float32List flat, List<User> map})> activeFlatTemplates() async {
  final users = await getActiveUsers();
  final dim = 192;
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
  return (flat: flat, map: map);
}

// Find by user code OR by face similarity > 0.85 — used by EnrollmentScreen registration
Future<User?> findExistingMatch({
  required String userCode,
  required Float32List embedding,
  required FaceMatchingService matcher,
}) async {
  final byCode = await getUserById(userCode);
  if (byCode != null) return byCode;
  final all = await getAllUsers();
  for (final u in all) {
    for (final t in u.faceTemplates) {
      if (matcher.cosine(embedding, t) > 0.85) return u;
    }
  }
  return null;
}
```

## 5.8 Backups and exports

Currently no export feature. If added later, the recommended on-disk format is the same little-endian byte layout used by Drift's converter, plus a small JSON sidecar per user. Encrypting the export is mandatory — face templates are biometric data under most data-protection regimes.
