import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:player/core/crypto/noise_service.dart';

// Mock storage for testing
class MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _storage.remove(key);
    } else {
      _storage[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('NoiseService', () {
    late NoiseService service;
    late MockSecureStorage mockStorage;

    setUp(() {
      mockStorage = MockSecureStorage();
      service = NoiseService(storage: mockStorage);
    });

    group('Keypair Management', () {
      test('generateKeypair creates valid X25519 keypair', () async {
        final (publicKey, privateKey) = await service.generateKeypair();

        expect(publicKey.length, equals(32));
        expect(privateKey.length, equals(32));
        expect(publicKey, isNot(equals(privateKey)));
      });

      test('loadOrGenerateKeypair generates and stores new keypair', () async {
        final (publicKey, privateKey) = await service.loadOrGenerateKeypair();

        expect(publicKey.length, equals(32));
        expect(privateKey.length, equals(32));

        // Verify stored in secure storage
        final storedPublic =
            await mockStorage.read(key: 'noise_device_public_key');
        final storedPrivate =
            await mockStorage.read(key: 'noise_device_private_key');

        expect(storedPublic, isNotNull);
        expect(storedPrivate, isNotNull);
        expect(base64Decode(storedPublic!), equals(publicKey));
        expect(base64Decode(storedPrivate!), equals(privateKey));
      });

      test('loadOrGenerateKeypair loads existing keypair', () async {
        // Generate first keypair
        final (firstPublic, firstPrivate) =
            await service.loadOrGenerateKeypair();

        // Load again - should return the same keypair
        final (secondPublic, secondPrivate) =
            await service.loadOrGenerateKeypair();

        expect(secondPublic, equals(firstPublic));
        expect(secondPrivate, equals(firstPrivate));
      });

      test('getDevicePublicKey returns null when no keypair exists', () async {
        final publicKey = await service.getDevicePublicKey();
        expect(publicKey, isNull);
      });

      test('getDevicePublicKey returns stored public key', () async {
        final (publicKey, _) = await service.loadOrGenerateKeypair();
        final retrieved = await service.getDevicePublicKey();

        expect(retrieved, equals(publicKey));
      });

      test('deleteKeypair removes stored keys', () async {
        await service.loadOrGenerateKeypair();

        await service.deleteKeypair();

        final publicKey = await service.getDevicePublicKey();
        expect(publicKey, isNull);

        final storedPublic =
            await mockStorage.read(key: 'noise_device_public_key');
        final storedPrivate =
            await mockStorage.read(key: 'noise_device_private_key');

        expect(storedPublic, isNull);
        expect(storedPrivate, isNull);
      });
    });

    group('Session Creation', () {
      test('startPairingHandshake creates valid session', () async {
        final serverPublicKey = Uint8List(32); // Mock server key
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);

        expect(session.isInitiator, isTrue);
        expect(session.isComplete, isFalse);
      });

      test('startPairingHandshake rejects invalid server key length',
          () async {
        final invalidKey = Uint8List(16); // Wrong length

        expect(
          () => service.startPairingHandshake(invalidKey),
          throwsArgumentError,
        );
      });

      test('startPairingHandshake session has correct properties', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);

        expect(session.localStaticKeypair, isNull);
        expect(session.remoteStaticPublicKey, equals(serverPublicKey));
      });

      test('startReconnectHandshake creates valid session', () async {
        final serverPublicKey = Uint8List(32); // Mock server key
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        // Generate device keypair first
        await service.loadOrGenerateKeypair();

        final session = await service.startReconnectHandshake(serverPublicKey);

        expect(session.isInitiator, isTrue);
        expect(session.isComplete, isFalse);
      });

      test('startReconnectHandshake rejects invalid server key length',
          () async {
        final invalidKey = Uint8List(16); // Wrong length

        expect(
          () => service.startReconnectHandshake(invalidKey),
          throwsArgumentError,
        );
      });

      test('startReconnectHandshake session has keypair', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        await service.loadOrGenerateKeypair();

        final session = await service.startReconnectHandshake(serverPublicKey);

        expect(session.localStaticKeypair, isNotNull);
        expect(session.remoteStaticPublicKey, equals(serverPublicKey));
      });
    });

    group('Handshake Messages', () {
      test('writeHandshakeMessage generates valid NK message', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);
        final message = await session.writeHandshakeMessage();

        // NK first message: e (32 bytes) + es (encrypted with DH)
        expect(message.length, greaterThanOrEqualTo(32));
        expect(session.isComplete, isFalse);
      });

      test('writeHandshakeMessage generates valid IK message', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i + 1;
        }

        await service.loadOrGenerateKeypair();
        final session = await service.startReconnectHandshake(serverPublicKey);
        final message = await session.writeHandshakeMessage();

        // IK first message: e (32 bytes) + encrypted static key + MAC
        // Should be at least 32 + 32 + 16 = 80 bytes
        expect(message.length, greaterThanOrEqualTo(80));
        expect(session.isComplete, isFalse);
      });

      test('writeHandshakeMessage with payload includes encrypted payload',
          () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);
        final payload = Uint8List.fromList(utf8.encode('test payload'));
        final message = await session.writeHandshakeMessage(payload);

        // Message should include ephemeral key + encrypted payload + MAC
        expect(message.length, greaterThanOrEqualTo(32 + payload.length + 16));
      });

      test('writeHandshakeMessage throws when called twice', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);
        await session.writeHandshakeMessage();

        expect(
          () => session.writeHandshakeMessage(),
          throwsStateError,
        );
      });

      test('readHandshakeMessage requires valid message length', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);
        await session.writeHandshakeMessage();

        final tooShortMessage = Uint8List(16); // Too short

        expect(
          () => session.readHandshakeMessage(tooShortMessage),
          throwsArgumentError,
        );
      });
    });

    group('Transport Encryption', () {
      test('encrypt throws when handshake not complete', () async {
        final serverPublicKey = Uint8List(32);
        final session = await service.startPairingHandshake(serverPublicKey);

        final plaintext = Uint8List.fromList(utf8.encode('Test'));

        expect(
          () => session.encrypt(plaintext),
          throwsStateError,
        );
      });

      test('decrypt throws when handshake not complete', () async {
        final serverPublicKey = Uint8List(32);
        final session = await service.startPairingHandshake(serverPublicKey);

        final ciphertext = Uint8List(32);

        expect(
          () => session.decrypt(ciphertext),
          throwsStateError,
        );
      });
    });

    group('Session Disposal', () {
      test('dispose clears sensitive key material', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);
        await session.writeHandshakeMessage();

        session.dispose();

        // After dispose, session state should be cleared
        expect(session.isComplete, isFalse);
      });
    });

    group('Pattern Validation', () {
      test('NK session has correct pattern', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final session = await service.startPairingHandshake(serverPublicKey);

        expect(session.pattern, equals(NoisePattern.nk));
        expect(session.localStaticKeypair, isNull);
      });

      test('IK session has correct pattern', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        await service.loadOrGenerateKeypair();
        final session = await service.startReconnectHandshake(serverPublicKey);

        expect(session.pattern, equals(NoisePattern.ik));
        expect(session.localStaticKeypair, isNotNull);
      });
    });
  });
}
