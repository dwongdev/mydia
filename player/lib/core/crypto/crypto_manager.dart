/// Crypto manager for X25519 key exchange and ChaCha20-Poly1305 encryption.
///
/// This class provides cryptographic operations for secure communication:
/// - X25519 key pair generation
/// - ECDH session key derivation via HKDF-SHA256
/// - ChaCha20-Poly1305 AEAD encryption/decryption
///
/// ## Usage
///
/// ```dart
/// final crypto = CryptoManager();
///
/// // Generate key pair and get base64-encoded public key
/// final publicKey = await crypto.generateKeyPair();
///
/// // Derive session key from server's public key
/// await crypto.deriveSessionKey(serverPublicKeyBase64);
///
/// // Encrypt a message
/// final encrypted = await crypto.encrypt('Hello, World!');
/// // encrypted = {ciphertext: '...', nonce: '...', mac: '...'}
///
/// // Decrypt a message
/// final plaintext = await crypto.decrypt(
///   encrypted['ciphertext']!,
///   encrypted['nonce']!,
///   encrypted['mac']!,
/// );
/// ```
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Pure Dart cryptography instance to avoid browser WebCrypto detection issues.
final _dartCrypto = DartCryptography.defaultInstance;

/// Manages X25519 key exchange and ChaCha20-Poly1305 encryption.
///
/// Provides secure cryptographic operations for establishing encrypted
/// communication channels using modern, well-vetted algorithms.
class CryptoManager {
  /// Creates a new CryptoManager instance.
  CryptoManager();

  /// The X25519 algorithm instance for key exchange.
  /// Uses pure Dart implementation to avoid browser WebCrypto compatibility issues.
  final _x25519 = _dartCrypto.x25519();

  /// The ChaCha20-Poly1305 AEAD cipher for encryption.
  /// Uses pure Dart implementation for cross-platform compatibility.
  final _cipher = _dartCrypto.chacha20Poly1305Aead();

  /// The HKDF algorithm with SHA-256 for key derivation.
  final _hkdf = _dartCrypto.hkdf(
    hmac: _dartCrypto.hmac(_dartCrypto.sha256()),
    outputLength: 32,
  );

  /// The generated X25519 key pair.
  SimpleKeyPair? _keyPair;

  /// The derived session key for encryption/decryption.
  SecretKey? _sessionKey;

  /// Generates an X25519 key pair and returns the base64-encoded public key.
  ///
  /// The key pair is stored internally for later use in session key derivation.
  ///
  /// ## Returns
  ///
  /// A base64-encoded string representing the public key (32 bytes).
  ///
  /// ## Example
  ///
  /// ```dart
  /// final crypto = CryptoManager();
  /// final publicKey = await crypto.generateKeyPair();
  /// // Send publicKey to the server for key exchange
  /// ```
  Future<String> generateKeyPair() async {
    // Generate a 32-byte seed manually using dart:math Random.secure() to
    // bypass browser WebCrypto detection issues. The cryptography package's
    // internal random byte generation (fillBytesWithSecureRandom) tries to
    // use browser WebCrypto API which fails in some browser environments with
    // "null: type 'Null' is not a subtype of type 'Object'" error.
    final random = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      seed[i] = random.nextInt(256);
    }
    _keyPair = await _x25519.newKeyPairFromSeed(seed);
    final publicKey = await _keyPair!.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Derives a session key from the server's base64-encoded public key.
  ///
  /// Uses X25519 ECDH to compute a shared secret, then derives a 32-byte
  /// session key using HKDF-SHA256.
  ///
  /// ## Parameters
  ///
  /// - `serverPublicKeyBase64` - The server's public key encoded as base64.
  ///
  /// ## Throws
  ///
  /// - [StateError] if no key pair has been generated yet.
  /// - [FormatException] if the base64 string is invalid.
  /// - [ArgumentError] if the public key is not 32 bytes.
  ///
  /// ## Example
  ///
  /// ```dart
  /// await crypto.deriveSessionKey(serverPublicKeyBase64);
  /// // Session key is now ready for encryption/decryption
  /// ```
  Future<void> deriveSessionKey(String serverPublicKeyBase64) async {
    if (_keyPair == null) {
      throw StateError('No key pair generated. Call generateKeyPair() first.');
    }

    // Decode server's public key from base64
    final serverPublicKeyBytes = base64Decode(serverPublicKeyBase64);
    if (serverPublicKeyBytes.length != 32) {
      throw ArgumentError(
        'Invalid public key length: expected 32 bytes, got ${serverPublicKeyBytes.length}',
      );
    }

    final serverPublicKey = SimplePublicKey(
      serverPublicKeyBytes,
      type: KeyPairType.x25519,
    );

    // Compute shared secret via X25519 ECDH
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: serverPublicKey,
    );

    // Derive session key via HKDF-SHA256
    // Note: info must match Elixir's Mydia.Crypto module for interoperability
    _sessionKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: Uint8List(0),
      info: utf8.encode('mydia-session-key'),
    );
  }

  /// Encrypts a plaintext message using ChaCha20-Poly1305.
  ///
  /// Returns a map containing the ciphertext, nonce, and MAC as base64 strings.
  ///
  /// ## Parameters
  ///
  /// - `plaintext` - The message to encrypt.
  ///
  /// ## Returns
  ///
  /// A map with keys:
  /// - `ciphertext` - The encrypted message (base64)
  /// - `nonce` - The random nonce used (base64)
  /// - `mac` - The authentication tag (base64)
  ///
  /// ## Throws
  ///
  /// - [StateError] if no session key has been derived.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final encrypted = await crypto.encrypt('Secret message');
  /// print(encrypted['ciphertext']); // base64-encoded ciphertext
  /// print(encrypted['nonce']);      // base64-encoded nonce
  /// print(encrypted['mac']);        // base64-encoded MAC
  /// ```
  Future<Map<String, String>> encrypt(String plaintext) async {
    if (_sessionKey == null) {
      throw StateError(
        'No session key derived. Call deriveSessionKey() first.',
      );
    }

    final plaintextBytes = utf8.encode(plaintext);

    // Generate nonce manually using dart:math Random.secure() to bypass
    // browser WebCrypto detection issues (same as in generateKeyPair).
    // ChaCha20-Poly1305 uses a 12-byte nonce.
    final random = Random.secure();
    final nonce = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      nonce[i] = random.nextInt(256);
    }

    final secretBox = await _cipher.encrypt(
      plaintextBytes,
      secretKey: _sessionKey!,
      nonce: nonce,
    );

    return {
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  /// Decrypts a message using ChaCha20-Poly1305.
  ///
  /// Verifies the MAC and decrypts the ciphertext.
  ///
  /// ## Parameters
  ///
  /// - `ciphertext` - The encrypted message (base64)
  /// - `nonce` - The nonce used during encryption (base64)
  /// - `mac` - The authentication tag (base64)
  ///
  /// ## Returns
  ///
  /// The decrypted plaintext string.
  ///
  /// ## Throws
  ///
  /// - [StateError] if no session key has been derived.
  /// - [FormatException] if any base64 string is invalid.
  /// - [SecretBoxAuthenticationError] if MAC verification fails
  ///   (indicating tampering or wrong key).
  ///
  /// ## Example
  ///
  /// ```dart
  /// final plaintext = await crypto.decrypt(
  ///   encrypted['ciphertext']!,
  ///   encrypted['nonce']!,
  ///   encrypted['mac']!,
  /// );
  /// print(plaintext); // 'Secret message'
  /// ```
  Future<String> decrypt(String ciphertext, String nonce, String mac) async {
    if (_sessionKey == null) {
      throw StateError(
        'No session key derived. Call deriveSessionKey() first.',
      );
    }

    final ciphertextBytes = base64Decode(ciphertext);
    final nonceBytes = base64Decode(nonce);
    final macBytes = base64Decode(mac);

    final secretBox = SecretBox(
      ciphertextBytes,
      nonce: nonceBytes,
      mac: Mac(macBytes),
    );

    final plaintextBytes = await _cipher.decrypt(
      secretBox,
      secretKey: _sessionKey!,
    );

    return utf8.decode(plaintextBytes);
  }

  /// Clears all stored keys from memory.
  ///
  /// Should be called when the CryptoManager is no longer needed
  /// to ensure sensitive key material is not retained.
  void dispose() {
    _keyPair = null;
    _sessionKey = null;
  }

  /// Returns whether a key pair has been generated.
  bool get hasKeyPair => _keyPair != null;

  /// Returns whether a session key has been derived.
  bool get hasSessionKey => _sessionKey != null;
}
