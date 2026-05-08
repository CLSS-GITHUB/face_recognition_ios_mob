import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// AES-GCM envelope encryption for face-template blobs.
///
/// The 256-bit data-encryption-key (DEK) is generated on first launch and
/// stored in platform secure storage (Android: EncryptedSharedPreferences
/// backed by Keystore; iOS: Keychain). The encrypted blob layout is:
///
///   [12-byte IV][ciphertext][16-byte GCM tag]
///
/// Callers should pass `FaceTemplatesCodec.encode(...)` bytes as plaintext.
class TemplateCrypto {
  TemplateCrypto({
    FlutterSecureStorage? storage,
    AesGcm? algorithm,
  })  : _storage = storage ?? const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        ),
        _aes = algorithm ?? AesGcm.with256bits();

  static const _dekKey = 'template_dek_v1';
  static const int _ivLength = 12;

  final FlutterSecureStorage _storage;
  final AesGcm _aes;

  SecretKey? _cachedKey;

  Future<SecretKey> _key() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final existing = await _storage.read(key: _dekKey);
    if (existing != null) {
      final bytes = base64Decode(existing);
      final key = SecretKey(bytes);
      _cachedKey = key;
      return key;
    }
    final key = await _aes.newSecretKey();
    final bytes = await key.extractBytes();
    await _storage.write(key: _dekKey, value: base64Encode(bytes));
    _cachedKey = key;
    return key;
  }

  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final key = await _key();
    final box = await _aes.encrypt(plaintext, secretKey: key);
    final out = BytesBuilder(copy: false)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  Future<Uint8List> decrypt(Uint8List blob) async {
    if (blob.length < _ivLength + 16) {
      throw const FormatException('Encrypted blob too short');
    }
    final iv = blob.sublist(0, _ivLength);
    final tag = blob.sublist(blob.length - 16);
    final ct = blob.sublist(_ivLength, blob.length - 16);
    final key = await _key();
    final box = SecretBox(ct, nonce: iv, mac: Mac(tag));
    final plain = await _aes.decrypt(box, secretKey: key);
    return Uint8List.fromList(plain);
  }
}
