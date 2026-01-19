part of '../../noise_protocol_framework.dart';

/// IK handshake pattern implementation.
///
/// Pattern definition:
///   IK:
///     <- s
///     ...
///     -> e, es, s, ss
///     <- e, ee, se
///
/// Pre-message: Initiator knows responder's static public key.
/// Message 1 (I→R): Initiator sends ephemeral, does DH(e,rs), sends encrypted
///   static, does DH(s,rs).
/// Message 2 (R→I): Responder sends ephemeral, does DH(e,re) and DH(s,re).
class IKHandshakeState extends IHandshakeState {
  late SymmetricState _symmetricState;
  final NoiseHash _hash;

  /// Initiator's ephemeral key pair (generated during handshake).
  late KeyPair _e;

  /// Remote ephemeral public key (received during handshake).
  late Uint8List _re;

  /// Local static key pair (initiator or responder).
  final KeyPair _s;

  /// Remote static public key (known to initiator pre-handshake, learned by
  /// responder from message 1).
  Uint8List? _rs;

  /// Optional prologue data mixed into handshake hash.
  final Uint8List? prologue;

  /// Creates an IK responder state.
  ///
  /// [s] is the responder's static key pair.
  /// [hash] is the hash function (e.g., SHA256).
  /// [prologue] is optional data to bind to the handshake.
  IKHandshakeState.responder(
    this._s,
    this._hash, {
    this.prologue,
  })  : _rs = null,
        super(false);

  /// Creates an IK initiator state.
  ///
  /// [s] is the initiator's static key pair.
  /// [rs] is the responder's static public key (known ahead of time).
  /// [hash] is the hash function (e.g., SHA256).
  /// [prologue] is optional data to bind to the handshake.
  IKHandshakeState.initiator(
    this._s,
    Uint8List rs,
    this._hash, {
    this.prologue,
  })  : _rs = Uint8List.fromList(rs),
        super(true);

  @override
  void init(CipherState cipherState, String name) {
    _symmetricState = SymmetricState.initializeSymmetricState(
      Uint8List.fromList(name.codeUnits),
      _hash,
      cipherState,
    );

    // Mix prologue if provided.
    if (prologue != null) {
      _symmetricState.mixHash(prologue!);
    }

    // Pre-message: <- s (responder's static is known to initiator).
    // Both sides mix the responder's static public key into the hash.
    if (_isInitiator) {
      // Initiator knows rs.
      _symmetricState.mixHash(_rs!);
    } else {
      // Responder uses own static public key.
      _symmetricState.mixHash(_s.publicKey);
    }
  }

  // ---------------------------------------------------------------------------
  // Initiator operations
  // ---------------------------------------------------------------------------

  /// Initiator writes message 1: -> e, es, s, ss
  @override
  Future<MessageBuffer> writeMessageInitiator(Uint8List payload) async {
    // Generate ephemeral key pair.
    _e = await KeyPair.generate();
    final ne = _e.publicKey;

    // -> e: Mix ephemeral public key into hash.
    _symmetricState.mixHash(ne);

    // -> es: DH(e, rs) - ephemeral private with remote static.
    final dhEsResult = await _e.computeDH(_rs!);
    await _symmetricState.mixKey(dhEsResult);

    // -> s: Encrypt and send initiator's static public key.
    final encryptedS = _symmetricState.encryptAndHash(_s.publicKey);

    // -> ss: DH(s, rs) - static private with remote static.
    final dhSsResult = await _s.computeDH(_rs!);
    await _symmetricState.mixKey(dhSsResult);

    // Encrypt payload.
    final ciphertext = _symmetricState.encryptAndHash(payload);

    return MessageBuffer(ne, encryptedS, ciphertext);
  }

  /// Initiator reads message 2: <- e, ee, se
  @override
  Future<NoiseResponse> readMessageInitiator(MessageBuffer message) async {
    // <- e: Receive responder's ephemeral public key.
    _re = message.ne;
    _symmetricState.mixHash(_re);

    // <- ee: DH(e, re) - our ephemeral with their ephemeral.
    final dhEeResult = await _e.computeDH(_re);
    await _symmetricState.mixKey(dhEeResult);

    // <- se: DH(s, re) - our static with their ephemeral.
    final dhSeResult = await _s.computeDH(_re);
    await _symmetricState.mixKey(dhSeResult);

    // Decrypt payload.
    final plaintext = _symmetricState.decryptAndHash(message.cipherText);

    // Split to get transport cipher states.
    final ciphers = await _symmetricState.split();

    _handshakeHash = _symmetricState.h;
    return NoiseResponse(
      MessageBuffer(Uint8List(0), Uint8List(0), plaintext),
      ciphers[0],
      ciphers[1],
      _symmetricState.h,
    );
  }

  // ---------------------------------------------------------------------------
  // Responder operations
  // ---------------------------------------------------------------------------

  /// Responder reads message 1: -> e, es, s, ss
  @override
  Future<Uint8List> readMessageResponder(MessageBuffer message) async {
    // -> e: Receive initiator's ephemeral public key.
    _re = message.ne;
    _symmetricState.mixHash(_re);

    // -> es: DH(s, re) - our static with their ephemeral.
    final dhEsResult = await _s.computeDH(_re);
    await _symmetricState.mixKey(dhEsResult);

    // -> s: Decrypt initiator's static public key.
    _rs = _symmetricState.decryptAndHash(message.ns);

    // -> ss: DH(s, rs) - our static with their static.
    final dhSsResult = await _s.computeDH(_rs!);
    await _symmetricState.mixKey(dhSsResult);

    // Decrypt payload.
    return _symmetricState.decryptAndHash(message.cipherText);
  }

  /// Responder writes message 2: <- e, ee, se
  @override
  Future<NoiseResponse> writeMessageResponder(Uint8List payload) async {
    // Generate ephemeral key pair.
    _e = await KeyPair.generate();
    final ne = _e.publicKey;

    // <- e: Mix ephemeral public key into hash.
    _symmetricState.mixHash(ne);

    // <- ee: DH(e, re) - our ephemeral with their ephemeral.
    final dhEeResult = await _e.computeDH(_re);
    await _symmetricState.mixKey(dhEeResult);

    // <- se: DH(e, rs) - our ephemeral with their static.
    final dhSeResult = await _e.computeDH(_rs!);
    await _symmetricState.mixKey(dhSeResult);

    // Encrypt payload.
    final ciphertext = _symmetricState.encryptAndHash(payload);

    // Split to get transport cipher states.
    final ciphers = await _symmetricState.split();

    _handshakeHash = _symmetricState.h;
    return NoiseResponse(
      MessageBuffer(ne, Uint8List(0), ciphertext),
      ciphers[0],
      ciphers[1],
      _symmetricState.h,
    );
  }
}
