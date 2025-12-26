/// Native implementation using flutter_secure_storage.
///
/// This provides secure storage on iOS, Android, macOS, Windows, and Linux.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_storage.dart';

AuthStorage getAuthStorage() => _NativeAuthStorage();

class _NativeAuthStorage implements AuthStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  @override
  Future<String?> read(String key) async {
    return await _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  @override
  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }
}
