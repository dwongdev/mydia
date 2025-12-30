/// Noise Protocol service for E2E encrypted remote device pairing.
///
/// This service implements Noise Protocol handshakes compatible with the
/// backend Decibel library using pure Dart cryptography primitives.
///
/// ## Supported Patterns
///
/// - **Noise_NK**: Initial pairing (client as initiator, server static key known)
/// - **Noise_IK**: Reconnection (mutual authentication with known static keys)
///
/// ## Protocol Configuration
///
/// - **Protocol**: Noise_IK_25519_ChaChaPoly_BLAKE2b / Noise_NK_25519_ChaChaPoly_BLAKE2b
/// - **Key Exchange**: Curve25519 (X25519)
/// - **Cipher**: ChaCha20-Poly1305 (AEAD)
/// - **Hash**: BLAKE2b
///
/// ## Usage
///
/// ```dart
/// final service = NoiseService();
///
/// // Initial pairing (NK pattern)
/// final serverPublicKey = /* from QR code or manual entry */;
/// final session = await service.startPairingHandshake(serverPublicKey);
/// final firstMessage = await session.writeHandshakeMessage();
///
/// // Send firstMessage to server, receive response
/// await session.readHandshakeMessage(serverResponse);
/// final encrypted = await session.encrypt(payload);
///
/// // Reconnection (IK pattern)
/// final reconnectSession = await service.startReconnectHandshake(serverPublicKey);
/// final firstMsg = await reconnectSession.writeHandshakeMessage();
/// await reconnectSession.readHandshakeMessage(serverResponse);
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:x25519/x25519.dart' as x25519_dart;

/// Keys for secure storage.
abstract class _StorageKeys {
  static const devicePublicKey = 'noise_device_public_key';
  static const devicePrivateKey = 'noise_device_private_key';
}

/// Noise session state for handshake and transport.
///
/// Manual implementation of Noise Protocol patterns NK and IK using
/// Curve25519 (X25519), ChaCha20-Poly1305, and BLAKE2b.
///
/// This implementation is compatible with the Decibel Elixir library.
class NoiseSession {
  NoiseSession._({
    required this.isInitiator,
    required this.pattern,
    this.localStaticKeypair,
    this.localStaticKeypairDart,
    this.remoteStaticPublicKey,
  });

  final bool isInitiator;
  final NoisePattern pattern;
  final SimpleKeyPair? localStaticKeypair;
  final x25519_dart.KeyPair? localStaticKeypairDart;
  final Uint8List? remoteStaticPublicKey;

  /// Symmetric state for encryption (CipherState + SymmetricState)
  final _chainingKey = Uint8List(64); // BLAKE2b output size = 64 bytes
  final _hash = Uint8List(64); // BLAKE2b output size = 64 bytes

  /// Cipher key for encryption during handshake (null = no key yet)
  /// This is set by MixKey and used by EncryptAndHash/DecryptAndHash.
  Uint8List? _cipherKey;

  /// Cipher nonce for handshake encryption (resets after each MixKey)
  int _cipherNonce = 0;

  SimpleKeyPair? _ephemeralKeypair;
  x25519_dart.KeyPair? _ephemeralKeypairDart;
  Uint8List? _remoteEphemeralPublicKey;

  /// Transport encryption keys (derived after handshake)
  SecretKey? _sendKey;
  SecretKey? _receiveKey;
  int _sendNonce = 0;
  int _receiveNonce = 0;

  /// Whether the handshake is complete and the session is ready for transport encryption.
  bool isComplete = false;

  /// Current message index in handshake
  int _messageIndex = 0;

  /// Writes a handshake message with optional payload.
  ///
  /// For NK pattern (initial pairing):
  /// - First message: e, es (client's ephemeral key and DH with server static)
  ///
  /// For IK pattern (reconnection):
  /// - First message: e, es, s, ss (client's ephemeral key, static key encrypted, and DHs)
  ///
  /// Returns the handshake message to send to the server.
  Future<Uint8List> writeHandshakeMessage([Uint8List? payload]) async {
    if (!isInitiator) {
      throw StateError('Only initiator can write first message');
    }

    if (_messageIndex != 0) {
      throw StateError('Unexpected message index: $_messageIndex');
    }

    final buffer = BytesBuilder();

    // Generate ephemeral keypair using pure Dart x25519 (avoids WebCrypto hang on web)
    _ephemeralKeypairDart = x25519_dart.generateKeyPair();
    final ephemeralPublicKeyBytes = Uint8List.fromList(_ephemeralKeypairDart!.publicKey);

    // Write ephemeral public key (e)
    buffer.add(ephemeralPublicKeyBytes);
    _mixHash(ephemeralPublicKeyBytes);

    // Perform DH with remote static key (es)
    if (remoteStaticPublicKey == null) {
      throw StateError('Remote static public key required');
    }
    final esBytes = Uint8List.fromList(x25519_dart.X25519(
      _ephemeralKeypairDart!.privateKey,
      remoteStaticPublicKey!,
    ));
    _mixKey(esBytes);

    if (pattern == NoisePattern.ik) {
      // IK: Send encrypted static key (s)
      final localPublicKeyBytes = localStaticKeypairDart != null
          ? Uint8List.fromList(localStaticKeypairDart!.publicKey)
          : (await localStaticKeypair!.extractPublicKey()).bytes as Uint8List;
      final encryptedStatic = await _encryptAndHash(Uint8List.fromList(localPublicKeyBytes));
      buffer.add(encryptedStatic);

      // Perform DH between static keys (ss)
      final localPrivateKey = localStaticKeypairDart != null
          ? localStaticKeypairDart!.privateKey
          : await localStaticKeypair!.extractPrivateKeyBytes();
      final ssBytes = Uint8List.fromList(x25519_dart.X25519(
        localPrivateKey,
        remoteStaticPublicKey!,
      ));
      _mixKey(ssBytes);
    }

    // Always encrypt payload (even if empty) - this produces the auth tag
    final effectivePayload = payload ?? Uint8List(0);
    final encryptedPayload = await _encryptAndHash(effectivePayload);
    buffer.add(encryptedPayload);

    _messageIndex++;
    return buffer.toBytes();
  }

  /// Reads a handshake message and extracts payload.
  ///
  /// For NK pattern:
  /// - Second message: e, ee (server's ephemeral key and DH)
  ///
  /// For IK pattern:
  /// - Second message: e, ee, se (server's ephemeral key and DHs)
  ///
  /// Returns the decrypted payload from the handshake message.
  Future<Uint8List> readHandshakeMessage(Uint8List message) async {
    if (!isInitiator) {
      throw StateError('Only initiator can read response');
    }

    if (_messageIndex != 1) {
      throw StateError('Unexpected message index: $_messageIndex');
    }

    var offset = 0;

    // Read remote ephemeral key (e)
    if (offset + 32 > message.length) {
      throw ArgumentError('Message too short for ephemeral key');
    }
    _remoteEphemeralPublicKey = message.sublist(offset, offset + 32);
    offset += 32;
    _mixHash(_remoteEphemeralPublicKey!);

    // Perform ee DH using pure Dart x25519 (avoids WebCrypto hang on web)
    final eeBytes = Uint8List.fromList(x25519_dart.X25519(
      _ephemeralKeypairDart!.privateKey,
      _remoteEphemeralPublicKey!,
    ));
    _mixKey(eeBytes);

    if (pattern == NoisePattern.ik && localStaticKeypairDart != null) {
      // IK: Perform se DH using pure Dart x25519
      final seBytes = Uint8List.fromList(x25519_dart.X25519(
        localStaticKeypairDart!.privateKey,
        _remoteEphemeralPublicKey!,
      ));
      _mixKey(seBytes);
    }

    // Decrypt the remaining payload (always present, at least auth tag for empty payload)
    final payload = await _decryptAndHash(message.sublist(offset));

    // Split keys for transport
    _split();
    isComplete = true;
    _messageIndex++;

    return payload;
  }

  /// Encrypts a transport message after handshake is complete.
  ///
  /// Uses ChaCha20-Poly1305 AEAD cipher with automatic nonce increment.
  /// The encrypted message includes the nonce, ciphertext, and authentication tag.
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    if (!isComplete) {
      throw StateError('Handshake must be complete before encrypting');
    }
    if (_sendKey == null) {
      throw StateError('Send key not initialized');
    }

    final cipher = Chacha20.poly1305Aead();
    final nonce = _uint64ToBytes(_sendNonce);
    _sendNonce++;

    final secretBox = await cipher.encrypt(
      plaintext,
      secretKey: _sendKey!,
      nonce: nonce,
    );

    // Format: nonce (8 bytes) + ciphertext + mac (16 bytes)
    final result = BytesBuilder();
    result.add(nonce);
    result.add(secretBox.cipherText);
    result.add(secretBox.mac.bytes);

    return result.toBytes();
  }

  /// Decrypts a transport message after handshake is complete.
  ///
  /// Verifies the authentication tag and decrypts using ChaCha20-Poly1305.
  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    if (!isComplete) {
      throw StateError('Handshake must be complete before decrypting');
    }
    if (_receiveKey == null) {
      throw StateError('Receive key not initialized');
    }

    if (ciphertext.length < 24) {
      throw ArgumentError('Ciphertext too short');
    }

    // Parse: nonce (8 bytes) + ciphertext + mac (16 bytes)
    final nonce = ciphertext.sublist(0, 8);
    final mac = ciphertext.sublist(ciphertext.length - 16);
    final encryptedData = ciphertext.sublist(8, ciphertext.length - 16);

    final cipher = Chacha20.poly1305Aead();
    final secretBox = SecretBox(
      encryptedData,
      nonce: nonce,
      mac: Mac(mac),
    );

    final plaintext = await cipher.decrypt(
      secretBox,
      secretKey: _receiveKey!,
    );

    _receiveNonce++;
    return Uint8List.fromList(plaintext);
  }

  /// Disposes of the handshake state and clears sensitive key material.
  void dispose() {
    _chainingKey.fillRange(0, _chainingKey.length, 0);
    _hash.fillRange(0, _hash.length, 0);
    _cipherKey?.fillRange(0, _cipherKey!.length, 0);
    _cipherKey = null;
    _cipherNonce = 0;
    _sendNonce = 0;
    _receiveNonce = 0;
    _ephemeralKeypair = null;
    _remoteEphemeralPublicKey = null;
    _sendKey = null;
    _receiveKey = null;
  }

  // ============================================================================
  // Noise Protocol Symmetric State Functions
  // ============================================================================

  /// Initialize the symmetric state with protocol name and pre-messages.
  void _initialize(String protocolName, Uint8List remoteStaticKey) {
    // Initialize hash with protocol name (pad with zeros if shorter than 64 bytes)
    final protocolBytes = Uint8List.fromList(protocolName.codeUnits);

    if (protocolBytes.length <= 64) {
      // If protocol name fits in 64 bytes, pad with zeros
      _hash.setRange(0, protocolBytes.length, protocolBytes);
      _hash.fillRange(protocolBytes.length, 64, 0);
    } else {
      // Otherwise hash it
      final hashed = _blake2b(protocolBytes);
      _hash.setRange(0, 64, hashed);
    }

    // Initialize chaining key to hash
    _chainingKey.setRange(0, 64, _hash);

    // No cipher key initially (will be set by first MixKey)
    _cipherKey = null;
    _cipherNonce = 0;

    // For NK and IK patterns, the responder's static key is a pre-message
    // Mix it into the hash (as if we received it)
    _mixHash(remoteStaticKey);
  }

  /// MixKey: mixes new key material into the chaining key and derives a new cipher key.
  ///
  /// This follows the Noise specification:
  /// - Sets ck, temp_k = HKDF(ck, input_key_material, 2)
  /// - Initializes cipher key with temp_k[:32]
  /// - Resets cipher nonce to 0
  void _mixKey(Uint8List inputKeyMaterial) {
    // HKDF returns (ck, temp_k) where each is hash_len bytes
    final (newCk, tempK) = _hkdf2(_chainingKey, inputKeyMaterial);

    // Update chaining key
    _chainingKey.setRange(0, 64, newCk);

    // Initialize cipher key with first 32 bytes of temp_k
    _cipherKey = tempK.sublist(0, 32);

    // Reset nonce for the new key
    _cipherNonce = 0;
  }

  /// MixHash: mixes new data into the hash.
  void _mixHash(Uint8List data) {
    final combined = Uint8List.fromList([..._hash, ...data]);
    final newHash = _blake2b(combined);
    _hash.setRange(0, 64, newHash);
  }

  /// EncryptAndHash: encrypts plaintext using the current cipher key and mixes ciphertext into hash.
  ///
  /// If no cipher key is set (before any MixKey), returns plaintext unchanged.
  Future<Uint8List> _encryptAndHash(Uint8List plaintext) async {
    // If no cipher key is set, just mix hash and return plaintext
    // (This shouldn't happen in NK/IK patterns after the first MixKey)
    if (_cipherKey == null) {
      _mixHash(plaintext);
      return plaintext;
    }

    final key = SecretKey(_cipherKey!);
    final cipher = Chacha20.poly1305Aead();

    // Nonce is 12 bytes: 4 zeros + 8-byte little-endian counter
    final nonce = _makeNonce(_cipherNonce);
    _cipherNonce++;

    final secretBox = await cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _hash, // Use current hash as additional authenticated data
    );

    // Ciphertext = encrypted data + MAC (16 bytes)
    final ciphertext = Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);

    // Mix the ciphertext into the hash
    _mixHash(ciphertext);

    return ciphertext;
  }

  /// DecryptAndHash: decrypts ciphertext using the current cipher key and mixes it into hash.
  Future<Uint8List> _decryptAndHash(Uint8List ciphertext) async {
    if (ciphertext.length < 16) {
      throw ArgumentError('Ciphertext too short for MAC');
    }

    // If no cipher key is set, just mix hash and return ciphertext
    // (This shouldn't happen in NK/IK patterns after the first MixKey)
    if (_cipherKey == null) {
      _mixHash(ciphertext);
      return ciphertext;
    }

    final mac = ciphertext.sublist(ciphertext.length - 16);
    final encryptedData = ciphertext.sublist(0, ciphertext.length - 16);

    final key = SecretKey(_cipherKey!);
    final cipher = Chacha20.poly1305Aead();

    // Nonce is 12 bytes: 4 zeros + 8-byte little-endian counter
    final nonce = _makeNonce(_cipherNonce);
    _cipherNonce++;

    final secretBox = SecretBox(
      encryptedData,
      nonce: nonce,
      mac: Mac(mac),
    );

    // Mix the ciphertext into the hash BEFORE decryption
    // (so the hash used for AAD is the pre-mix state)
    final hashBeforeMix = Uint8List.fromList(_hash);
    _mixHash(ciphertext);

    final plaintext = await cipher.decrypt(
      secretBox,
      secretKey: key,
      aad: hashBeforeMix,
    );

    return Uint8List.fromList(plaintext);
  }

  /// Split: derives transport encryption keys after handshake.
  ///
  /// Sets temp_k1, temp_k2 = HKDF(ck, empty, 2)
  /// - For initiator: send key = temp_k1[:32], receive key = temp_k2[:32]
  /// - For responder: send key = temp_k2[:32], receive key = temp_k1[:32]
  void _split() {
    final (tempK1, tempK2) = _hkdf2(_chainingKey, Uint8List(0));

    // For initiator: c1 = send, c2 = receive
    // For responder: c1 = receive, c2 = send
    // Since we're always the initiator in this implementation:
    _sendKey = SecretKey(tempK1.sublist(0, 32));
    _receiveKey = SecretKey(tempK2.sublist(0, 32));
  }

  // ============================================================================
  // Cryptographic Primitives
  // ============================================================================

  /// BLAKE2b hash function (512-bit output).
  Uint8List _blake2b(Uint8List data) {
    final digest = pc.Blake2bDigest(digestSize: 64);
    final output = Uint8List(64);
    digest.update(data, 0, data.length);
    digest.doFinal(output, 0);
    return output;
  }

  /// HMAC-BLAKE2b: keyed hash function.
  Uint8List _hmacBlake2b(Uint8List key, Uint8List data) {
    final hmac = pc.HMac(pc.Blake2bDigest(digestSize: 64), 128);
    hmac.init(pc.KeyParameter(key));
    hmac.update(data, 0, data.length);
    final output = Uint8List(64);
    hmac.doFinal(output, 0);
    return output;
  }

  /// HKDF using BLAKE2b, returning 2 outputs as a tuple.
  ///
  /// This follows the Noise specification HKDF(chaining_key, input_key_material, num_outputs):
  /// - temp_key = HMAC-HASH(chaining_key, input_key_material)
  /// - output1 = HMAC-HASH(temp_key, 0x01)
  /// - output2 = HMAC-HASH(temp_key, output1 || 0x02)
  ///
  /// Returns (output1, output2) where each is 64 bytes.
  (Uint8List, Uint8List) _hkdf2(Uint8List chainingKey, Uint8List inputKeyMaterial) {
    // HKDF-Extract: temp_key = HMAC-BLAKE2b(chaining_key, input_key_material)
    final tempKey = _hmacBlake2b(chainingKey, inputKeyMaterial);

    // HKDF-Expand for 2 outputs:
    // output1 = HMAC-BLAKE2b(temp_key, 0x01)
    final output1 = _hmacBlake2b(tempKey, Uint8List.fromList([0x01]));

    // output2 = HMAC-BLAKE2b(temp_key, output1 || 0x02)
    final output2Input = Uint8List.fromList([...output1, 0x02]);
    final output2 = _hmacBlake2b(tempKey, output2Input);

    return (output1, output2);
  }

  /// Creates a 12-byte ChaCha20-Poly1305 nonce from an integer counter.
  ///
  /// Format: 4 zero bytes + 8-byte little-endian counter
  Uint8List _makeNonce(int counter) {
    final nonce = Uint8List(12);
    final view = ByteData.view(nonce.buffer);
    // First 4 bytes are zeros (already initialized)
    // Last 8 bytes are the counter in little-endian
    view.setUint64(4, counter, Endian.little);
    return nonce;
  }

  /// Converts a uint64 nonce to 12-byte format for transport messages.
  ///
  /// Format: 4 zero bytes + 8-byte little-endian counter
  Uint8List _uint64ToBytes(int value) {
    return _makeNonce(value);
  }
}

/// Noise handshake patterns.
enum NoisePattern {
  /// NK: Initiator has no static key, responder's static key is known.
  nk,

  /// IK: Both parties have static keys, mutual authentication.
  ik,
}

/// Noise Protocol service for device pairing and reconnection.
///
/// This service manages device keypairs and provides methods to start
/// Noise protocol handshakes compatible with the backend Decibel library.
class NoiseService {
  NoiseService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Protocol names following Decibel naming convention.
  /// These will be used when the full Noise protocol implementation is complete.
  // ignore: unused_field
  static const _protocolNK = 'Noise_NK_25519_ChaChaPoly_BLAKE2b';
  // ignore: unused_field
  static const _protocolIK = 'Noise_IK_25519_ChaChaPoly_BLAKE2b';

  /// Generates a new Curve25519 keypair for this device.
  ///
  /// Uses pure Dart x25519 implementation to avoid WebCrypto hang on web.
  /// Returns a tuple of (publicKey, privateKey) as Uint8List.
  (Uint8List, Uint8List) generateKeypair() {
    final keypair = x25519_dart.generateKeyPair();
    return (
      Uint8List.fromList(keypair.publicKey),
      Uint8List.fromList(keypair.privateKey),
    );
  }

  /// Loads the device keypair from secure storage, or generates and stores a new one.
  ///
  /// Returns a tuple of (publicKey, privateKey) as Uint8List.
  Future<(Uint8List, Uint8List)> loadOrGenerateKeypair() async {
    // Try to load existing keypair
    final publicKeyStr = await _storage.read(key: _StorageKeys.devicePublicKey);
    final privateKeyStr =
        await _storage.read(key: _StorageKeys.devicePrivateKey);

    if (publicKeyStr != null && privateKeyStr != null) {
      // Decode from base64
      final publicKey = Uint8List.fromList(base64Decode(publicKeyStr));
      final privateKey = Uint8List.fromList(base64Decode(privateKeyStr));
      return (publicKey, privateKey);
    }

    // Generate new keypair using pure Dart x25519 (avoids WebCrypto hang)
    final (publicKey, privateKey) = generateKeypair();

    // Store in secure storage
    await _storage.write(
      key: _StorageKeys.devicePublicKey,
      value: base64Encode(publicKey),
    );
    await _storage.write(
      key: _StorageKeys.devicePrivateKey,
      value: base64Encode(privateKey),
    );

    return (publicKey, privateKey);
  }

  /// Retrieves the device's public key from storage.
  ///
  /// Returns null if no keypair has been generated yet.
  Future<Uint8List?> getDevicePublicKey() async {
    final publicKeyStr = await _storage.read(key: _StorageKeys.devicePublicKey);
    if (publicKeyStr == null) return null;
    return Uint8List.fromList(base64Decode(publicKeyStr));
  }

  /// Deletes the device keypair from storage.
  ///
  /// This should be called when the device is unpaired or revoked.
  Future<void> deleteKeypair() async {
    await _storage.delete(key: _StorageKeys.devicePublicKey);
    await _storage.delete(key: _StorageKeys.devicePrivateKey);
  }

  /// Starts a Noise_NK handshake for initial device pairing (client as initiator).
  ///
  /// The NK pattern is used when the client does not yet have a registered static key.
  /// The server's public key must be known to the client (from QR code or manual entry).
  ///
  /// ## Handshake Flow (NK Pattern)
  ///
  /// 1. Client -> Server: `e, es` (ephemeral key, DH with server static)
  /// 2. Server -> Client: `e, ee` (ephemeral key, DH ephemeral-ephemeral)
  /// 3. Handshake complete, secure channel established
  ///
  /// ## Parameters
  ///
  /// - `serverPublicKey` - The server's static public key (32 bytes)
  ///
  /// ## Returns
  ///
  /// A NoiseSession ready for handshake message exchange.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final serverKey = /* from QR code */;
  /// final session = await service.startPairingHandshake(serverKey);
  /// final firstMessage = await session.writeHandshakeMessage();
  /// // Send firstMessage to server, receive response
  /// await session.readHandshakeMessage(serverResponse);
  /// ```
  Future<NoiseSession> startPairingHandshake(
    Uint8List serverPublicKey,
  ) async {
    if (serverPublicKey.length != 32) {
      throw ArgumentError('Server public key must be 32 bytes');
    }

    // Create Noise_NK handshake session as initiator
    // NK: client has no static key (N), server's public key is known (K)
    final session = NoiseSession._(
      isInitiator: true,
      pattern: NoisePattern.nk,
      localStaticKeypair: null,
      remoteStaticPublicKey: serverPublicKey,
    );

    // Initialize symmetric state with protocol name
    session._initialize(_protocolNK, serverPublicKey);
    return session;
  }

  /// Starts a Noise_IK handshake for device reconnection (client as initiator).
  ///
  /// The IK pattern provides mutual authentication - both client and server
  /// authenticate each other using their static keys.
  ///
  /// ## Handshake Flow (IK Pattern)
  ///
  /// 1. Client -> Server: `e, es, s, ss` (ephemeral key, static key encrypted, DHs)
  /// 2. Server verifies client's static key against device database
  /// 3. Server -> Client: `e, ee, se` (ephemeral key, complete DH)
  /// 4. Handshake complete, mutual authentication established
  ///
  /// ## Parameters
  ///
  /// - `serverPublicKey` - The server's static public key (32 bytes)
  ///
  /// ## Returns
  ///
  /// A NoiseSession ready for handshake message exchange.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final session = await service.startReconnectHandshake(serverKey);
  /// final firstMessage = await session.writeHandshakeMessage();
  /// // Send firstMessage to server, receive response
  /// await session.readHandshakeMessage(serverResponse);
  /// ```
  Future<NoiseSession> startReconnectHandshake(
    Uint8List serverPublicKey,
  ) async {
    if (serverPublicKey.length != 32) {
      throw ArgumentError('Server public key must be 32 bytes');
    }

    // Load device keypair
    final (publicKey, privateKey) = await loadOrGenerateKeypair();

    // Create pure Dart x25519 keypair from stored keys (avoids WebCrypto hang)
    final keypair = x25519_dart.KeyPair(
      publicKey: publicKey.toList(),
      privateKey: privateKey.toList(),
    );

    // Create Noise_IK handshake session as initiator
    // IK: client has static keypair (I), server's public key is known (K)
    final session = NoiseSession._(
      isInitiator: true,
      pattern: NoisePattern.ik,
      localStaticKeypairDart: keypair,
      remoteStaticPublicKey: serverPublicKey,
    );

    // Initialize symmetric state with protocol name
    session._initialize(_protocolIK, serverPublicKey);
    return session;
  }
}
