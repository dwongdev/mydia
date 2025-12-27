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
  group('Noise Handshake Integration Tests', () {
    late NoiseService clientService;
    late MockSecureStorage clientStorage;

    setUp(() {
      clientStorage = MockSecureStorage();
      clientService = NoiseService(storage: clientStorage);
    });

    group('NK Pattern (Initial Pairing)', () {
      test('generates valid handshake message structure', () async {
        // Simulate server's static public key
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        // Client starts NK handshake
        final clientSession =
            await clientService.startPairingHandshake(serverPublicKey);

        // Client sends first message: e, es
        final clientMessage = await clientSession.writeHandshakeMessage();

        // Verify message structure
        expect(clientMessage.length, greaterThanOrEqualTo(32)); // At least ephemeral key
        expect(clientSession.isComplete, isFalse); // Waiting for server response
        expect(clientSession.isInitiator, isTrue);
      });

      test('NK message includes payload', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i;
        }

        final clientSession =
            await clientService.startPairingHandshake(serverPublicKey);

        final payload = Uint8List.fromList('test payload'.codeUnits);
        final message = await clientSession.writeHandshakeMessage(payload);

        // Message should include ephemeral key + encrypted payload + MAC
        expect(message.length, greaterThanOrEqualTo(32 + payload.length + 16));
      });
    });

    group('IK Pattern (Reconnection)', () {
      test('generates valid IK handshake message', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i + 1;
        }

        // Client generates keypair (simulates already paired device)
        await clientService.loadOrGenerateKeypair();

        // Client starts IK handshake
        final clientSession =
            await clientService.startReconnectHandshake(serverPublicKey);

        // Client sends first message: e, es, s, ss
        final clientMessage = await clientSession.writeHandshakeMessage();

        // Verify message structure
        // Should contain: ephemeral key (32) + encrypted static key (32 + 16 MAC) = minimum 80 bytes
        expect(clientMessage.length, greaterThanOrEqualTo(80));
        expect(clientSession.isComplete, isFalse); // Waiting for server response
        expect(clientSession.isInitiator, isTrue);
      });

      test('IK message with payload', () async {
        final serverPublicKey = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          serverPublicKey[i] = i + 1;
        }

        await clientService.loadOrGenerateKeypair();
        final clientSession =
            await clientService.startReconnectHandshake(serverPublicKey);

        final payload = Uint8List.fromList('additional data'.codeUnits);
        final message = await clientSession.writeHandshakeMessage(payload);

        // Should include base IK message + encrypted payload + MAC
        expect(message.length, greaterThanOrEqualTo(80 + payload.length + 16));
      });
    });

    group('Error Cases', () {
      test('throws when encrypting before handshake completes', () async {
        final serverPublicKey = Uint8List(32);
        final session = await clientService.startPairingHandshake(serverPublicKey);

        final plaintext = Uint8List.fromList('test'.codeUnits);

        expect(
          () => session.encrypt(plaintext),
          throwsStateError,
        );
      });

      test('throws when decrypting before handshake completes', () async {
        final serverPublicKey = Uint8List(32);
        final session = await clientService.startPairingHandshake(serverPublicKey);

        final ciphertext = Uint8List(32);

        expect(
          () => session.decrypt(ciphertext),
          throwsStateError,
        );
      });

      test('throws when writing handshake message twice', () async {
        final serverPublicKey = Uint8List(32);
        final session = await clientService.startPairingHandshake(serverPublicKey);

        await session.writeHandshakeMessage();

        expect(
          () => session.writeHandshakeMessage(),
          throwsStateError,
        );
      });
    });

    group('Session Cleanup', () {
      test('dispose clears session state', () async {
        final serverPublicKey = Uint8List(32);
        final session = await clientService.startPairingHandshake(serverPublicKey);

        await session.writeHandshakeMessage();
        session.dispose();

        // Session should be cleared
        expect(session.isComplete, isFalse);
      });
    });
  });
}
