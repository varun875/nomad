import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Thrown when an encrypted Hive box cannot be opened because the encryption
/// key is unavailable. We refuse to fall back to an unencrypted box so data
/// believed to be encrypted at rest never silently goes to disk in plaintext.
class EncryptionUnavailableException implements Exception {
  EncryptionUnavailableException(this.boxName, this.cause);

  final String boxName;
  final Object cause;

  @override
  String toString() =>
      'Refusing to open "$boxName" without encryption: $cause';
}

class SecureStorageService {
  static const _keyName = 'nomad_hive_key';
  static const _storage = FlutterSecureStorage();

  static List<int>? _cachedKey;

  /// Returns the persistent 32-byte AES key from the platform keychain,
  /// generating and storing one on first launch.
  ///
  /// Unlike before, keychain read/write failures are no longer swallowed: a
  /// failed write would otherwise generate a throwaway key on every launch,
  /// making existing boxes unreadable.
  static Future<List<int>> _getOrCreateKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final existing = await _storage.read(key: _keyName);
    if (existing != null && existing.isNotEmpty) {
      _cachedKey = base64Decode(existing);
      return _cachedKey!;
    }
    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await _storage.write(key: _keyName, value: base64Encode(key));
    _cachedKey = key;
    return key;
  }

  static Future<HiveAesCipher> hiveCipher() async {
    final key = await _getOrCreateKey();
    return HiveAesCipher(key);
  }

  /// Opens [name] with AES encryption, or throws
  /// [EncryptionUnavailableException] if the cipher or box cannot be opened.
  /// Never opens the box unencrypted.
  static Future<Box> openEncryptedBox(String name) async {
    if (Hive.isBoxOpen(name)) return Hive.box(name);
    final HiveAesCipher cipher;
    try {
      cipher = await hiveCipher();
    } catch (e) {
      throw EncryptionUnavailableException(name, e);
    }
    try {
      return await Hive.openBox(name, encryptionCipher: cipher);
    } catch (e) {
      throw EncryptionUnavailableException(name, e);
    }
  }

  static Future<Box> openBox(String name, {bool encrypted = false}) async {
    if (encrypted) return openEncryptedBox(name);
    if (Hive.isBoxOpen(name)) return Hive.box(name);
    return Hive.openBox(name);
  }
}
