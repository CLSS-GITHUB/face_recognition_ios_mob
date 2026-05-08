# 10 — Security & Encryption

## 10.1 Threat model recap

The product stores a **biometric template** (192 floats) per enrollment. Under most data-protection regimes (GDPR, India DPDP, CCPA's CCRA expansion), face templates are **special-category personal data** and require:

- Storage encryption at rest.
- Access control (no other app should be able to read it).
- Reversibility-resistance (the embedding should not be reconstructable into a face image).
- A clear deletion path tied to user request.

Plus the operational concerns the Android app already handles: refuse to run on rooted/emulator devices.

## 10.2 Gaps in the Android baseline

Identified during source review:

| Gap | Where | Severity |
|---|---|---|
| Templates stored unencrypted in SQLite | `Converters.kt` writes raw `ByteBuffer` into the BLOB column | **High** |
| `imagePath` JPEG of the user's face stored unencrypted on disk | `BitmapUtils.saveBitmapToInternalStorage` | **High** |
| `android.util.Log.d/i` lines include user names + similarity scores | `EnrollmentScreen.kt`, `VerificationScreen.kt` | Medium (log scrape on non-root devices) |
| Root/emulator detection limited to ~14 properties | `SecurityUtils.kt` | Medium (bypassable by Magisk + Build prop spoofing) |
| No rate limiting on verification attempts | `VerificationScreen.kt` | Medium |
| No account lockout after N failures | n/a | Medium |
| No anti-spoofing beyond active liveness (no texture / depth analysis) | `LivenessDetector.kt` | Medium |
| No audit trail of enrollment/verification attempts | n/a | Low |
| `INTERNET` permission declared but unused (attack surface) | `AndroidManifest.xml` | Low |
| `fallbackToDestructiveMigration` wipes templates silently on schema change | `AppDatabase.kt` | Low |
| `allowBackup="true"` in manifest may copy DB to cloud backup | `AndroidManifest.xml` | Medium |

The Flutter port should close the **High** items and most **Medium** items.

## 10.3 Encryption strategy

### 10.3.1 Per-template envelope encryption

Generate a 256-bit data-encryption-key (DEK) on first launch, store it in:

- **iOS:** Keychain (`flutter_secure_storage` with `IOSOptions.first.copyWith(accessibility: KeychainAccessibility.first_unlock_this_device)`).
- **Android:** Keystore-backed `EncryptedSharedPreferences` (also via `flutter_secure_storage`).

Encrypt every template before it goes into the BLOB:

```dart
class EncryptedTemplatesConverter extends TypeConverter<List<Float32List>, Uint8List> {
  EncryptedTemplatesConverter(this._key);
  final SecretKey _key;

  @override
  Uint8List toSql(List<Float32List> value) {
    final raw = FaceTemplatesConverter().toSql(value);  // existing byte layout
    final iv = SecureRandom(12).bytes;                   // GCM 96-bit IV
    final ciphertext = AesGcm.encrypt(raw, _key, iv);
    return Uint8List.fromList([...iv, ...ciphertext]);  // [IV][ct][tag]
  }

  @override
  List<Float32List> fromSql(Uint8List blob) {
    final iv = blob.sublist(0, 12);
    final ct = blob.sublist(12);
    final raw = AesGcm.decrypt(ct, _key, iv);
    return FaceTemplatesConverter().fromSql(raw);
  }
}
```

Use `package:cryptography` (Dart-native AES-GCM, 100 % cross-platform, no FFI required).

This is **better** than wrapping the whole DB in SQLCipher because:

- Smaller blast radius: a corrupted blob breaks one user, not the DB.
- Easier key rotation (re-encrypt rows incrementally).
- No native dependency on `sqlcipher_flutter_libs`, which complicates iOS builds.

### 10.3.2 Image file encryption

Two options:

| Option | Pros | Cons |
|---|---|---|
| Encrypt JPEG bytes the same way as templates | Consistent with template encryption; symmetric cleanup | Decrypt cost on every list render in `UserManagementScreen` |
| Skip storing the face image at all | Eliminates the biggest privacy risk; UI shows initials/avatar | Loses visual confirmation of who's enrolled |

Recommendation: **default to skipping the image storage**. The Android source uses it only for `UserCard` thumbnails — replace with initial-letter avatar circles. If the customer requires real photos, encrypt with the same DEK used for templates.

## 10.4 Permissions

| Permission | Manifest entry | Flutter equivalent |
|---|---|---|
| Camera | `android.permission.CAMERA` | iOS `NSCameraUsageDescription`; Android auto-merged from `camera` plugin; runtime via `permission_handler` |
| INTERNET | declared, **unused** | Drop. Plugins that need it (e.g., crash reporting) will re-add. |
| READ_EXTERNAL_STORAGE / READ_MEDIA_IMAGES | declared for gallery | Drop unless `image_picker` is reintroduced; then `Permission.photos` |

iOS strings (`ios/Runner/Info.plist`):

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to perform face verification.</string>
```

## 10.5 Root / emulator detection

`SecurityUtils.kt` checks ~9 su paths and ~14 Build properties. The closest Flutter equivalent is `safe_device`. Augment as follows:

```dart
Future<SecurityStatus> currentStatus() async {
  final isJailBroken = await SafeDevice.isJailBroken;
  final isRealDevice = await SafeDevice.isRealDevice;
  // SafeDevice.isOnExternalStorage: catches some emulator side-loads
  return SecurityStatus(rooted: isJailBroken, emulator: !isRealDevice);
}
```

Both checks are heuristics, not guarantees. For high-assurance deployments add **Play Integrity API** (Android) and **DeviceCheck / App Attest** (iOS) — both have Flutter wrappers. Out of scope for v1; document as a future hardening step.

## 10.6 Logging discipline

Replace direct `android.util.Log` lines that leak identity:

```kotlin
android.util.Log.i("Verification", "✓ MATCH FOUND: ${bestMatch.name} (Similarity: $highestSimilarity)")
```

…with structured, redacted logs:

```dart
_log.info('match_found', {'similarity': sim.toStringAsFixed(3)});
// User name omitted entirely.
```

Set `Logger.root.level = Level.WARNING` in release. Never log embeddings or full templates.

## 10.7 Backup posture

The Android `AndroidManifest.xml` declares `android:allowBackup="true"`. This causes Auto Backup to copy `/data/data/<pkg>/files/` and the DB to Google Drive on user opt-in — including face templates and JPEGs. Two responses for the Flutter port:

- **Android:** in `android/app/src/main/AndroidManifest.xml`, set `android:allowBackup="false"` and `android:fullBackupContent="@xml/backup_rules"` with explicit excludes for `databases/` and `app_flutter/user_faces/`.
- **iOS:** mark the templates database with `NSURLIsExcludedFromBackupKey` (use `path_provider` + a small platform channel, or set `getApplicationSupportDirectory()` paths which iCloud Backup excludes by default for some subpaths — confirm with `getApplicationSupportDirectory()` semantics on the target iOS version).

## 10.8 Verification rate limiting (recommended addition)

Add a simple counter per user (or device) using `flutter_secure_storage`:

```
attempt_count : int
last_attempt_ts : int
```

Reject verification attempts when `attempt_count >= 5` within `last_attempt_ts + 60 s`. Reset on successful verification.

## 10.9 Anti-spoofing roadmap

Active liveness (blink, head turns, mouth open) defeats printed photos and most replays but **not** high-quality video replays or 3D-printed masks. For higher assurance:

1. **Texture-based passive liveness** — train a small classifier on RGB face crops to flag screen reflections (~moiré patterns). Possible Flutter package: ship the model alongside MobileFaceNet.
2. **3D depth via TrueDepth (iOS) / Camera2 depth API (Android flagship)** — out of scope for v1; design `FaceRecognitionService` to accept an optional `DepthMap` parameter so it's additive later.

Document but do not implement in Phase 1.

## 10.10 Compliance posture (informational)

- Provide a clear **delete-my-data** path: the existing `UserManagementScreen` already supports deletion. Ensure it deletes the encrypted blob *and* the JPEG file (the Android implementation does this).
- Provide a **purpose-of-processing** notice on the `PermissionScreen` ("This app uses your camera to verify your identity. Your face template is stored only on this device.").
- Consider an **export / portability** path only if a B2B customer requires it; encrypt the export.
- Keep this document updated as the threat model evolves.
