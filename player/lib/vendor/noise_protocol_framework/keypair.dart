part of 'noise_protocol_framework.dart';

/// A class that represents a key pair in the Noise Protocol Framework.
///
/// This implementation uses the `cryptography` package for X25519.
class KeyPair {
  final Uint8List _publicKey;
  final Uint8List _privateKey;

  /// Creates a new `KeyPair` instance with the given public and private keys.
  KeyPair._(this._publicKey, this._privateKey);

  /// Creates a `KeyPair` from raw bytes.
  ///
  /// [publicKey] is the 32-byte X25519 public key.
  /// [privateKey] is the 32-byte X25519 private key (seed).
  factory KeyPair.fromBytes(Uint8List publicKey, Uint8List privateKey) {
    assert(publicKey.length == 32, 'Public key must be 32 bytes');
    assert(privateKey.length == 32, 'Private key must be 32 bytes');
    return KeyPair._(
      Uint8List.fromList(publicKey),
      Uint8List.fromList(privateKey),
    );
  }

  /// Creates a `KeyPair` from a cryptography SimpleKeyPair.
  static Future<KeyPair> fromSimpleKeyPair(crypto.SimpleKeyPair keyPair) async {
    final publicKeyData = await keyPair.extractPublicKey();
    final privateKeyData = await keyPair.extractPrivateKeyBytes();
    return KeyPair._(
      Uint8List.fromList(publicKeyData.bytes),
      Uint8List.fromList(privateKeyData),
    );
  }

  /// Creates a `KeyPair` from a map with the public key and private key.
  KeyPair.fromMap(Map<String, String> json)
      : this._(
          bytesFromHex(json['publicKey']!),
          bytesFromHex(json['privateKey']!),
        );

  /// Converts the `KeyPair` instance to a map.
  Map<String, String> toMap() => {
        'publicKey': _publicKey.toHex(),
        'privateKey': _privateKey.toHex(),
      };

  /// Returns a copy of the public key (32 bytes).
  Uint8List get publicKey => Uint8List.fromList(_publicKey);

  /// Returns a copy of the private key (32 bytes).
  Uint8List get privateKey => Uint8List.fromList(_privateKey);

  /// Generates a new X25519 `KeyPair`.
  static Future<KeyPair> generate() async {
    final algorithm = crypto.X25519();
    final keyPair = await algorithm.newKeyPair();
    return fromSimpleKeyPair(keyPair as crypto.SimpleKeyPair);
  }

  /// Computes the Diffie-Hellman shared secret.
  ///
  /// [remotePublicKey] is the remote party's 32-byte public key.
  /// Returns the 32-byte shared secret.
  Future<Uint8List> computeDH(Uint8List remotePublicKey) async {
    final algorithm = crypto.X25519();

    // Create our key pair
    final localKeyPair = crypto.SimpleKeyPairData(
      _privateKey,
      publicKey: crypto.SimplePublicKey(_publicKey, type: crypto.KeyPairType.x25519),
      type: crypto.KeyPairType.x25519,
    );

    // Create remote public key
    final remotePubKey = crypto.SimplePublicKey(
      remotePublicKey,
      type: crypto.KeyPairType.x25519,
    );

    // Compute shared secret
    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: remotePubKey,
    );

    return Uint8List.fromList(await sharedSecret.extractBytes());
  }
}
