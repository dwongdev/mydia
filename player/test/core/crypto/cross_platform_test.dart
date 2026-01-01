/// Cross-platform compatibility tests for E2EE crypto operations.
///
/// These tests use fixed test vectors that must produce identical results
/// in both the Elixir (server) and Flutter (client) implementations.
///
/// Test vectors cover:
/// - X25519 ECDH key exchange
/// - HKDF-SHA256 key derivation
/// - ChaCha20-Poly1305 authenticated encryption
///
/// The Elixir equivalent tests are in:
/// test/mydia/crypto/cross_platform_test.exs
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// ============================================================================
// Test Vector Constants
// These values are used by both Elixir and Flutter tests.
// Changing these values requires updating the Elixir tests as well.
// ============================================================================

/// X25519 key pairs (from RFC 7748 test vectors)
final alicePrivateKeyBytes =
    base64Decode('dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=');
final alicePublicKeyBytes =
    base64Decode('hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=');
final bobPrivateKeyBytes =
    base64Decode('XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=');
final bobPublicKeyBytes =
    base64Decode('3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=');

/// Expected shared secret from X25519 ECDH
final expectedSharedSecretBytes =
    base64Decode('Sl2dW6TOLeFyjjv0gDUPJeB+IclH0Z4zdvCbPB4WF0I=');

/// Expected session key after HKDF-SHA256 derivation
final expectedSessionKeyBytes =
    base64Decode('O4JgYEVzaUyxG0tuQz5E1ptxX2qcdrjbrY43QLM+xQw=');

/// ChaCha20-Poly1305 encryption test vectors
final testNonceBytes = base64Decode('AAAAAAAAAAAAAAAB');
const testPlaintext = 'Hello from Elixir to Flutter!';
final expectedCiphertextBytes =
    base64Decode('FR87tXgCzdKEwRwego00v8WLjSpKQEpYhstK60k=');
final expectedMacBytes = base64Decode('dKLBE7tTUEB2tIOy3B9qHw==');

/// Additional HKDF test vectors
final hkdfTestIkm1 = Uint8List.fromList(List.filled(32, 0x01));
final hkdfExpectedKey1 =
    base64Decode('qw1cYyAG63Ob8gMI9lgxhE+ejdxGIrrGDYsFwnOiwFQ=');

final hkdfTestIkm2 = Uint8List.fromList([
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, //
  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
  0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
  0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
]);
final hkdfExpectedKey2 =
    base64Decode('pYVxdJkM3ZsEWanSBDNfNdztu81/Zoul8+6vfk5LgZk=');

/// Additional ChaCha20-Poly1305 test vectors
final testKey1 = base64Decode('qw1cYyAG63Ob8gMI9lgxhE+ejdxGIrrGDYsFwnOiwFQ=');
final testNonce1 = base64Decode('AAAAAAAAAAAAAAAB');
const testPlaintext1 = 'Hello, World!';
final expectedCiphertext1 = base64Decode('sx9ZlIqKK5vS9Afj+A==');
final expectedMac1 = base64Decode('YfqcJ3IcQw0+Lrw9MnwjtA==');

final testNonce3 = base64Decode('ECAwQFBgcICQoLDA');
const testPlaintext3 = 'Test message for cross-platform compatibility';
final expectedCiphertext3 =
    base64Decode('bNRLMKmWw9+wMYfZgD5uqFWt6GY/6HPy1CHJCLKmRrq60m6rNMP9xv6wT5Ei');
final expectedMac3 = base64Decode('LEic0kwn4OHWu5n6Km3wnw==');

/// HKDF info string used for session key derivation
final hkdfInfo = utf8.encode('mydia-session-key');

void main() {
  group('Cross-Platform Crypto Compatibility', () {
    final x25519 = X25519();
    final cipher = Chacha20.poly1305Aead();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

    group('X25519 ECDH key exchange', () {
      test('computes correct shared secret (Alice perspective)', () async {
        // Create key pairs from test vectors
        final aliceKeyPair = SimpleKeyPairData(
          alicePrivateKeyBytes,
          publicKey: SimplePublicKey(
            alicePublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final bobPublicKey = SimplePublicKey(
          bobPublicKeyBytes,
          type: KeyPairType.x25519,
        );

        // Compute shared secret
        final sharedSecret = await x25519.sharedSecretKey(
          keyPair: aliceKeyPair,
          remotePublicKey: bobPublicKey,
        );

        final sharedSecretBytes = await sharedSecret.extractBytes();
        expect(sharedSecretBytes, equals(expectedSharedSecretBytes));
      });

      test('computes correct shared secret (Bob perspective)', () async {
        // Create key pairs from test vectors
        final bobKeyPair = SimpleKeyPairData(
          bobPrivateKeyBytes,
          publicKey: SimplePublicKey(
            bobPublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final alicePublicKey = SimplePublicKey(
          alicePublicKeyBytes,
          type: KeyPairType.x25519,
        );

        // Compute shared secret
        final sharedSecret = await x25519.sharedSecretKey(
          keyPair: bobKeyPair,
          remotePublicKey: alicePublicKey,
        );

        final sharedSecretBytes = await sharedSecret.extractBytes();
        expect(sharedSecretBytes, equals(expectedSharedSecretBytes));
      });

      test('both parties derive identical shared secret', () async {
        final aliceKeyPair = SimpleKeyPairData(
          alicePrivateKeyBytes,
          publicKey: SimplePublicKey(
            alicePublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final bobKeyPair = SimpleKeyPairData(
          bobPrivateKeyBytes,
          publicKey: SimplePublicKey(
            bobPublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final aliceShared = await x25519.sharedSecretKey(
          keyPair: aliceKeyPair,
          remotePublicKey: SimplePublicKey(
            bobPublicKeyBytes,
            type: KeyPairType.x25519,
          ),
        );

        final bobShared = await x25519.sharedSecretKey(
          keyPair: bobKeyPair,
          remotePublicKey: SimplePublicKey(
            alicePublicKeyBytes,
            type: KeyPairType.x25519,
          ),
        );

        final aliceSecretBytes = await aliceShared.extractBytes();
        final bobSecretBytes = await bobShared.extractBytes();

        expect(aliceSecretBytes, equals(bobSecretBytes));
        expect(aliceSecretBytes, equals(expectedSharedSecretBytes));
      });
    });

    group('HKDF-SHA256 key derivation', () {
      test('derives correct session key from shared secret', () async {
        final sharedSecret = SecretKey(expectedSharedSecretBytes);

        final sessionKey = await hkdf.deriveKey(
          secretKey: sharedSecret,
          nonce: Uint8List(0), // Empty salt
          info: hkdfInfo,
        );

        final sessionKeyBytes = await sessionKey.extractBytes();
        expect(sessionKeyBytes, equals(expectedSessionKeyBytes));
      });

      test('derives correct key with test vector 1 (all 0x01 bytes)', () async {
        final inputKey = SecretKey(hkdfTestIkm1);

        final derivedKey = await hkdf.deriveKey(
          secretKey: inputKey,
          nonce: Uint8List(0),
          info: hkdfInfo,
        );

        final derivedKeyBytes = await derivedKey.extractBytes();
        expect(derivedKeyBytes, equals(hkdfExpectedKey1));
      });

      test('derives correct key with test vector 2 (sequential bytes)',
          () async {
        final inputKey = SecretKey(hkdfTestIkm2);

        final derivedKey = await hkdf.deriveKey(
          secretKey: inputKey,
          nonce: Uint8List(0),
          info: hkdfInfo,
        );

        final derivedKeyBytes = await derivedKey.extractBytes();
        expect(derivedKeyBytes, equals(hkdfExpectedKey2));
      });

      test('full key exchange produces expected session key', () async {
        // Simulate full key exchange
        final aliceKeyPair = SimpleKeyPairData(
          alicePrivateKeyBytes,
          publicKey: SimplePublicKey(
            alicePublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final bobPublicKey = SimplePublicKey(
          bobPublicKeyBytes,
          type: KeyPairType.x25519,
        );

        final sharedSecret = await x25519.sharedSecretKey(
          keyPair: aliceKeyPair,
          remotePublicKey: bobPublicKey,
        );

        final sessionKey = await hkdf.deriveKey(
          secretKey: sharedSecret,
          nonce: Uint8List(0),
          info: hkdfInfo,
        );

        final sessionKeyBytes = await sessionKey.extractBytes();
        expect(sessionKeyBytes, equals(expectedSessionKeyBytes));
      });
    });

    group('ChaCha20-Poly1305 encryption', () {
      test('encrypts to expected ciphertext and MAC with test vector 1',
          () async {
        final secretKey = SecretKey(testKey1);
        final plaintextBytes = utf8.encode(testPlaintext1);

        final secretBox = await cipher.encrypt(
          plaintextBytes,
          secretKey: secretKey,
          nonce: testNonce1,
        );

        expect(secretBox.cipherText, equals(expectedCiphertext1));
        expect(secretBox.mac.bytes, equals(expectedMac1));
      });

      test('encrypts to expected ciphertext and MAC with test vector 3',
          () async {
        final secretKey = SecretKey(testKey1);
        final plaintextBytes = utf8.encode(testPlaintext3);

        final secretBox = await cipher.encrypt(
          plaintextBytes,
          secretKey: secretKey,
          nonce: testNonce3,
        );

        expect(secretBox.cipherText, equals(expectedCiphertext3));
        expect(secretBox.mac.bytes, equals(expectedMac3));
      });

      test('encrypts to expected ciphertext and MAC with E2E session key',
          () async {
        final secretKey = SecretKey(expectedSessionKeyBytes);
        final plaintextBytes = utf8.encode(testPlaintext);

        final secretBox = await cipher.encrypt(
          plaintextBytes,
          secretKey: secretKey,
          nonce: testNonceBytes,
        );

        expect(secretBox.cipherText, equals(expectedCiphertextBytes));
        expect(secretBox.mac.bytes, equals(expectedMacBytes));
      });

      test('decrypts test vector ciphertext correctly', () async {
        final secretKey = SecretKey(expectedSessionKeyBytes);

        final secretBox = SecretBox(
          expectedCiphertextBytes,
          nonce: testNonceBytes,
          mac: Mac(expectedMacBytes),
        );

        final plaintextBytes = await cipher.decrypt(
          secretBox,
          secretKey: secretKey,
        );

        expect(utf8.decode(plaintextBytes), equals(testPlaintext));
      });

      test('decrypts test vector 1 correctly', () async {
        final secretKey = SecretKey(testKey1);

        final secretBox = SecretBox(
          expectedCiphertext1,
          nonce: testNonce1,
          mac: Mac(expectedMac1),
        );

        final plaintextBytes = await cipher.decrypt(
          secretBox,
          secretKey: secretKey,
        );

        expect(utf8.decode(plaintextBytes), equals(testPlaintext1));
      });

      test('decrypts test vector 3 correctly', () async {
        final secretKey = SecretKey(testKey1);

        final secretBox = SecretBox(
          expectedCiphertext3,
          nonce: testNonce3,
          mac: Mac(expectedMac3),
        );

        final plaintextBytes = await cipher.decrypt(
          secretBox,
          secretKey: secretKey,
        );

        expect(utf8.decode(plaintextBytes), equals(testPlaintext3));
      });

      test('fails decryption with wrong MAC', () async {
        final secretKey = SecretKey(expectedSessionKeyBytes);

        // Flip a bit in the MAC
        final wrongMacBytes = Uint8List.fromList(expectedMacBytes);
        wrongMacBytes[0] ^= 0x01;

        final secretBox = SecretBox(
          expectedCiphertextBytes,
          nonce: testNonceBytes,
          mac: Mac(wrongMacBytes),
        );

        expect(
          () => cipher.decrypt(secretBox, secretKey: secretKey),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      });

      test('fails decryption with wrong key', () async {
        final wrongKey = SecretKey(Uint8List(32)); // All zeros

        final secretBox = SecretBox(
          expectedCiphertextBytes,
          nonce: testNonceBytes,
          mac: Mac(expectedMacBytes),
        );

        expect(
          () => cipher.decrypt(secretBox, secretKey: wrongKey),
          throwsA(isA<SecretBoxAuthenticationError>()),
        );
      });
    });

    group('end-to-end cross-platform flow', () {
      test('full flow: key exchange -> key derivation -> encryption', () async {
        // Step 1: Key Exchange (simulate Alice and Bob exchanging public keys)
        final aliceKeyPair = SimpleKeyPairData(
          alicePrivateKeyBytes,
          publicKey: SimplePublicKey(
            alicePublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final bobKeyPair = SimpleKeyPairData(
          bobPrivateKeyBytes,
          publicKey: SimplePublicKey(
            bobPublicKeyBytes,
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );

        final aliceShared = await x25519.sharedSecretKey(
          keyPair: aliceKeyPair,
          remotePublicKey: SimplePublicKey(
            bobPublicKeyBytes,
            type: KeyPairType.x25519,
          ),
        );

        final bobShared = await x25519.sharedSecretKey(
          keyPair: bobKeyPair,
          remotePublicKey: SimplePublicKey(
            alicePublicKeyBytes,
            type: KeyPairType.x25519,
          ),
        );

        final aliceSharedBytes = await aliceShared.extractBytes();
        final bobSharedBytes = await bobShared.extractBytes();
        expect(aliceSharedBytes, equals(bobSharedBytes));

        // Step 2: Key Derivation (both derive session key)
        final aliceSessionKey = await hkdf.deriveKey(
          secretKey: aliceShared,
          nonce: Uint8List(0),
          info: hkdfInfo,
        );

        final bobSessionKey = await hkdf.deriveKey(
          secretKey: bobShared,
          nonce: Uint8List(0),
          info: hkdfInfo,
        );

        final aliceKeyBytes = await aliceSessionKey.extractBytes();
        final bobKeyBytes = await bobSessionKey.extractBytes();
        expect(aliceKeyBytes, equals(bobKeyBytes));
        expect(aliceKeyBytes, equals(expectedSessionKeyBytes));

        // Step 3: Encryption (Alice encrypts a message)
        final plaintextBytes = utf8.encode(testPlaintext);
        final secretBox = await cipher.encrypt(
          plaintextBytes,
          secretKey: aliceSessionKey,
          nonce: testNonceBytes,
        );

        // Step 4: Decryption (Bob decrypts the message)
        final decrypted = await cipher.decrypt(
          secretBox,
          secretKey: bobSessionKey,
        );

        expect(utf8.decode(decrypted), equals(testPlaintext));
      });

      test('can decrypt message encrypted by Elixir', () async {
        // This test verifies that Flutter can decrypt a message
        // that was encrypted by Elixir with the known test vectors

        final sessionKey = SecretKey(expectedSessionKeyBytes);

        final secretBox = SecretBox(
          expectedCiphertextBytes,
          nonce: testNonceBytes,
          mac: Mac(expectedMacBytes),
        );

        final decrypted = await cipher.decrypt(
          secretBox,
          secretKey: sessionKey,
        );

        expect(utf8.decode(decrypted), equals(testPlaintext));
      });
    });

    group('base64 encoding compatibility', () {
      test('all test vectors are valid base64 and correct sizes', () {
        // X25519 keys are 32 bytes
        expect(alicePrivateKeyBytes.length, equals(32));
        expect(alicePublicKeyBytes.length, equals(32));
        expect(bobPrivateKeyBytes.length, equals(32));
        expect(bobPublicKeyBytes.length, equals(32));

        // Shared secret and session key are 32 bytes
        expect(expectedSharedSecretBytes.length, equals(32));
        expect(expectedSessionKeyBytes.length, equals(32));

        // Nonce is 12 bytes
        expect(testNonceBytes.length, equals(12));

        // MAC is 16 bytes
        expect(expectedMacBytes.length, equals(16));
      });

      test('ciphertext length matches plaintext length', () {
        // ChaCha20 is a stream cipher, so ciphertext length equals plaintext length
        expect(
          expectedCiphertextBytes.length,
          equals(utf8.encode(testPlaintext).length),
        );
      });
    });
  });
}
