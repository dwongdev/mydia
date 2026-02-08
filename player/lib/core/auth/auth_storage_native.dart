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

  static final Map<String, String> _memoryStorage = <String, String>{};
  static bool _fallbackToMemory = false;

  Future<T> _withFallback<T>(Future<T> Function() operation, T Function() onFallback) async {
    if (_fallbackToMemory) {
      return onFallback();
    }

    try {
      return await operation();
    } catch (_) {
      _fallbackToMemory = true;
      return onFallback();
    }
  }

  @override
  Future<String?> read(String key) async {
    return _withFallback<String?>(
      () => _storage.read(key: key),
      () => _memoryStorage[key],
    );
  }

  @override
  Future<void> write(String key, String value) async {
    await _withFallback<void>(
      () => _storage.write(key: key, value: value),
      () {
        _memoryStorage[key] = value;
      },
    );
  }

  @override
  Future<void> delete(String key) async {
    await _withFallback<void>(
      () => _storage.delete(key: key),
      () {
        _memoryStorage.remove(key);
      },
    );
  }

  @override
  Future<void> deleteAll() async {
    await _withFallback<void>(
      _storage.deleteAll,
      () {
        _memoryStorage.clear();
      },
    );
  }
}
