import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crypto/noise_service.dart';
import 'package:pointycastle/export.dart' as pc;

/// Tests to verify the Noise protocol implementation is compatible with Decibel.
///
/// These test vectors were generated from the Elixir Decibel library.
void main() {
  group('Noise Protocol Decibel Compatibility', () {
    test('BLAKE2b hash produces correct output', () {
      // Test vector from Decibel
      // Input: "test"
      // Expected: a71079d42853dea26e453004338670a53814b78137ffbed07603a41d76a483aa9bc33b582f77d30a65e6f29a896c0411f38312e1d66e0bf16386c86a89bea572
      final input = Uint8List.fromList('test'.codeUnits);
      final expected = _hexDecode(
          'a71079d42853dea26e453004338670a53814b78137ffbed07603a41d76a483aa9bc33b582f77d30a65e6f29a896c0411f38312e1d66e0bf16386c86a89bea572');

      final digest = pc.Blake2bDigest(digestSize: 64);
      final output = Uint8List(64);
      digest.update(input, 0, input.length);
      digest.doFinal(output, 0);

      expect(_hexEncode(output), _hexEncode(expected));
    });

    test('HMAC-BLAKE2b produces correct output', () {
      // Test vector from Decibel HKDF trace
      // chaining_key: 64 bytes of 0x01
      // input_key_material: 32 bytes of 0x02
      // Expected temp_key: 68d6f7351c9d0aa5a988cf584fce2c767ec863081d0d824c90b7c16a3b652d1ed8af07b45ea6eacb3a12c430318e11528afeb8f5f507b86447d0ca75098a4a04
      final chainingKey = Uint8List(64)..fillRange(0, 64, 0x01);
      final ikm = Uint8List(32)..fillRange(0, 32, 0x02);
      final expectedTempKey = _hexDecode(
          '68d6f7351c9d0aa5a988cf584fce2c767ec863081d0d824c90b7c16a3b652d1ed8af07b45ea6eacb3a12c430318e11528afeb8f5f507b86447d0ca75098a4a04');

      final hmac = pc.HMac(pc.Blake2bDigest(digestSize: 64), 128);
      hmac.init(pc.KeyParameter(chainingKey));
      hmac.update(ikm, 0, ikm.length);
      final output = Uint8List(64);
      hmac.doFinal(output, 0);

      expect(_hexEncode(output), _hexEncode(expectedTempKey));
    });

    test('HKDF produces correct outputs', () {
      // Test vector from Decibel HKDF trace
      final chainingKey = Uint8List(64)..fillRange(0, 64, 0x01);
      final ikm = Uint8List(32)..fillRange(0, 32, 0x02);

      // Expected outputs from Decibel:
      final expectedOutput1 = _hexDecode(
          '12c4352c487964a39209817dc1f3a007a0d46ca33334d4a860fd773ac5dc462c37dfeaa45b8b38a14b7f416a9107ea18e15700c2de4a105e6607be1964ce0184');
      final expectedOutput2 = _hexDecode(
          'c9b08b41c790d5ccfb34c7575440ff38aa6daebdf57cc8caf802d7588be685b103a8b67a866c7193734491c3f6ca839d82f80844f7ee827c8db71540f039c317');

      // Compute HKDF
      final tempKey = _hmacBlake2b(chainingKey, ikm);
      final output1 = _hmacBlake2b(tempKey, Uint8List.fromList([0x01]));
      final output2Input = Uint8List.fromList([...output1, 0x02]);
      final output2 = _hmacBlake2b(tempKey, output2Input);

      expect(_hexEncode(output1), _hexEncode(expectedOutput1));
      expect(_hexEncode(output2), _hexEncode(expectedOutput2));
    });

    test('Protocol name initialization matches Decibel', () {
      // From Decibel test vectors:
      // Protocol: Noise_NK_25519_ChaChaPoly_BLAKE2b
      // Initial h (padded): 4e6f6973655f4e4b5f32353531395f436861436861506f6c795f424c414b45326200000000000000000000000000000000000000000000000000000000000000
      final protocolName = 'Noise_NK_25519_ChaChaPoly_BLAKE2b';
      final expectedInitialHash = _hexDecode(
          '4e6f6973655f4e4b5f32353531395f436861436861506f6c795f424c414b45326200000000000000000000000000000000000000000000000000000000000000');

      final protocolBytes = Uint8List.fromList(protocolName.codeUnits);
      final hash = Uint8List(64);
      hash.setRange(0, protocolBytes.length, protocolBytes);
      hash.fillRange(protocolBytes.length, 64, 0);

      expect(_hexEncode(hash), _hexEncode(expectedInitialHash));
    });

    test('MixHash with server public key matches Decibel', () {
      // From Decibel test vectors:
      // Server public key: 7373489852ee269e4c0deb4dbf2e161653425854b4740aad1cd6219d37c7aa3d
      // After mixing: f9250624c1aa326b0a8d4541b01905dc7e7de9c051d944bc2e387e06df52c64f8081da03aa32cfa8f2a227e0420086bfb1f4636e1e3a0bcfd06fe0866f7d8649
      final serverPublicKey = _hexDecode(
          '7373489852ee269e4c0deb4dbf2e161653425854b4740aad1cd6219d37c7aa3d');
      final initialHash = _hexDecode(
          '4e6f6973655f4e4b5f32353531395f436861436861506f6c795f424c414b45326200000000000000000000000000000000000000000000000000000000000000');
      final expectedAfterMix = _hexDecode(
          'f9250624c1aa326b0a8d4541b01905dc7e7de9c051d944bc2e387e06df52c64f8081da03aa32cfa8f2a227e0420086bfb1f4636e1e3a0bcfd06fe0866f7d8649');

      // MixHash: h = HASH(h || data)
      final combined = Uint8List.fromList([...initialHash, ...serverPublicKey]);
      final digest = pc.Blake2bDigest(digestSize: 64);
      final newHash = Uint8List(64);
      digest.update(combined, 0, combined.length);
      digest.doFinal(newHash, 0);

      expect(_hexEncode(newHash), _hexEncode(expectedAfterMix));
    });

    test('NK handshake first message format matches Decibel', () async {
      // From Decibel test vectors with known ephemeral key:
      // Server public key: 7373489852ee269e4c0deb4dbf2e161653425854b4740aad1cd6219d37c7aa3d
      // Client ephemeral private key: b0eaad5f66cd50961f0644250a35221ce393e6a06a5e656428b946f18d698670
      // Client ephemeral public key: fe532b90e3b561692fdef0091f171ad2796c3bc47c380b582acd95405d1baf12
      //
      // Client's first message (48 bytes): fe532b90e3b561692fdef0091f171ad2796c3bc47c380b582acd95405d1baf12dc459aadd4ef56aa744ae78afc6a905d
      // - First 32 bytes: ephemeral public key
      // - Last 16 bytes: encrypted empty payload + auth tag

      final serverPublicKey = _hexDecode(
          '7373489852ee269e4c0deb4dbf2e161653425854b4740aad1cd6219d37c7aa3d');
      final expectedEphemeralPublic = _hexDecode(
          'fe532b90e3b561692fdef0091f171ad2796c3bc47c380b582acd95405d1baf12');

      // We can't easily test with a fixed ephemeral key since NoiseService generates it internally.
      // But we can verify the message structure:
      // - Total length should be 48 bytes (32 bytes ephemeral + 16 bytes auth tag for empty payload)
      final service = NoiseService();
      final session = await service.startPairingHandshake(serverPublicKey);
      final message = await session.writeHandshakeMessage();

      // Verify message length: 32 (ephemeral) + 16 (encrypted empty payload + tag) = 48
      expect(message.length, 48,
          reason: 'NK first message should be 48 bytes');

      // Verify the ephemeral key is valid (32 bytes)
      final ephemeralKey = message.sublist(0, 32);
      expect(ephemeralKey.length, 32);

      // Verify the remaining bytes (encrypted payload + auth tag) is 16 bytes
      final encryptedPayload = message.sublist(32);
      expect(encryptedPayload.length, 16,
          reason: 'Encrypted empty payload should be 16 bytes (auth tag only)');
    });
  });
}

/// Helper function to decode hex string to Uint8List.
Uint8List _hexDecode(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

/// Helper function to encode Uint8List to hex string.
String _hexEncode(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// HMAC-BLAKE2b helper for testing.
Uint8List _hmacBlake2b(Uint8List key, Uint8List data) {
  final hmac = pc.HMac(pc.Blake2bDigest(digestSize: 64), 128);
  hmac.init(pc.KeyParameter(key));
  hmac.update(data, 0, data.length);
  final output = Uint8List(64);
  hmac.doFinal(output, 0);
  return output;
}
