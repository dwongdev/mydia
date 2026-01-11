part of 'noise_protocol_framework.dart';

/// A class that represents a cipher state in the Noise Protocol Framework.
///
/// Uses ChaCha20-Poly1305 AEAD cipher.
class CipherState {
  Uint8List _key;
  Uint8List _nonce;

  /// Creates a new `CipherState` instance with an empty key and nonce.
  CipherState.empty()
      : _key = Uint8List(CIPHER_KEY_LENGTH),
        _nonce = Uint8List(8);

  /// Creates a new `CipherState` instance with the given key and nonce.
  CipherState(this._key, this._nonce) {
    assert(_key.length == CIPHER_KEY_LENGTH);
    assert(_nonce.length == 8);
  }

  /// Returns `true` if the cipher state has a non-zero key.
  bool get hasKey {
    for (var b in _key) {
      if (b != 0) return true;
    }
    return false;
  }

  /// Sets the nonce of the cipher state.
  set nonce(Uint8List nonce) {
    assert(nonce.length == 8);
    _nonce = nonce;
  }

  /// Sets the key of the cipher state.
  /// NOTE: nonce will be set to 0.
  set key(Uint8List key) {
    assert(key.length == CIPHER_KEY_LENGTH);
    _key = key;
    nonce = Uint8List(8);
  }

  /// Encrypts the plaintext with the given associated data and returns the ciphertext.
  Uint8List encryptWithAd(Uint8List ad, Uint8List plaintext) {
    if (_nonce.isEqual(MAX_UINT_64_MINUS_ONE)) {
      throw Exception("Nonce overflow");
    }
    Uint8List res = _encrypt(ad, plaintext);
    _nonce.incrementBigEndian();
    return res;
  }

  Uint8List _encrypt(Uint8List ad, Uint8List plaintext, {Uint8List? n}) {
    if (n != null) assert(n.length == 8);
    // Build 12-byte nonce: 4 zero bytes || 8 byte counter
    Uint8List nonce = Uint8List(12);
    nonce.setRange(0, 4, [0, 0, 0, 0]);
    nonce.setAll(4, n ?? _nonce);

    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    cipher.init(true, AEADParameters(KeyParameter(_key), 128, nonce, ad));

    // Output buffer: plaintext + 16 byte MAC
    final outputSize = cipher.getOutputSize(plaintext.length);
    final output = Uint8List(outputSize);

    var len = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    len += cipher.doFinal(output, len);

    return output.sublist(0, len);
  }

  /// Decrypts the ciphertext with the given associated data and returns the plaintext.
  Uint8List decryptWithAd(Uint8List ad, Uint8List ciphertext) {
    if (_nonce.isEqual(MAX_UINT_64_MINUS_ONE)) {
      throw Exception("Nonce overflow");
    }
    Uint8List res = _decrypt(ad, ciphertext);
    _nonce.incrementBigEndian();
    return res;
  }

  Uint8List _decrypt(Uint8List ad, Uint8List ciphertext) {
    // Build 12-byte nonce: 4 zero bytes || 8 byte counter
    Uint8List nonce = Uint8List(12);
    nonce.setRange(4, nonce.length, _nonce);

    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    cipher.init(false, AEADParameters(KeyParameter(_key), 128, nonce, ad));

    // Output buffer: ciphertext - 16 byte MAC
    final outputSize = cipher.getOutputSize(ciphertext.length);
    final output = Uint8List(outputSize);

    var len = cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    len += cipher.doFinal(output, len);

    return output.sublist(0, len);
  }

  /// Generates a new key for the cipher state (Noise Rekey).
  ///
  /// Per Noise spec: REKEY(k) = ENCRYPT(k, maxnonce, zerolen, zeros)
  /// Returns the first 32 bytes of the encryption output.
  Future<void> reKey() async {
    final encrypted =
        _encrypt(Uint8List(0), EMPTY_CIPHER_KEY_LENGTH_BYTES, n: MAX_UINT_64);
    // Take first 32 bytes (key length) from the 48-byte output (32 + 16 MAC).
    _key = encrypted.sublist(0, CIPHER_KEY_LENGTH);
  }

  /// Writes a regular message with the given payload and returns the message buffer.
  MessageBuffer writeMessageRegular(Uint8List payload) {
    Uint8List cipherText = encryptWithAd(Uint8List(0), payload);
    return MessageBuffer(Uint8List(0), Uint8List(0), cipherText);
  }

  /// Reads a regular message from the given message buffer and returns the payload.
  Uint8List readMessageRegular(MessageBuffer message) {
    return decryptWithAd(Uint8List(0), message.cipherText);
  }

  /// Splits the cipher state into two cipher states with the given keys.
  List<CipherState> split(Uint8List key1, Uint8List key2) {
    return [
      CipherState(key1, Uint8List(8)),
      CipherState(key2, Uint8List(8)),
    ];
  }
}
