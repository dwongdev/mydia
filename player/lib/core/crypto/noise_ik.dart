library noise_ik;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../../vendor/noise_protocol_framework/noise_protocol_framework.dart'
    as noise;

/// Protocol name for Noise IK with X25519, ChaCha20-Poly1305, and SHA256.
const _protocolName = 'Noise_IK_25519_ChaChaPoly_SHA256';

/// Minimal adapter surface for Noise IK handshake and transport.
///
/// Implements the IK pattern:
///   <- s
///   ...
///   -> e, es, s, ss
///   <- e, ee, se
///
/// The initiator knows the responder's static public key ahead of time.
/// The initiator also has a static key pair that is encrypted and sent
/// in message 1.
class NoiseIK {
  NoiseIK._(this._protocol, this._localStatic);

  final noise.NoiseProtocol _protocol;
  final noise.KeyPair _localStatic;

  /// Transport cipher for sending (cipher2 for initiator after handshake).
  noise.CipherState get _tx => _protocol.cipher2;

  /// Transport cipher for receiving (cipher1 for initiator after handshake).
  noise.CipherState get _rx => _protocol.cipher1;

  /// The handshake hash after completion. Can be used for channel binding.
  Uint8List? get handshakeHash => _protocol.handshakeHash;

  /// Creates an IK initiator.
  ///
  /// [rs] is the responder's static public key (known ahead of time, 32 bytes).
  /// [s] is an optional initiator static key pair; if not provided, a new
  ///     ephemeral static key pair is generated.
  /// [prologue] is optional data to bind to the handshake transcript.
  static Future<NoiseIK> initiator({
    required Uint8List rs,
    noise.KeyPair? s,
    Uint8List? prologue,
  }) async {
    // Generate initiator static key pair if not provided.
    final localStatic = s ?? await noise.KeyPair.generate();

    final protocol = noise.NoiseProtocol.getIKInitiator(
      localStatic,
      rs,
      noise.NoiseHash(sha256),
      prologue: prologue,
    );

    protocol.initialize(_defaultCipherState(), _protocolName);

    return NoiseIK._(protocol, localStatic);
  }

  /// Creates an IK responder.
  ///
  /// [s] is the responder's static key pair.
  /// [prologue] is optional data to bind to the handshake transcript.
  static Future<NoiseIK> responder({
    required noise.KeyPair s,
    Uint8List? prologue,
  }) async {
    final protocol = noise.NoiseProtocol.getIKResponder(
      s,
      noise.NoiseHash(sha256),
      prologue: prologue,
    );

    protocol.initialize(_defaultCipherState(), _protocolName);

    return NoiseIK._(protocol, s);
  }

  static noise.CipherState _defaultCipherState() {
    return noise.CipherState.empty();
  }

  /// The local static public key.
  Uint8List get localStaticPublicKey => _localStatic.publicKey;

  /// Writes the first handshake message (initiator -> responder).
  ///
  /// For IK pattern: -> e, es, s, ss
  /// Returns the serialized message: ne || encrypted_s || ciphertext
  Future<Uint8List> writeHandshake(Uint8List payload) async {
    final msg = await _protocol.sendMessage(payload);
    return Uint8List.fromList([...msg.ne, ...msg.ns, ...msg.cipherText]);
  }

  /// Reads a handshake message.
  ///
  /// For initiator reading message 2: <- e, ee, se
  /// [frame] is the serialized message.
  /// [neLen] is the length of the ephemeral public key (32 for X25519).
  /// [nsLen] is the length of the encrypted static key (0 for message 2).
  Future<Uint8List> readHandshake(
    Uint8List frame, {
    int neLen = 32,
    int nsLen = 0,
  }) async {
    final ne = frame.sublist(0, neLen);
    final ns = nsLen > 0 ? frame.sublist(neLen, neLen + nsLen) : Uint8List(0);
    final ct = frame.sublist(neLen + nsLen);
    final msg = noise.MessageBuffer(ne, ns, ct);
    return _protocol.readMessage(msg);
  }

  /// Reads the first handshake message (responder side).
  ///
  /// For IK pattern message 1: -> e, es, s, ss
  /// [frame] is the serialized message.
  /// [neLen] is the length of the ephemeral public key (32 for X25519).
  /// [nsLen] is the length of the encrypted static key (32 + 16 tag = 48).
  Future<Uint8List> readHandshakeResponder(
    Uint8List frame, {
    int neLen = 32,
    int nsLen = 48,
  }) async {
    return readHandshake(frame, neLen: neLen, nsLen: nsLen);
  }

  /// Writes the second handshake message (responder -> initiator).
  ///
  /// For IK pattern: <- e, ee, se
  Future<Uint8List> writeHandshakeResponder(Uint8List payload) async {
    final msg = await _protocol.sendMessage(payload);
    // Message 2 has no encrypted static (ns is empty).
    return Uint8List.fromList([...msg.ne, ...msg.cipherText]);
  }

  /// Encrypts a transport message after handshake completion.
  ///
  /// [plaintext] is the data to encrypt.
  /// [ad] is optional associated data for AEAD.
  Uint8List encrypt(Uint8List plaintext, {Uint8List? ad}) {
    return _tx.encryptWithAd(ad ?? Uint8List(0), plaintext);
  }

  /// Decrypts a transport message after handshake completion.
  ///
  /// [ciphertext] is the encrypted data.
  /// [ad] is optional associated data for AEAD (must match encryption).
  Uint8List decrypt(Uint8List ciphertext, {Uint8List? ad}) {
    return _rx.decryptWithAd(ad ?? Uint8List(0), ciphertext);
  }

  /// Triggers rekeying on the send cipher.
  Future<void> rekeyTx() async {
    await _tx.reKey();
  }

  /// Triggers rekeying on the receive cipher.
  Future<void> rekeyRx() async {
    await _rx.reKey();
  }
}
