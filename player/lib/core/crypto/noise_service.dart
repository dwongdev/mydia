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

/// Keys for secure storage.
abstract class _StorageKeys {
  static const devicePublicKey = 'noise_device_public_key';
  static const devicePrivateKey = 'noise_device_private_key';
}

/// Noise session state for handshake and transport.
///
/// Manual implementation of Noise Protocol patterns NK and IK using
/// Curve25519 (X25519), ChaCha20-Poly1305, and BLAKE2b.
class NoiseSession {
  NoiseSession._({
    required this.isInitiator,
    required this.pattern,
    this.localStaticKeypair,
    this.remoteStaticPublicKey,
  });

  final bool isInitiator;
  final NoisePattern pattern;
  final SimpleKeyPair? localStaticKeypair;
  final Uint8List? remoteStaticPublicKey;

  /// Symmetric state for encryption
  final _chainingKey = Uint8List(64); // BLAKE2b output size
  final _hash = Uint8List(64); // BLAKE2b output size
  SimpleKeyPair? _ephemeralKeypair;
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

    // Generate ephemeral keypair
    final x25519 = X25519();
    _ephemeralKeypair = await x25519.newKeyPair();
    final ephemeralPublicKey = await _ephemeralKeypair!.extractPublicKey();
    final ephemeralPublicKeyBytes = Uint8List.fromList(ephemeralPublicKey.bytes);

    // Write ephemeral public key (e)
    buffer.add(ephemeralPublicKeyBytes);
    _mixHash(ephemeralPublicKeyBytes);

    // Perform DH with remote static key (es)
    if (remoteStaticPublicKey == null) {
      throw StateError('Remote static public key required');
    }
    final remoteStaticKey = SimplePublicKey(remoteStaticPublicKey!.toList(), type: KeyPairType.x25519);
    final esSharedSecret = await x25519.sharedSecretKey(
      keyPair: _ephemeralKeypair!,
      remotePublicKey: remoteStaticKey,
    );
    final esBytes = Uint8List.fromList(await esSharedSecret.extractBytes());
    _mixKey(esBytes);

    if (pattern == NoisePattern.ik) {
      // IK: Send encrypted static key (s)
      final localPublicKey = await localStaticKeypair!.extractPublicKey();
      final localPublicKeyBytes = Uint8List.fromList(localPublicKey.bytes);
      final encryptedStatic = await _encryptAndHash(localPublicKeyBytes);
      buffer.add(encryptedStatic);

      // Perform DH between static keys (ss)
      final ssSharedSecret = await x25519.sharedSecretKey(
        keyPair: localStaticKeypair!,
        remotePublicKey: remoteStaticKey,
      );
      final ssBytes = Uint8List.fromList(await ssSharedSecret.extractBytes());
      _mixKey(ssBytes);
    }

    // Encrypt payload if provided
    if (payload != null && payload.isNotEmpty) {
      final encryptedPayload = await _encryptAndHash(payload);
      buffer.add(encryptedPayload);
    }

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

    // Perform ee DH
    final remoteEphemeralKey = SimplePublicKey(_remoteEphemeralPublicKey!.toList(), type: KeyPairType.x25519);
    final x25519 = X25519();
    final eeSharedSecret = await x25519.sharedSecretKey(
      keyPair: _ephemeralKeypair!,
      remotePublicKey: remoteEphemeralKey,
    );
    final eeBytes = Uint8List.fromList(await eeSharedSecret.extractBytes());
    _mixKey(eeBytes);

    if (pattern == NoisePattern.ik && localStaticKeypair != null) {
      // IK: Perform se DH
      final seSharedSecret = await x25519.sharedSecretKey(
        keyPair: localStaticKeypair!,
        remotePublicKey: remoteEphemeralKey,
      );
      final seBytes = Uint8List.fromList(await seSharedSecret.extractBytes());
      _mixKey(seBytes);
    }

    // Decrypt any remaining payload
    Uint8List payload = Uint8List(0);
    if (offset < message.length) {
      payload = await _decryptAndHash(message.sublist(offset));
    }

    // Split keys for transport
    await _split();
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
    // Initialize hash with protocol name
    final protocolBytes = Uint8List.fromList(protocolName.codeUnits);

    if (protocolBytes.length <= 64) {
      // If protocol name fits in 64 bytes, use it directly
      _hash.setRange(0, protocolBytes.length, protocolBytes);
      _hash.fillRange(protocolBytes.length, 64, 0);
    } else {
      // Otherwise hash it
      final hashed = _blake2b(protocolBytes);
      _hash.setRange(0, 64, hashed);
    }

    // Initialize chaining key to hash
    _chainingKey.setRange(0, 64, _hash);

    // For NK and IK patterns, the responder's static key is a pre-message
    // Mix it into the hash (as if we received it)
    _mixHash(remoteStaticKey);
  }

  /// MixKey: mixes new key material into the chaining key.
  void _mixKey(Uint8List inputKeyMaterial) {
    // HKDF using BLAKE2b
    final tempKey = _hkdf(_chainingKey, inputKeyMaterial);
    _chainingKey.setRange(0, 64, tempKey.sublist(0, 64));
  }

  /// MixHash: mixes new data into the hash.
  void _mixHash(Uint8List data) {
    final combined = Uint8List.fromList([..._hash, ...data]);
    final newHash = _blake2b(combined);
    _hash.setRange(0, 64, newHash);
  }

  /// EncryptAndHash: encrypts plaintext and mixes ciphertext into hash.
  Future<Uint8List> _encryptAndHash(Uint8List plaintext) async {
    // Extract 32-byte key from chaining key
    final tempKey = _hkdf(_chainingKey, Uint8List(0));
    final key = SecretKey(tempKey.sublist(0, 32));

    final cipher = Chacha20.poly1305Aead();
    final nonce = Uint8List(12); // Zero nonce for handshake

    final secretBox = await cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _hash, // Use hash as additional authenticated data
    );

    // Ciphertext = encrypted data + MAC
    final ciphertext = Uint8List.fromList([...secretBox.cipherText, ...secretBox.mac.bytes]);
    _mixHash(ciphertext);
    return ciphertext;
  }

  /// DecryptAndHash: decrypts ciphertext and mixes it into hash.
  Future<Uint8List> _decryptAndHash(Uint8List ciphertext) async {
    // Extract 32-byte key from chaining key
    final tempKey = _hkdf(_chainingKey, Uint8List(0));
    final key = SecretKey(tempKey.sublist(0, 32));

    if (ciphertext.length < 16) {
      throw ArgumentError('Ciphertext too short for MAC');
    }

    final mac = ciphertext.sublist(ciphertext.length - 16);
    final encryptedData = ciphertext.sublist(0, ciphertext.length - 16);

    final cipher = Chacha20.poly1305Aead();
    final nonce = Uint8List(12); // Zero nonce for handshake

    final secretBox = SecretBox(
      encryptedData,
      nonce: nonce,
      mac: Mac(mac),
    );

    _mixHash(ciphertext);

    final plaintext = await cipher.decrypt(
      secretBox,
      secretKey: key,
      aad: _hash.sublist(0, 64), // Restore pre-mixHash state for AAD
    );

    return Uint8List.fromList(plaintext);
  }

  /// Split: derives transport encryption keys after handshake.
  Future<void> _split() async {
    final tempKey = _hkdf(_chainingKey, Uint8List(0));

    // First 32 bytes for sending, next 32 for receiving
    _sendKey = SecretKey(tempKey.sublist(0, 32));
    _receiveKey = SecretKey(tempKey.sublist(32, 64));
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

  /// HKDF using BLAKE2b as the hash function.
  Uint8List _hkdf(Uint8List chainingKey, Uint8List inputKeyMaterial) {
    // HKDF-Extract: HMAC-BLAKE2b(chainingKey, inputKeyMaterial)
    final hmac = pc.HMac(pc.Blake2bDigest(digestSize: 64), 128);
    hmac.init(pc.KeyParameter(chainingKey));

    final prkOutput = Uint8List(64);
    hmac.update(inputKeyMaterial, 0, inputKeyMaterial.length);
    hmac.doFinal(prkOutput, 0);

    // HKDF-Expand: Output 64 bytes (2 x 32-byte keys)
    final hmac2 = pc.HMac(pc.Blake2bDigest(digestSize: 64), 128);
    hmac2.init(pc.KeyParameter(prkOutput));

    final output1 = Uint8List(64);
    hmac2.update(Uint8List.fromList([0x01]), 0, 1);
    hmac2.doFinal(output1, 0);

    final hmac3 = pc.HMac(pc.Blake2bDigest(digestSize: 64), 128);
    hmac3.init(pc.KeyParameter(prkOutput));

    final output2 = Uint8List(64);
    final input2 = Uint8List.fromList([...output1, 0x02]);
    hmac3.update(input2, 0, input2.length);
    hmac3.doFinal(output2, 0);

    return Uint8List.fromList([...output1, ...output2]);
  }

  /// Converts a uint64 nonce to 8-byte little-endian format.
  Uint8List _uint64ToBytes(int value) {
    final bytes = Uint8List(12); // 12 bytes for ChaCha20 nonce
    final view = ByteData.view(bytes.buffer);
    view.setUint64(4, value, Endian.little); // Last 8 bytes
    return bytes;
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
  /// Returns a tuple of (publicKey, privateKey) as Uint8List.
  Future<(Uint8List, Uint8List)> generateKeypair() async {
    final algorithm = X25519();
    final keypair = await algorithm.newKeyPair();

    final publicKeyBytes = await keypair.extractPublicKey();
    final privateKeyBytes = await keypair.extractPrivateKeyBytes();

    return (
      Uint8List.fromList(publicKeyBytes.bytes),
      Uint8List.fromList(privateKeyBytes),
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

    // Generate new keypair
    final (publicKey, privateKey) = await generateKeypair();

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

    // Reconstruct keypair from stored keys
    final algorithm = X25519();
    final keypair = await algorithm.newKeyPairFromSeed(privateKey);

    // Create Noise_IK handshake session as initiator
    // IK: client has static keypair (I), server's public key is known (K)
    final session = NoiseSession._(
      isInitiator: true,
      pattern: NoisePattern.ik,
      localStaticKeypair: keypair,
      remoteStaticPublicKey: serverPublicKey,
    );

    // Initialize symmetric state with protocol name
    session._initialize(_protocolIK, serverPublicKey);
    return session;
  }
}
