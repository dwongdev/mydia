part of '../noise_protocol_framework.dart';

/// A class that represents a response in the Noise Protocol Framework.
class NoiseResponse {
  final MessageBuffer message;
  final CipherState cipher1;
  final CipherState cipher2;
  Uint8List h;

  /// Creates a new `NoiseResponse` instance.
  NoiseResponse(this.message, this.cipher1, this.cipher2, this.h);
}

/// An interface that represents a handshake state in the Noise Protocol Framework.
///
/// This implementation is specialized for X25519 key exchange.
abstract class IHandshakeState {
  /// Reads a message from the responder and returns the payload.
  Future<Uint8List> readMessageResponder(MessageBuffer message);

  /// Writes a message to the responder and returns the response.
  Future<NoiseResponse> writeMessageResponder(Uint8List payload);

  /// Reads a message from the initiator and returns the response.
  Future<NoiseResponse> readMessageInitiator(MessageBuffer message);

  /// Writes a message to the initiator and returns the message buffer.
  Future<MessageBuffer> writeMessageInitiator(Uint8List payload);

  /// Initializes the handshake state with the given cipher state and name.
  void init(CipherState cipherState, String name);

  final bool _isInitiator;

  Uint8List? _handshakeHash;

  Uint8List? get handshakeHash => _handshakeHash;

  /// Creates a new `IHandshakeState` instance with the given initiator flag.
  IHandshakeState(this._isInitiator);
}
