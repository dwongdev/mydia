library noise_transport;

import 'dart:typed_data';

import 'noise_ik.dart';

/// Wire format constants matching the server implementation.
const int _protocolVersion = 1;
const int _channelApi = 0x01;
const int _channelMedia = 0x02;
const int _flagsNone = 0x00;
const int _headerSize = 11;

/// Rekey threshold: rekey after 2^32 messages.
const int _rekeyThreshold = 4294967296;

/// Channel type for WebRTC data channels.
enum NoiseChannel { api, media }

/// Manages Noise Protocol transport encryption with wire framing.
///
/// Wraps [NoiseIK] and adds the wire format framing used by Mydia's
/// WebRTC E2EE implementation:
///
/// ```
/// || version (1) || channel (1) || flags (1) || counter (8) || ciphertext ||
/// ```
class NoiseTransport {
  NoiseTransport._(this._noise);

  final NoiseIK _noise;
  int _txCounter = 0;
  int _rxCounter = 0;
  bool _handshakeComplete = false;

  /// Creates a new NoiseTransport as the initiator (client side).
  ///
  /// [serverPublicKey] is the server's static public key (32 bytes).
  /// [sessionId] is the WebRTC session ID for prologue binding.
  /// [instanceId] is the Mydia instance ID for prologue binding.
  static Future<NoiseTransport> initiator({
    required Uint8List serverPublicKey,
    required String sessionId,
    required String instanceId,
  }) async {
    // Build prologue: session_id || instance_id || protocol_version
    final prologue = _buildPrologue(sessionId, instanceId);

    final noise = await NoiseIK.initiator(
      rs: serverPublicKey,
      prologue: prologue,
    );

    return NoiseTransport._(noise);
  }

  static Uint8List _buildPrologue(String sessionId, String instanceId) {
    final sessionBytes = Uint8List.fromList(sessionId.codeUnits);
    final instanceBytes = Uint8List.fromList(instanceId.codeUnits);
    final version = Uint8List.fromList([_protocolVersion]);

    return Uint8List.fromList([
      ...sessionBytes,
      ...instanceBytes,
      ...version,
    ]);
  }

  /// Whether the handshake has completed.
  bool get isHandshakeComplete => _handshakeComplete;

  /// The handshake hash for channel binding (available after handshake).
  Uint8List? get handshakeHash => _noise.handshakeHash;

  /// Writes the first handshake message (client -> server).
  ///
  /// Returns the raw handshake message (no framing).
  Future<Uint8List> writeHandshake() async {
    return _noise.writeHandshake(Uint8List(0));
  }

  /// Reads the second handshake message (server -> client).
  ///
  /// [message] is the raw handshake message from the server.
  /// After this call, [isHandshakeComplete] will be true.
  Future<void> readHandshake(Uint8List message) async {
    await _noise.readHandshake(message, neLen: 32, nsLen: 0);
    _handshakeComplete = true;
  }

  /// Encrypts a message with wire framing.
  ///
  /// [channel] specifies which channel the message is for.
  /// [plaintext] is the data to encrypt.
  /// Returns the framed ciphertext: header || encrypted_data.
  Uint8List encrypt(NoiseChannel channel, Uint8List plaintext) {
    if (!_handshakeComplete) {
      throw StateError('Handshake not complete');
    }

    final channelId = channel == NoiseChannel.api ? _channelApi : _channelMedia;
    final counter = _txCounter++;

    // Build header
    final header = _buildHeader(channelId, counter);

    // Encrypt with AD (the header)
    final ciphertext = _noise.encrypt(plaintext, ad: header);

    // Combine header and ciphertext
    return Uint8List.fromList([...header, ...ciphertext]);
  }

  /// Decrypts a framed message.
  ///
  /// [framedCiphertext] is the full framed message (header || ciphertext).
  /// Returns a tuple of (channel, plaintext).
  /// Throws if the message is invalid or replay is detected.
  (NoiseChannel, Uint8List) decrypt(Uint8List framedCiphertext) {
    if (!_handshakeComplete) {
      throw StateError('Handshake not complete');
    }

    final parsed = _parseHeader(framedCiphertext);
    if (parsed == null) {
      throw FormatException('Invalid message header');
    }

    final (channelId, counter, header, ciphertext) = parsed;

    // Replay protection
    if (counter <= _rxCounter && _rxCounter > 0) {
      throw StateError('Replay detected: counter=$counter, last=$_rxCounter');
    }

    // Decrypt with AD (the header)
    final plaintext = _noise.decrypt(ciphertext, ad: header);

    // Update counter
    _rxCounter = counter;

    final channel = channelId == _channelApi ? NoiseChannel.api : NoiseChannel.media;
    return (channel, plaintext);
  }

  /// Checks if a message appears to be encrypted transport (vs handshake).
  static bool isTransportMessage(Uint8List data) {
    if (data.length < _headerSize) return false;
    return data[0] == _protocolVersion &&
        (data[1] == _channelApi || data[1] == _channelMedia) &&
        data[2] == _flagsNone;
  }

  /// Whether the transmit channel needs rekeying.
  bool get needsRekeyTx => _txCounter >= _rekeyThreshold;
  
  /// Whether the receive channel needs rekeying.
  bool get needsRekeyRx => _rxCounter >= _rekeyThreshold;
  
  /// Returns metrics about the transport session.
  Map<String, dynamic> get metrics => {
    'handshakeComplete': _handshakeComplete,
    'txCounter': _txCounter,
    'rxCounter': _rxCounter,
    'needsRekeyTx': needsRekeyTx,
    'needsRekeyRx': needsRekeyRx,
  };

  /// Triggers rekeying on the send cipher.
  Future<void> rekeyTx() async {
    await _noise.rekeyTx();
    _txCounter = 0;
  }

  /// Triggers rekeying on the receive cipher.
  Future<void> rekeyRx() async {
    await _noise.rekeyRx();
    _rxCounter = 0;
  }

  Uint8List _buildHeader(int channelId, int counter) {
    final header = ByteData(11);
    header.setUint8(0, _protocolVersion);
    header.setUint8(1, channelId);
    header.setUint8(2, _flagsNone);
    header.setUint64(3, counter, Endian.big);
    return header.buffer.asUint8List();
  }

  (int, int, Uint8List, Uint8List)? _parseHeader(Uint8List data) {
    if (data.length < _headerSize) return null;

    final version = data[0];
    final channelId = data[1];
    final flags = data[2];

    if (version != _protocolVersion) return null;
    if (channelId != _channelApi && channelId != _channelMedia) return null;
    if (flags != _flagsNone) return null;

    final counterBytes = ByteData.sublistView(data, 3, 11);
    final counter = counterBytes.getUint64(0, Endian.big);

    final header = data.sublist(0, _headerSize);
    final ciphertext = data.sublist(_headerSize);

    return (channelId, counter, header, ciphertext);
  }
}
