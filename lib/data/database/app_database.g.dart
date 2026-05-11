// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $UsersTable extends Users with TableInfo<$UsersTable, UserRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _faceTemplatesMeta = const VerificationMeta(
    'faceTemplates',
  );
  @override
  late final GeneratedColumn<Uint8List> faceTemplates =
      GeneratedColumn<Uint8List>(
        'face_templates',
        aliasedName,
        false,
        type: DriftSqlType.blob,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _imagePathMeta = const VerificationMeta(
    'imagePath',
  );
  @override
  late final GeneratedColumn<String> imagePath = GeneratedColumn<String>(
    'image_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _enrolledAtMeta = const VerificationMeta(
    'enrolledAt',
  );
  @override
  late final GeneratedColumn<DateTime> enrolledAt = GeneratedColumn<DateTime>(
    'enrolled_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    clientDefault: () => DateTime.now().toUtc(),
  );
  static const VerificationMeta _lastVerifiedAtMeta = const VerificationMeta(
    'lastVerifiedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastVerifiedAt =
      GeneratedColumn<DateTime>(
        'last_verified_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _templateMetaMeta = const VerificationMeta(
    'templateMeta',
  );
  @override
  late final GeneratedColumn<Uint8List> templateMeta =
      GeneratedColumn<Uint8List>(
        'template_meta',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _modelVersionMeta = const VerificationMeta(
    'modelVersion',
  );
  @override
  late final GeneratedColumn<int> modelVersion = GeneratedColumn<int>(
    'model_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    name,
    faceTemplates,
    isActive,
    imagePath,
    enrolledAt,
    lastVerifiedAt,
    templateMeta,
    modelVersion,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'users';
  @override
  VerificationContext validateIntegrity(
    Insertable<UserRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('face_templates')) {
      context.handle(
        _faceTemplatesMeta,
        faceTemplates.isAcceptableOrUnknown(
          data['face_templates']!,
          _faceTemplatesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_faceTemplatesMeta);
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    if (data.containsKey('image_path')) {
      context.handle(
        _imagePathMeta,
        imagePath.isAcceptableOrUnknown(data['image_path']!, _imagePathMeta),
      );
    }
    if (data.containsKey('enrolled_at')) {
      context.handle(
        _enrolledAtMeta,
        enrolledAt.isAcceptableOrUnknown(data['enrolled_at']!, _enrolledAtMeta),
      );
    }
    if (data.containsKey('last_verified_at')) {
      context.handle(
        _lastVerifiedAtMeta,
        lastVerifiedAt.isAcceptableOrUnknown(
          data['last_verified_at']!,
          _lastVerifiedAtMeta,
        ),
      );
    }
    if (data.containsKey('template_meta')) {
      context.handle(
        _templateMetaMeta,
        templateMeta.isAcceptableOrUnknown(
          data['template_meta']!,
          _templateMetaMeta,
        ),
      );
    }
    if (data.containsKey('model_version')) {
      context.handle(
        _modelVersionMeta,
        modelVersion.isAcceptableOrUnknown(
          data['model_version']!,
          _modelVersionMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  UserRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserRow(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      faceTemplates: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}face_templates'],
      )!,
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
      imagePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_path'],
      ),
      enrolledAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}enrolled_at'],
      ),
      lastVerifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_verified_at'],
      ),
      templateMeta: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}template_meta'],
      ),
      modelVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}model_version'],
      )!,
    );
  }

  @override
  $UsersTable createAlias(String alias) {
    return $UsersTable(attachedDatabase, alias);
  }
}

class UserRow extends DataClass implements Insertable<UserRow> {
  final String userId;
  final String name;
  final Uint8List faceTemplates;
  final bool isActive;
  final String? imagePath;
  final DateTime? enrolledAt;
  final DateTime? lastVerifiedAt;
  final Uint8List? templateMeta;
  final int modelVersion;
  const UserRow({
    required this.userId,
    required this.name,
    required this.faceTemplates,
    required this.isActive,
    this.imagePath,
    this.enrolledAt,
    this.lastVerifiedAt,
    this.templateMeta,
    required this.modelVersion,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['name'] = Variable<String>(name);
    map['face_templates'] = Variable<Uint8List>(faceTemplates);
    map['is_active'] = Variable<bool>(isActive);
    if (!nullToAbsent || imagePath != null) {
      map['image_path'] = Variable<String>(imagePath);
    }
    if (!nullToAbsent || enrolledAt != null) {
      map['enrolled_at'] = Variable<DateTime>(enrolledAt);
    }
    if (!nullToAbsent || lastVerifiedAt != null) {
      map['last_verified_at'] = Variable<DateTime>(lastVerifiedAt);
    }
    if (!nullToAbsent || templateMeta != null) {
      map['template_meta'] = Variable<Uint8List>(templateMeta);
    }
    map['model_version'] = Variable<int>(modelVersion);
    return map;
  }

  UsersCompanion toCompanion(bool nullToAbsent) {
    return UsersCompanion(
      userId: Value(userId),
      name: Value(name),
      faceTemplates: Value(faceTemplates),
      isActive: Value(isActive),
      imagePath: imagePath == null && nullToAbsent
          ? const Value.absent()
          : Value(imagePath),
      enrolledAt: enrolledAt == null && nullToAbsent
          ? const Value.absent()
          : Value(enrolledAt),
      lastVerifiedAt: lastVerifiedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastVerifiedAt),
      templateMeta: templateMeta == null && nullToAbsent
          ? const Value.absent()
          : Value(templateMeta),
      modelVersion: Value(modelVersion),
    );
  }

  factory UserRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserRow(
      userId: serializer.fromJson<String>(json['userId']),
      name: serializer.fromJson<String>(json['name']),
      faceTemplates: serializer.fromJson<Uint8List>(json['faceTemplates']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      imagePath: serializer.fromJson<String?>(json['imagePath']),
      enrolledAt: serializer.fromJson<DateTime?>(json['enrolledAt']),
      lastVerifiedAt: serializer.fromJson<DateTime?>(json['lastVerifiedAt']),
      templateMeta: serializer.fromJson<Uint8List?>(json['templateMeta']),
      modelVersion: serializer.fromJson<int>(json['modelVersion']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'name': serializer.toJson<String>(name),
      'faceTemplates': serializer.toJson<Uint8List>(faceTemplates),
      'isActive': serializer.toJson<bool>(isActive),
      'imagePath': serializer.toJson<String?>(imagePath),
      'enrolledAt': serializer.toJson<DateTime?>(enrolledAt),
      'lastVerifiedAt': serializer.toJson<DateTime?>(lastVerifiedAt),
      'templateMeta': serializer.toJson<Uint8List?>(templateMeta),
      'modelVersion': serializer.toJson<int>(modelVersion),
    };
  }

  UserRow copyWith({
    String? userId,
    String? name,
    Uint8List? faceTemplates,
    bool? isActive,
    Value<String?> imagePath = const Value.absent(),
    Value<DateTime?> enrolledAt = const Value.absent(),
    Value<DateTime?> lastVerifiedAt = const Value.absent(),
    Value<Uint8List?> templateMeta = const Value.absent(),
    int? modelVersion,
  }) => UserRow(
    userId: userId ?? this.userId,
    name: name ?? this.name,
    faceTemplates: faceTemplates ?? this.faceTemplates,
    isActive: isActive ?? this.isActive,
    imagePath: imagePath.present ? imagePath.value : this.imagePath,
    enrolledAt: enrolledAt.present ? enrolledAt.value : this.enrolledAt,
    lastVerifiedAt: lastVerifiedAt.present
        ? lastVerifiedAt.value
        : this.lastVerifiedAt,
    templateMeta: templateMeta.present ? templateMeta.value : this.templateMeta,
    modelVersion: modelVersion ?? this.modelVersion,
  );
  UserRow copyWithCompanion(UsersCompanion data) {
    return UserRow(
      userId: data.userId.present ? data.userId.value : this.userId,
      name: data.name.present ? data.name.value : this.name,
      faceTemplates: data.faceTemplates.present
          ? data.faceTemplates.value
          : this.faceTemplates,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      imagePath: data.imagePath.present ? data.imagePath.value : this.imagePath,
      enrolledAt: data.enrolledAt.present
          ? data.enrolledAt.value
          : this.enrolledAt,
      lastVerifiedAt: data.lastVerifiedAt.present
          ? data.lastVerifiedAt.value
          : this.lastVerifiedAt,
      templateMeta: data.templateMeta.present
          ? data.templateMeta.value
          : this.templateMeta,
      modelVersion: data.modelVersion.present
          ? data.modelVersion.value
          : this.modelVersion,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserRow(')
          ..write('userId: $userId, ')
          ..write('name: $name, ')
          ..write('faceTemplates: $faceTemplates, ')
          ..write('isActive: $isActive, ')
          ..write('imagePath: $imagePath, ')
          ..write('enrolledAt: $enrolledAt, ')
          ..write('lastVerifiedAt: $lastVerifiedAt, ')
          ..write('templateMeta: $templateMeta, ')
          ..write('modelVersion: $modelVersion')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    userId,
    name,
    $driftBlobEquality.hash(faceTemplates),
    isActive,
    imagePath,
    enrolledAt,
    lastVerifiedAt,
    $driftBlobEquality.hash(templateMeta),
    modelVersion,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserRow &&
          other.userId == this.userId &&
          other.name == this.name &&
          $driftBlobEquality.equals(other.faceTemplates, this.faceTemplates) &&
          other.isActive == this.isActive &&
          other.imagePath == this.imagePath &&
          other.enrolledAt == this.enrolledAt &&
          other.lastVerifiedAt == this.lastVerifiedAt &&
          $driftBlobEquality.equals(other.templateMeta, this.templateMeta) &&
          other.modelVersion == this.modelVersion);
}

class UsersCompanion extends UpdateCompanion<UserRow> {
  final Value<String> userId;
  final Value<String> name;
  final Value<Uint8List> faceTemplates;
  final Value<bool> isActive;
  final Value<String?> imagePath;
  final Value<DateTime?> enrolledAt;
  final Value<DateTime?> lastVerifiedAt;
  final Value<Uint8List?> templateMeta;
  final Value<int> modelVersion;
  final Value<int> rowid;
  const UsersCompanion({
    this.userId = const Value.absent(),
    this.name = const Value.absent(),
    this.faceTemplates = const Value.absent(),
    this.isActive = const Value.absent(),
    this.imagePath = const Value.absent(),
    this.enrolledAt = const Value.absent(),
    this.lastVerifiedAt = const Value.absent(),
    this.templateMeta = const Value.absent(),
    this.modelVersion = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UsersCompanion.insert({
    required String userId,
    required String name,
    required Uint8List faceTemplates,
    this.isActive = const Value.absent(),
    this.imagePath = const Value.absent(),
    this.enrolledAt = const Value.absent(),
    this.lastVerifiedAt = const Value.absent(),
    this.templateMeta = const Value.absent(),
    this.modelVersion = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       name = Value(name),
       faceTemplates = Value(faceTemplates);
  static Insertable<UserRow> custom({
    Expression<String>? userId,
    Expression<String>? name,
    Expression<Uint8List>? faceTemplates,
    Expression<bool>? isActive,
    Expression<String>? imagePath,
    Expression<DateTime>? enrolledAt,
    Expression<DateTime>? lastVerifiedAt,
    Expression<Uint8List>? templateMeta,
    Expression<int>? modelVersion,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (name != null) 'name': name,
      if (faceTemplates != null) 'face_templates': faceTemplates,
      if (isActive != null) 'is_active': isActive,
      if (imagePath != null) 'image_path': imagePath,
      if (enrolledAt != null) 'enrolled_at': enrolledAt,
      if (lastVerifiedAt != null) 'last_verified_at': lastVerifiedAt,
      if (templateMeta != null) 'template_meta': templateMeta,
      if (modelVersion != null) 'model_version': modelVersion,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UsersCompanion copyWith({
    Value<String>? userId,
    Value<String>? name,
    Value<Uint8List>? faceTemplates,
    Value<bool>? isActive,
    Value<String?>? imagePath,
    Value<DateTime?>? enrolledAt,
    Value<DateTime?>? lastVerifiedAt,
    Value<Uint8List?>? templateMeta,
    Value<int>? modelVersion,
    Value<int>? rowid,
  }) {
    return UsersCompanion(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      faceTemplates: faceTemplates ?? this.faceTemplates,
      isActive: isActive ?? this.isActive,
      imagePath: imagePath ?? this.imagePath,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      templateMeta: templateMeta ?? this.templateMeta,
      modelVersion: modelVersion ?? this.modelVersion,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (faceTemplates.present) {
      map['face_templates'] = Variable<Uint8List>(faceTemplates.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (imagePath.present) {
      map['image_path'] = Variable<String>(imagePath.value);
    }
    if (enrolledAt.present) {
      map['enrolled_at'] = Variable<DateTime>(enrolledAt.value);
    }
    if (lastVerifiedAt.present) {
      map['last_verified_at'] = Variable<DateTime>(lastVerifiedAt.value);
    }
    if (templateMeta.present) {
      map['template_meta'] = Variable<Uint8List>(templateMeta.value);
    }
    if (modelVersion.present) {
      map['model_version'] = Variable<int>(modelVersion.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UsersCompanion(')
          ..write('userId: $userId, ')
          ..write('name: $name, ')
          ..write('faceTemplates: $faceTemplates, ')
          ..write('isActive: $isActive, ')
          ..write('imagePath: $imagePath, ')
          ..write('enrolledAt: $enrolledAt, ')
          ..write('lastVerifiedAt: $lastVerifiedAt, ')
          ..write('templateMeta: $templateMeta, ')
          ..write('modelVersion: $modelVersion, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VerificationLogsTable extends VerificationLogs
    with TableInfo<$VerificationLogsTable, VerificationLogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VerificationLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES users (user_id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _atMeta = const VerificationMeta('at');
  @override
  late final GeneratedColumn<DateTime> at = GeneratedColumn<DateTime>(
    'at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _outcomeMeta = const VerificationMeta(
    'outcome',
  );
  @override
  late final GeneratedColumn<String> outcome = GeneratedColumn<String>(
    'outcome',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _failureReasonMeta = const VerificationMeta(
    'failureReason',
  );
  @override
  late final GeneratedColumn<String> failureReason = GeneratedColumn<String>(
    'failure_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bestSimilarityMeta = const VerificationMeta(
    'bestSimilarity',
  );
  @override
  late final GeneratedColumn<double> bestSimilarity = GeneratedColumn<double>(
    'best_similarity',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _latencyMsMeta = const VerificationMeta(
    'latencyMs',
  );
  @override
  late final GeneratedColumn<int> latencyMs = GeneratedColumn<int>(
    'latency_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    userId,
    at,
    outcome,
    failureReason,
    bestSimilarity,
    latencyMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'verification_logs';
  @override
  VerificationContext validateIntegrity(
    Insertable<VerificationLogRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    }
    if (data.containsKey('at')) {
      context.handle(_atMeta, at.isAcceptableOrUnknown(data['at']!, _atMeta));
    } else if (isInserting) {
      context.missing(_atMeta);
    }
    if (data.containsKey('outcome')) {
      context.handle(
        _outcomeMeta,
        outcome.isAcceptableOrUnknown(data['outcome']!, _outcomeMeta),
      );
    } else if (isInserting) {
      context.missing(_outcomeMeta);
    }
    if (data.containsKey('failure_reason')) {
      context.handle(
        _failureReasonMeta,
        failureReason.isAcceptableOrUnknown(
          data['failure_reason']!,
          _failureReasonMeta,
        ),
      );
    }
    if (data.containsKey('best_similarity')) {
      context.handle(
        _bestSimilarityMeta,
        bestSimilarity.isAcceptableOrUnknown(
          data['best_similarity']!,
          _bestSimilarityMeta,
        ),
      );
    }
    if (data.containsKey('latency_ms')) {
      context.handle(
        _latencyMsMeta,
        latencyMs.isAcceptableOrUnknown(data['latency_ms']!, _latencyMsMeta),
      );
    } else if (isInserting) {
      context.missing(_latencyMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  VerificationLogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VerificationLogRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      ),
      at: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}at'],
      )!,
      outcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outcome'],
      )!,
      failureReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}failure_reason'],
      ),
      bestSimilarity: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}best_similarity'],
      ),
      latencyMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}latency_ms'],
      )!,
    );
  }

  @override
  $VerificationLogsTable createAlias(String alias) {
    return $VerificationLogsTable(attachedDatabase, alias);
  }
}

class VerificationLogRow extends DataClass
    implements Insertable<VerificationLogRow> {
  final int id;

  /// Foreign key to `users.userId`. Nullable for "no match" / spoof rows. We
  /// use ON DELETE SET NULL so deleting a user keeps the log row for forensic
  /// completeness — see architecture_recommendations.md §M Test MGR-009.
  final String? userId;
  final DateTime at;

  /// One of: granted / denied / error / rateLimited / spoof / lowLight /
  /// occluded / multiFace / noFace / blinkRequired / qualityFailed / timeout.
  final String outcome;
  final String? failureReason;
  final double? bestSimilarity;
  final int latencyMs;
  const VerificationLogRow({
    required this.id,
    this.userId,
    required this.at,
    required this.outcome,
    this.failureReason,
    this.bestSimilarity,
    required this.latencyMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || userId != null) {
      map['user_id'] = Variable<String>(userId);
    }
    map['at'] = Variable<DateTime>(at);
    map['outcome'] = Variable<String>(outcome);
    if (!nullToAbsent || failureReason != null) {
      map['failure_reason'] = Variable<String>(failureReason);
    }
    if (!nullToAbsent || bestSimilarity != null) {
      map['best_similarity'] = Variable<double>(bestSimilarity);
    }
    map['latency_ms'] = Variable<int>(latencyMs);
    return map;
  }

  VerificationLogsCompanion toCompanion(bool nullToAbsent) {
    return VerificationLogsCompanion(
      id: Value(id),
      userId: userId == null && nullToAbsent
          ? const Value.absent()
          : Value(userId),
      at: Value(at),
      outcome: Value(outcome),
      failureReason: failureReason == null && nullToAbsent
          ? const Value.absent()
          : Value(failureReason),
      bestSimilarity: bestSimilarity == null && nullToAbsent
          ? const Value.absent()
          : Value(bestSimilarity),
      latencyMs: Value(latencyMs),
    );
  }

  factory VerificationLogRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VerificationLogRow(
      id: serializer.fromJson<int>(json['id']),
      userId: serializer.fromJson<String?>(json['userId']),
      at: serializer.fromJson<DateTime>(json['at']),
      outcome: serializer.fromJson<String>(json['outcome']),
      failureReason: serializer.fromJson<String?>(json['failureReason']),
      bestSimilarity: serializer.fromJson<double?>(json['bestSimilarity']),
      latencyMs: serializer.fromJson<int>(json['latencyMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'userId': serializer.toJson<String?>(userId),
      'at': serializer.toJson<DateTime>(at),
      'outcome': serializer.toJson<String>(outcome),
      'failureReason': serializer.toJson<String?>(failureReason),
      'bestSimilarity': serializer.toJson<double?>(bestSimilarity),
      'latencyMs': serializer.toJson<int>(latencyMs),
    };
  }

  VerificationLogRow copyWith({
    int? id,
    Value<String?> userId = const Value.absent(),
    DateTime? at,
    String? outcome,
    Value<String?> failureReason = const Value.absent(),
    Value<double?> bestSimilarity = const Value.absent(),
    int? latencyMs,
  }) => VerificationLogRow(
    id: id ?? this.id,
    userId: userId.present ? userId.value : this.userId,
    at: at ?? this.at,
    outcome: outcome ?? this.outcome,
    failureReason: failureReason.present
        ? failureReason.value
        : this.failureReason,
    bestSimilarity: bestSimilarity.present
        ? bestSimilarity.value
        : this.bestSimilarity,
    latencyMs: latencyMs ?? this.latencyMs,
  );
  VerificationLogRow copyWithCompanion(VerificationLogsCompanion data) {
    return VerificationLogRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      at: data.at.present ? data.at.value : this.at,
      outcome: data.outcome.present ? data.outcome.value : this.outcome,
      failureReason: data.failureReason.present
          ? data.failureReason.value
          : this.failureReason,
      bestSimilarity: data.bestSimilarity.present
          ? data.bestSimilarity.value
          : this.bestSimilarity,
      latencyMs: data.latencyMs.present ? data.latencyMs.value : this.latencyMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VerificationLogRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('at: $at, ')
          ..write('outcome: $outcome, ')
          ..write('failureReason: $failureReason, ')
          ..write('bestSimilarity: $bestSimilarity, ')
          ..write('latencyMs: $latencyMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    at,
    outcome,
    failureReason,
    bestSimilarity,
    latencyMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VerificationLogRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.at == this.at &&
          other.outcome == this.outcome &&
          other.failureReason == this.failureReason &&
          other.bestSimilarity == this.bestSimilarity &&
          other.latencyMs == this.latencyMs);
}

class VerificationLogsCompanion extends UpdateCompanion<VerificationLogRow> {
  final Value<int> id;
  final Value<String?> userId;
  final Value<DateTime> at;
  final Value<String> outcome;
  final Value<String?> failureReason;
  final Value<double?> bestSimilarity;
  final Value<int> latencyMs;
  const VerificationLogsCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.at = const Value.absent(),
    this.outcome = const Value.absent(),
    this.failureReason = const Value.absent(),
    this.bestSimilarity = const Value.absent(),
    this.latencyMs = const Value.absent(),
  });
  VerificationLogsCompanion.insert({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    required DateTime at,
    required String outcome,
    this.failureReason = const Value.absent(),
    this.bestSimilarity = const Value.absent(),
    required int latencyMs,
  }) : at = Value(at),
       outcome = Value(outcome),
       latencyMs = Value(latencyMs);
  static Insertable<VerificationLogRow> custom({
    Expression<int>? id,
    Expression<String>? userId,
    Expression<DateTime>? at,
    Expression<String>? outcome,
    Expression<String>? failureReason,
    Expression<double>? bestSimilarity,
    Expression<int>? latencyMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (at != null) 'at': at,
      if (outcome != null) 'outcome': outcome,
      if (failureReason != null) 'failure_reason': failureReason,
      if (bestSimilarity != null) 'best_similarity': bestSimilarity,
      if (latencyMs != null) 'latency_ms': latencyMs,
    });
  }

  VerificationLogsCompanion copyWith({
    Value<int>? id,
    Value<String?>? userId,
    Value<DateTime>? at,
    Value<String>? outcome,
    Value<String?>? failureReason,
    Value<double?>? bestSimilarity,
    Value<int>? latencyMs,
  }) {
    return VerificationLogsCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      at: at ?? this.at,
      outcome: outcome ?? this.outcome,
      failureReason: failureReason ?? this.failureReason,
      bestSimilarity: bestSimilarity ?? this.bestSimilarity,
      latencyMs: latencyMs ?? this.latencyMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (at.present) {
      map['at'] = Variable<DateTime>(at.value);
    }
    if (outcome.present) {
      map['outcome'] = Variable<String>(outcome.value);
    }
    if (failureReason.present) {
      map['failure_reason'] = Variable<String>(failureReason.value);
    }
    if (bestSimilarity.present) {
      map['best_similarity'] = Variable<double>(bestSimilarity.value);
    }
    if (latencyMs.present) {
      map['latency_ms'] = Variable<int>(latencyMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VerificationLogsCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('at: $at, ')
          ..write('outcome: $outcome, ')
          ..write('failureReason: $failureReason, ')
          ..write('bestSimilarity: $bestSimilarity, ')
          ..write('latencyMs: $latencyMs')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $UsersTable users = $UsersTable(this);
  late final $VerificationLogsTable verificationLogs = $VerificationLogsTable(
    this,
  );
  late final UserDao userDao = UserDao(this as AppDatabase);
  late final VerificationLogDao verificationLogDao = VerificationLogDao(
    this as AppDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [users, verificationLogs];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'users',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('verification_logs', kind: UpdateKind.update)],
    ),
  ]);
}

typedef $$UsersTableCreateCompanionBuilder =
    UsersCompanion Function({
      required String userId,
      required String name,
      required Uint8List faceTemplates,
      Value<bool> isActive,
      Value<String?> imagePath,
      Value<DateTime?> enrolledAt,
      Value<DateTime?> lastVerifiedAt,
      Value<Uint8List?> templateMeta,
      Value<int> modelVersion,
      Value<int> rowid,
    });
typedef $$UsersTableUpdateCompanionBuilder =
    UsersCompanion Function({
      Value<String> userId,
      Value<String> name,
      Value<Uint8List> faceTemplates,
      Value<bool> isActive,
      Value<String?> imagePath,
      Value<DateTime?> enrolledAt,
      Value<DateTime?> lastVerifiedAt,
      Value<Uint8List?> templateMeta,
      Value<int> modelVersion,
      Value<int> rowid,
    });

final class $$UsersTableReferences
    extends BaseReferences<_$AppDatabase, $UsersTable, UserRow> {
  $$UsersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$VerificationLogsTable, List<VerificationLogRow>>
  _verificationLogsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.verificationLogs,
    aliasName: $_aliasNameGenerator(
      db.users.userId,
      db.verificationLogs.userId,
    ),
  );

  $$VerificationLogsTableProcessedTableManager get verificationLogsRefs {
    final manager =
        $$VerificationLogsTableTableManager($_db, $_db.verificationLogs).filter(
          (f) => f.userId.userId.sqlEquals($_itemColumn<String>('user_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _verificationLogsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$UsersTableFilterComposer extends Composer<_$AppDatabase, $UsersTable> {
  $$UsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get faceTemplates => $composableBuilder(
    column: $table.faceTemplates,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imagePath => $composableBuilder(
    column: $table.imagePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get enrolledAt => $composableBuilder(
    column: $table.enrolledAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastVerifiedAt => $composableBuilder(
    column: $table.lastVerifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get templateMeta => $composableBuilder(
    column: $table.templateMeta,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get modelVersion => $composableBuilder(
    column: $table.modelVersion,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> verificationLogsRefs(
    Expression<bool> Function($$VerificationLogsTableFilterComposer f) f,
  ) {
    final $$VerificationLogsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.userId,
      referencedTable: $db.verificationLogs,
      getReferencedColumn: (t) => t.userId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$VerificationLogsTableFilterComposer(
            $db: $db,
            $table: $db.verificationLogs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$UsersTableOrderingComposer
    extends Composer<_$AppDatabase, $UsersTable> {
  $$UsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get faceTemplates => $composableBuilder(
    column: $table.faceTemplates,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imagePath => $composableBuilder(
    column: $table.imagePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get enrolledAt => $composableBuilder(
    column: $table.enrolledAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastVerifiedAt => $composableBuilder(
    column: $table.lastVerifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get templateMeta => $composableBuilder(
    column: $table.templateMeta,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get modelVersion => $composableBuilder(
    column: $table.modelVersion,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UsersTableAnnotationComposer
    extends Composer<_$AppDatabase, $UsersTable> {
  $$UsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<Uint8List> get faceTemplates => $composableBuilder(
    column: $table.faceTemplates,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<String> get imagePath =>
      $composableBuilder(column: $table.imagePath, builder: (column) => column);

  GeneratedColumn<DateTime> get enrolledAt => $composableBuilder(
    column: $table.enrolledAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastVerifiedAt => $composableBuilder(
    column: $table.lastVerifiedAt,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get templateMeta => $composableBuilder(
    column: $table.templateMeta,
    builder: (column) => column,
  );

  GeneratedColumn<int> get modelVersion => $composableBuilder(
    column: $table.modelVersion,
    builder: (column) => column,
  );

  Expression<T> verificationLogsRefs<T extends Object>(
    Expression<T> Function($$VerificationLogsTableAnnotationComposer a) f,
  ) {
    final $$VerificationLogsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.userId,
      referencedTable: $db.verificationLogs,
      getReferencedColumn: (t) => t.userId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$VerificationLogsTableAnnotationComposer(
            $db: $db,
            $table: $db.verificationLogs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$UsersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $UsersTable,
          UserRow,
          $$UsersTableFilterComposer,
          $$UsersTableOrderingComposer,
          $$UsersTableAnnotationComposer,
          $$UsersTableCreateCompanionBuilder,
          $$UsersTableUpdateCompanionBuilder,
          (UserRow, $$UsersTableReferences),
          UserRow,
          PrefetchHooks Function({bool verificationLogsRefs})
        > {
  $$UsersTableTableManager(_$AppDatabase db, $UsersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<Uint8List> faceTemplates = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
                Value<String?> imagePath = const Value.absent(),
                Value<DateTime?> enrolledAt = const Value.absent(),
                Value<DateTime?> lastVerifiedAt = const Value.absent(),
                Value<Uint8List?> templateMeta = const Value.absent(),
                Value<int> modelVersion = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UsersCompanion(
                userId: userId,
                name: name,
                faceTemplates: faceTemplates,
                isActive: isActive,
                imagePath: imagePath,
                enrolledAt: enrolledAt,
                lastVerifiedAt: lastVerifiedAt,
                templateMeta: templateMeta,
                modelVersion: modelVersion,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required String name,
                required Uint8List faceTemplates,
                Value<bool> isActive = const Value.absent(),
                Value<String?> imagePath = const Value.absent(),
                Value<DateTime?> enrolledAt = const Value.absent(),
                Value<DateTime?> lastVerifiedAt = const Value.absent(),
                Value<Uint8List?> templateMeta = const Value.absent(),
                Value<int> modelVersion = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UsersCompanion.insert(
                userId: userId,
                name: name,
                faceTemplates: faceTemplates,
                isActive: isActive,
                imagePath: imagePath,
                enrolledAt: enrolledAt,
                lastVerifiedAt: lastVerifiedAt,
                templateMeta: templateMeta,
                modelVersion: modelVersion,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$UsersTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({verificationLogsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (verificationLogsRefs) db.verificationLogs,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (verificationLogsRefs)
                    await $_getPrefetchedData<
                      UserRow,
                      $UsersTable,
                      VerificationLogRow
                    >(
                      currentTable: table,
                      referencedTable: $$UsersTableReferences
                          ._verificationLogsRefsTable(db),
                      managerFromTypedResult: (p0) => $$UsersTableReferences(
                        db,
                        table,
                        p0,
                      ).verificationLogsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.userId == item.userId),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$UsersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $UsersTable,
      UserRow,
      $$UsersTableFilterComposer,
      $$UsersTableOrderingComposer,
      $$UsersTableAnnotationComposer,
      $$UsersTableCreateCompanionBuilder,
      $$UsersTableUpdateCompanionBuilder,
      (UserRow, $$UsersTableReferences),
      UserRow,
      PrefetchHooks Function({bool verificationLogsRefs})
    >;
typedef $$VerificationLogsTableCreateCompanionBuilder =
    VerificationLogsCompanion Function({
      Value<int> id,
      Value<String?> userId,
      required DateTime at,
      required String outcome,
      Value<String?> failureReason,
      Value<double?> bestSimilarity,
      required int latencyMs,
    });
typedef $$VerificationLogsTableUpdateCompanionBuilder =
    VerificationLogsCompanion Function({
      Value<int> id,
      Value<String?> userId,
      Value<DateTime> at,
      Value<String> outcome,
      Value<String?> failureReason,
      Value<double?> bestSimilarity,
      Value<int> latencyMs,
    });

final class $$VerificationLogsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $VerificationLogsTable,
          VerificationLogRow
        > {
  $$VerificationLogsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $UsersTable _userIdTable(_$AppDatabase db) => db.users.createAlias(
    $_aliasNameGenerator(db.verificationLogs.userId, db.users.userId),
  );

  $$UsersTableProcessedTableManager? get userId {
    final $_column = $_itemColumn<String>('user_id');
    if ($_column == null) return null;
    final manager = $$UsersTableTableManager(
      $_db,
      $_db.users,
    ).filter((f) => f.userId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_userIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$VerificationLogsTableFilterComposer
    extends Composer<_$AppDatabase, $VerificationLogsTable> {
  $$VerificationLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get at => $composableBuilder(
    column: $table.at,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get bestSimilarity => $composableBuilder(
    column: $table.bestSimilarity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get latencyMs => $composableBuilder(
    column: $table.latencyMs,
    builder: (column) => ColumnFilters(column),
  );

  $$UsersTableFilterComposer get userId {
    final $$UsersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.userId,
      referencedTable: $db.users,
      getReferencedColumn: (t) => t.userId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UsersTableFilterComposer(
            $db: $db,
            $table: $db.users,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$VerificationLogsTableOrderingComposer
    extends Composer<_$AppDatabase, $VerificationLogsTable> {
  $$VerificationLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get at => $composableBuilder(
    column: $table.at,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get bestSimilarity => $composableBuilder(
    column: $table.bestSimilarity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get latencyMs => $composableBuilder(
    column: $table.latencyMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$UsersTableOrderingComposer get userId {
    final $$UsersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.userId,
      referencedTable: $db.users,
      getReferencedColumn: (t) => t.userId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UsersTableOrderingComposer(
            $db: $db,
            $table: $db.users,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$VerificationLogsTableAnnotationComposer
    extends Composer<_$AppDatabase, $VerificationLogsTable> {
  $$VerificationLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get at =>
      $composableBuilder(column: $table.at, builder: (column) => column);

  GeneratedColumn<String> get outcome =>
      $composableBuilder(column: $table.outcome, builder: (column) => column);

  GeneratedColumn<String> get failureReason => $composableBuilder(
    column: $table.failureReason,
    builder: (column) => column,
  );

  GeneratedColumn<double> get bestSimilarity => $composableBuilder(
    column: $table.bestSimilarity,
    builder: (column) => column,
  );

  GeneratedColumn<int> get latencyMs =>
      $composableBuilder(column: $table.latencyMs, builder: (column) => column);

  $$UsersTableAnnotationComposer get userId {
    final $$UsersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.userId,
      referencedTable: $db.users,
      getReferencedColumn: (t) => t.userId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$UsersTableAnnotationComposer(
            $db: $db,
            $table: $db.users,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$VerificationLogsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $VerificationLogsTable,
          VerificationLogRow,
          $$VerificationLogsTableFilterComposer,
          $$VerificationLogsTableOrderingComposer,
          $$VerificationLogsTableAnnotationComposer,
          $$VerificationLogsTableCreateCompanionBuilder,
          $$VerificationLogsTableUpdateCompanionBuilder,
          (VerificationLogRow, $$VerificationLogsTableReferences),
          VerificationLogRow,
          PrefetchHooks Function({bool userId})
        > {
  $$VerificationLogsTableTableManager(
    _$AppDatabase db,
    $VerificationLogsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VerificationLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VerificationLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VerificationLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> userId = const Value.absent(),
                Value<DateTime> at = const Value.absent(),
                Value<String> outcome = const Value.absent(),
                Value<String?> failureReason = const Value.absent(),
                Value<double?> bestSimilarity = const Value.absent(),
                Value<int> latencyMs = const Value.absent(),
              }) => VerificationLogsCompanion(
                id: id,
                userId: userId,
                at: at,
                outcome: outcome,
                failureReason: failureReason,
                bestSimilarity: bestSimilarity,
                latencyMs: latencyMs,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> userId = const Value.absent(),
                required DateTime at,
                required String outcome,
                Value<String?> failureReason = const Value.absent(),
                Value<double?> bestSimilarity = const Value.absent(),
                required int latencyMs,
              }) => VerificationLogsCompanion.insert(
                id: id,
                userId: userId,
                at: at,
                outcome: outcome,
                failureReason: failureReason,
                bestSimilarity: bestSimilarity,
                latencyMs: latencyMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$VerificationLogsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({userId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (userId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.userId,
                                referencedTable:
                                    $$VerificationLogsTableReferences
                                        ._userIdTable(db),
                                referencedColumn:
                                    $$VerificationLogsTableReferences
                                        ._userIdTable(db)
                                        .userId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$VerificationLogsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $VerificationLogsTable,
      VerificationLogRow,
      $$VerificationLogsTableFilterComposer,
      $$VerificationLogsTableOrderingComposer,
      $$VerificationLogsTableAnnotationComposer,
      $$VerificationLogsTableCreateCompanionBuilder,
      $$VerificationLogsTableUpdateCompanionBuilder,
      (VerificationLogRow, $$VerificationLogsTableReferences),
      VerificationLogRow,
      PrefetchHooks Function({bool userId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db, _db.users);
  $$VerificationLogsTableTableManager get verificationLogs =>
      $$VerificationLogsTableTableManager(_db, _db.verificationLogs);
}
