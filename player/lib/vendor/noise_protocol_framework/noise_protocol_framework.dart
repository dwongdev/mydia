library noise_protocol_framework;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'constants/noise_constants.dart';
import 'extensions/ext_on_byte_list.dart';
import 'crypto/key_derivation.dart';

part 'protocols/ik/handshake_state.dart';
part 'protocols/handshake_state_interface.dart';
part 'hash.dart';
part 'keypair.dart';
part 'cipher_state.dart';
part 'message_buffer.dart';
part 'symmetric_state.dart';

/// A class that represents a Noise Protocol instance.
///
/// This implementation is specialized for X25519 key exchange.
class NoiseProtocol {
  int _messageCounter;
  final IHandshakeState _handshakeState;
  bool isInitialized = false;

  late CipherState _cipher1;
  late CipherState _cipher2;

  CipherState get cipher1 => _cipher1;
  CipherState get cipher2 => _cipher2;

  Uint8List? get handshakeHash => _handshakeState.handshakeHash;

  /// Creates a new `NoiseProtocol` instance with a custom handshake state.
  NoiseProtocol.custom(this._handshakeState) : _messageCounter = 0;

  /// Creates a new `NoiseProtocol` instance with the IK responder handshake pattern.
  ///
  /// IK pattern: <- s, ... -> e, es, s, ss <- e, ee, se
  ///
  /// [s] is the responder's static key pair.
  /// [hash] is the hash function to use.
  /// [prologue] is an optional byte sequence that is included in the handshake.
  NoiseProtocol.getIKResponder(
    KeyPair s,
    NoiseHash hash, {
    Uint8List? prologue,
  })  : _messageCounter = 0,
        _handshakeState = IKHandshakeState.responder(
          s,
          hash,
          prologue: prologue,
        );

  /// Creates a new `NoiseProtocol` instance with the IK initiator handshake pattern.
  ///
  /// IK pattern: <- s, ... -> e, es, s, ss <- e, ee, se
  ///
  /// [s] is the initiator's static key pair.
  /// [rs] is the responder's static public key (known ahead of time).
  /// [hash] is the hash function to use.
  /// [prologue] is an optional byte sequence that is included in the handshake.
  NoiseProtocol.getIKInitiator(
    KeyPair s,
    Uint8List rs,
    NoiseHash hash, {
    Uint8List? prologue,
  })  : _messageCounter = 0,
        _handshakeState = IKHandshakeState.initiator(
          s,
          rs,
          hash,
          prologue: prologue,
        );

  /// Initializes the `NoiseProtocol` instance with the given cipher state and name.
  ///
  /// [cipherState] is the cipher state to use.
  /// [name] is the name of the protocol, e.g., "Noise_IK_25519_ChaChaPoly_SHA256".
  void initialize(CipherState cipherState, String name) {
    _handshakeState.init(cipherState, name);
    isInitialized = true;
  }

  /// Reads a message from the given message buffer.
  Future<Uint8List> readMessage(MessageBuffer message) async {
    if (!isInitialized) {
      throw Exception("NoiseProtocol is not initialized");
    }
    Uint8List res;
    if (_messageCounter == 0 && !_handshakeState._isInitiator) {
      res = await _handshakeState.readMessageResponder(message);
    } else if (_messageCounter == 1 && _handshakeState._isInitiator) {
      NoiseResponse noiseRes =
          await _handshakeState.readMessageInitiator(message);
      _cipher1 = noiseRes.cipher2;
      _cipher2 = noiseRes.cipher1;
      res = noiseRes.message.cipherText;
    } else if (_messageCounter <= 1) {
      throw Exception("Invalid message counter");
    } else {
      res = _cipher1.readMessageRegular(message);
    }
    _messageCounter++;
    return res;
  }

  /// Sends a message with the given payload.
  Future<MessageBuffer> sendMessage(Uint8List payload) async {
    if (!isInitialized) {
      throw Exception("NoiseProtocol is not initialized");
    }
    MessageBuffer res;
    if (_messageCounter == 1 && !_handshakeState._isInitiator) {
      NoiseResponse writeResponse =
          await _handshakeState.writeMessageResponder(payload);
      _cipher1 = writeResponse.cipher1;
      _cipher2 = writeResponse.cipher2;

      res = writeResponse.message;
    } else if (_messageCounter == 0 && _handshakeState._isInitiator) {
      res = await _handshakeState.writeMessageInitiator(payload);
    } else if (_messageCounter <= 1) {
      throw Exception("Invalid message counter");
    } else {
      res = _cipher2.writeMessageRegular(payload);
    }
    _messageCounter++;
    return res;
  }
}
