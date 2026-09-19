import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

class SecureStorageService {
  static const _keyName = 'nomad_hive_key';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static List<int>? _cachedKey;

  static Future<List<int>> _getOrCreateKey() async {
    if (_cachedKey != null) return _cachedKey!;
    try {
      final existing = await _storage.read(key: _keyName);
      if (existing != null && existing.isNotEmpty) {
        _cachedKey = base64Decode(existing);
        return _cachedKey!;
      }
    } catch (_) {}
    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    try {
      await _storage.write(key: _keyName, value: base64Encode(key));
    } catch (_) {}
    _cachedKey = key;
    return key;
  }

  static Future<HiveAesCipher> hiveCipher() async {
    final key = await _getOrCreateKey();
    return HiveAesCipher(key);
  }

  static Future<Box> openEncryptedBox(String name) async {
    if (Hive.isBoxOpen(name)) return Hive.box(name);
    try {
      final cipher = await hiveCipher();
      return await Hive.openBox(name, encryptionCipher: cipher);
    } catch (_) {
      return await Hive.openBox(name);
    }
  }

  static Future<Box> openBox(String name, {bool encrypted = false}) async {
    if (encrypted) return openEncryptedBox(name);
    if (Hive.isBoxOpen(name)) return Hive.box(name);
    return Hive.openBox(name);
  }
}
