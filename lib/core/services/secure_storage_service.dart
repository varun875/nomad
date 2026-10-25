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
  static Future<List<int>>? _inFlightKeyFuture;
  static final Map<String, Future<Box>> _inFlightBoxes = {};

  /// Returns the persistent 32-byte AES key from the platform keychain,
  /// generating and storing one on first launch.
  ///
  /// Concurrent callers share the same in-flight Future to prevent redundant
  /// platform-channel round trips before the key is cached.
  static Future<List<int>> _getOrCreateKey() {
    if (_cachedKey != null) return Future.value(_cachedKey!);
    return _inFlightKeyFuture ??= _readOrCreateKeyInternal();
  }

  static Future<List<int>> _readOrCreateKeyInternal() async {
    try {
      final existing = await _storage.read(key: _keyName);
      if (existing != null && existing.isNotEmpty) {
        _cachedKey = base64Decode(existing);
        return _cachedKey!;
      }
      final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      await _storage.write(key: _keyName, value: base64Encode(key));
      _cachedKey = key;
      return key;
    } finally {
      _inFlightKeyFuture = null;
    }
  }

  static Future<HiveAesCipher> hiveCipher() async {
    final key = await _getOrCreateKey();
    return HiveAesCipher(key);
  }

  /// Opens [name] with AES encryption, or throws
  /// [EncryptionUnavailableException] if the cipher or box cannot be opened.
  /// Never opens the box unencrypted. Concurrent requests for the same box share
  /// a single in-flight operation.
  static Future<Box> openEncryptedBox(String name) async {
    if (Hive.isBoxOpen(name)) return Hive.box(name);
    final inFlight = _inFlightBoxes[name];
    if (inFlight != null) return inFlight;

    final future = _openEncryptedBoxInternal(name);
    _inFlightBoxes[name] = future;
    try {
      return await future;
    } finally {
      _inFlightBoxes.remove(name);
    }
  }

  static Future<Box> _openEncryptedBoxInternal(String name) async {
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
