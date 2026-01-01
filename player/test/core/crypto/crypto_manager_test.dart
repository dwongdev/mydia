import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crypto/crypto_manager.dart';

void main() {
  group('CryptoManager', () {
    group('Key Pair Generation', () {
      test('generateKeyPair returns valid base64-encoded public key', () async {
        final crypto = CryptoManager();

        final publicKeyBase64 = await crypto.generateKeyPair();

        // Should be valid base64
        final publicKeyBytes = base64Decode(publicKeyBase64);

        // X25519 public key is 32 bytes
        expect(publicKeyBytes.length, equals(32));
      });

      test('generateKeyPair sets hasKeyPair to true', () async {
        final crypto = CryptoManager();

        expect(crypto.hasKeyPair, isFalse);

        await crypto.generateKeyPair();

        expect(crypto.hasKeyPair, isTrue);
      });

      test('generateKeyPair generates different keys each time', () async {
        final crypto1 = CryptoManager();
        final crypto2 = CryptoManager();

        final publicKey1 = await crypto1.generateKeyPair();
        final publicKey2 = await crypto2.generateKeyPair();

        expect(publicKey1, isNot(equals(publicKey2)));
      });

      test('calling generateKeyPair multiple times replaces the key pair',
          () async {
        final crypto = CryptoManager();

        final publicKey1 = await crypto.generateKeyPair();
        final publicKey2 = await crypto.generateKeyPair();

        // Keys should be different
        expect(publicKey1, isNot(equals(publicKey2)));
        expect(crypto.hasKeyPair, isTrue);
      });
    });

    group('Session Key Derivation', () {
      test('deriveSessionKey succeeds with valid server public key', () async {
        final clientCrypto = CryptoManager();
        await clientCrypto.generateKeyPair();

        // Generate a valid X25519 public key for the "server"
        final serverX25519 = X25519();
        final serverKeyPair = await serverX25519.newKeyPair();
        final serverPublicKey = await serverKeyPair.extractPublicKey();
        final serverPublicKeyBase64 = base64Encode(serverPublicKey.bytes);

        await clientCrypto.deriveSessionKey(serverPublicKeyBase64);

        expect(clientCrypto.hasSessionKey, isTrue);
      });

      test('deriveSessionKey throws StateError without key pair', () async {
        final crypto = CryptoManager();

        final serverX25519 = X25519();
        final serverKeyPair = await serverX25519.newKeyPair();
        final serverPublicKey = await serverKeyPair.extractPublicKey();
        final serverPublicKeyBase64 = base64Encode(serverPublicKey.bytes);

        expect(
          () => crypto.deriveSessionKey(serverPublicKeyBase64),
          throwsStateError,
        );
      });

      test('deriveSessionKey throws ArgumentError for invalid key length',
          () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        // Invalid key length (not 32 bytes)
        final invalidKeyBase64 = base64Encode(List.filled(16, 0));

        expect(
          () => crypto.deriveSessionKey(invalidKeyBase64),
          throwsArgumentError,
        );
      });

      test('deriveSessionKey throws FormatException for invalid base64',
          () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        expect(
          () => crypto.deriveSessionKey('not-valid-base64!!!'),
          throwsFormatException,
        );
      });

      test('deriveSessionKey sets hasSessionKey to true', () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        expect(crypto.hasSessionKey, isFalse);

        final serverX25519 = X25519();
        final serverKeyPair = await serverX25519.newKeyPair();
        final serverPublicKey = await serverKeyPair.extractPublicKey();
        final serverPublicKeyBase64 = base64Encode(serverPublicKey.bytes);

        await crypto.deriveSessionKey(serverPublicKeyBase64);

        expect(crypto.hasSessionKey, isTrue);
      });
    });

    group('Encrypt/Decrypt Round Trip', () {
      late CryptoManager clientCrypto;
      late CryptoManager serverCrypto;

      setUp(() async {
        clientCrypto = CryptoManager();
        serverCrypto = CryptoManager();

        // Generate key pairs for both parties
        final clientPublicKey = await clientCrypto.generateKeyPair();
        final serverPublicKey = await serverCrypto.generateKeyPair();

        // Derive session keys (each side uses the other's public key)
        await clientCrypto.deriveSessionKey(serverPublicKey);
        await serverCrypto.deriveSessionKey(clientPublicKey);
      });

      test('encrypt returns map with ciphertext, nonce, and mac', () async {
        const plaintext = 'Hello, World!';

        final encrypted = await clientCrypto.encrypt(plaintext);

        expect(encrypted, containsPair('ciphertext', isA<String>()));
        expect(encrypted, containsPair('nonce', isA<String>()));
        expect(encrypted, containsPair('mac', isA<String>()));

        // All values should be valid base64
        expect(() => base64Decode(encrypted['ciphertext']!), returnsNormally);
        expect(() => base64Decode(encrypted['nonce']!), returnsNormally);
        expect(() => base64Decode(encrypted['mac']!), returnsNormally);
      });

      test('encrypt/decrypt round trip with short message', () async {
        const plaintext = 'Hello, World!';

        final encrypted = await clientCrypto.encrypt(plaintext);
        final decrypted = await clientCrypto.decrypt(
          encrypted['ciphertext']!,
          encrypted['nonce']!,
          encrypted['mac']!,
        );

        expect(decrypted, equals(plaintext));
      });

      test('encrypt/decrypt round trip with empty message', () async {
        const plaintext = '';

        final encrypted = await clientCrypto.encrypt(plaintext);
        final decrypted = await clientCrypto.decrypt(
          encrypted['ciphertext']!,
          encrypted['nonce']!,
          encrypted['mac']!,
        );

        expect(decrypted, equals(plaintext));
      });

      test('encrypt/decrypt round trip with long message', () async {
        final plaintext = 'A' * 10000;

        final encrypted = await clientCrypto.encrypt(plaintext);
        final decrypted = await clientCrypto.decrypt(
          encrypted['ciphertext']!,
          encrypted['nonce']!,
          encrypted['mac']!,
        );

        expect(decrypted, equals(plaintext));
      });

      test('encrypt/decrypt round trip with unicode characters', () async {
        const plaintext = 'Hello, World! 世界 🌍 Привет мир';

        final encrypted = await clientCrypto.encrypt(plaintext);
        final decrypted = await clientCrypto.decrypt(
          encrypted['ciphertext']!,
          encrypted['nonce']!,
          encrypted['mac']!,
        );

        expect(decrypted, equals(plaintext));
      });

      test('encrypt produces different ciphertext for same plaintext',
          () async {
        const plaintext = 'Test message';

        final encrypted1 = await clientCrypto.encrypt(plaintext);
        final encrypted2 = await clientCrypto.encrypt(plaintext);

        // Ciphertext should be different (random nonce)
        expect(encrypted1['ciphertext'], isNot(equals(encrypted2['ciphertext'])));
        // Nonce should be different
        expect(encrypted1['nonce'], isNot(equals(encrypted2['nonce'])));
      });
    });

    group('Decryption Failure with Wrong Key', () {
      test('decrypt fails with different session key', () async {
        // Set up first crypto instance
        final crypto1 = CryptoManager();
        await crypto1.generateKeyPair();

        // Set up second crypto instance with different key pair
        final crypto2 = CryptoManager();
        await crypto2.generateKeyPair();

        // Set up third party to derive keys
        final serverCrypto = CryptoManager();
        final serverPublicKey = await serverCrypto.generateKeyPair();

        // Both derive session keys with server
        await crypto1.deriveSessionKey(serverPublicKey);

        // crypto2 derives with a different server public key
        final otherServer = CryptoManager();
        final otherServerPublicKey = await otherServer.generateKeyPair();
        await crypto2.deriveSessionKey(otherServerPublicKey);

        // Encrypt with crypto1
        const plaintext = 'Secret message';
        final encrypted = await crypto1.encrypt(plaintext);

        // Try to decrypt with crypto2 (different session key)
        expect(
          () => crypto2.decrypt(
            encrypted['ciphertext']!,
            encrypted['nonce']!,
            encrypted['mac']!,
          ),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      });
    });

    group('Decryption Failure with Tampered Ciphertext', () {
      late CryptoManager crypto;

      setUp(() async {
        crypto = CryptoManager();
        await crypto.generateKeyPair();

        final serverCrypto = CryptoManager();
        final serverPublicKey = await serverCrypto.generateKeyPair();
        await crypto.deriveSessionKey(serverPublicKey);
      });

      test('decrypt fails with tampered ciphertext', () async {
        const plaintext = 'Secret message';
        final encrypted = await crypto.encrypt(plaintext);

        // Tamper with ciphertext
        final ciphertextBytes = base64Decode(encrypted['ciphertext']!);
        ciphertextBytes[0] ^= 0xFF; // Flip bits in first byte
        final tamperedCiphertext = base64Encode(ciphertextBytes);

        expect(
          () => crypto.decrypt(
            tamperedCiphertext,
            encrypted['nonce']!,
            encrypted['mac']!,
          ),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      });

      test('decrypt fails with tampered nonce', () async {
        const plaintext = 'Secret message';
        final encrypted = await crypto.encrypt(plaintext);

        // Tamper with nonce
        final nonceBytes = base64Decode(encrypted['nonce']!);
        nonceBytes[0] ^= 0xFF; // Flip bits in first byte
        final tamperedNonce = base64Encode(nonceBytes);

        expect(
          () => crypto.decrypt(
            encrypted['ciphertext']!,
            tamperedNonce,
            encrypted['mac']!,
          ),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      });

      test('decrypt fails with tampered MAC', () async {
        const plaintext = 'Secret message';
        final encrypted = await crypto.encrypt(plaintext);

        // Tamper with MAC
        final macBytes = base64Decode(encrypted['mac']!);
        macBytes[0] ^= 0xFF; // Flip bits in first byte
        final tamperedMac = base64Encode(macBytes);

        expect(
          () => crypto.decrypt(
            encrypted['ciphertext']!,
            encrypted['nonce']!,
            tamperedMac,
          ),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      });

      test('decrypt fails with swapped ciphertext and nonce', () async {
        const plaintext = 'Secret message';
        final encrypted = await crypto.encrypt(plaintext);

        // Swap ciphertext and nonce - this fails with ArgumentError
        // because nonce has wrong length (not 12 bytes)
        expect(
          () => crypto.decrypt(
            encrypted['nonce']!, // Wrong!
            encrypted['ciphertext']!, // Wrong!
            encrypted['mac']!,
          ),
          throwsArgumentError,
        );
      });
    });

    group('Encrypt/Decrypt State Errors', () {
      test('encrypt throws StateError without session key', () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        expect(
          () => crypto.encrypt('Hello'),
          throwsStateError,
        );
      });

      test('decrypt throws StateError without session key', () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        expect(
          () => crypto.decrypt('YQ==', 'YQ==', 'YQ=='),
          throwsStateError,
        );
      });
    });

    group('Dispose', () {
      test('dispose clears key pair and session key', () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        final serverCrypto = CryptoManager();
        final serverPublicKey = await serverCrypto.generateKeyPair();
        await crypto.deriveSessionKey(serverPublicKey);

        expect(crypto.hasKeyPair, isTrue);
        expect(crypto.hasSessionKey, isTrue);

        crypto.dispose();

        expect(crypto.hasKeyPair, isFalse);
        expect(crypto.hasSessionKey, isFalse);
      });

      test('operations fail after dispose', () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        final serverCrypto = CryptoManager();
        final serverPublicKey = await serverCrypto.generateKeyPair();
        await crypto.deriveSessionKey(serverPublicKey);

        crypto.dispose();

        // deriveSessionKey should fail (no key pair)
        expect(
          () => crypto.deriveSessionKey(serverPublicKey),
          throwsStateError,
        );

        // encrypt should fail (no session key)
        expect(
          () => crypto.encrypt('Hello'),
          throwsStateError,
        );
      });

      test('dispose can be called multiple times safely', () async {
        final crypto = CryptoManager();
        await crypto.generateKeyPair();

        crypto.dispose();
        crypto.dispose(); // Should not throw
        crypto.dispose();

        expect(crypto.hasKeyPair, isFalse);
        expect(crypto.hasSessionKey, isFalse);
      });
    });
  });
}
