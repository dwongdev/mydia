import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/crypto/noise_ik.dart';
import 'package:player/vendor/noise_protocol_framework/noise_protocol_framework.dart'
    as noise;

void main() {
  group('NoiseIK Adapter', () {
    test('initiator and responder complete handshake', () async {
      // Generate responder's static key pair.
      final responderStatic = await noise.KeyPair.generate();

      // Create initiator (knows responder's public key).
      final initiator = await NoiseIK.initiator(
        rs: responderStatic.publicKey,
      );

      // Create responder.
      final responder = await NoiseIK.responder(
        s: responderStatic,
      );

      // Initiator writes handshake message 1.
      final msg1Payload = Uint8List.fromList('init-hello'.codeUnits);
      final msg1Frame = await initiator.writeHandshake(msg1Payload);

      // Responder reads handshake message 1.
      final msg1Received = await responder.readHandshakeResponder(msg1Frame);
      expect(msg1Received, equals(msg1Payload));

      // Responder writes handshake message 2.
      final msg2Payload = Uint8List.fromList('resp-hello'.codeUnits);
      final msg2Frame = await responder.writeHandshakeResponder(msg2Payload);

      // Initiator reads handshake message 2.
      final msg2Received = await initiator.readHandshake(msg2Frame);
      expect(msg2Received, equals(msg2Payload));

      // Verify handshake hashes match.
      expect(initiator.handshakeHash, isNotNull);
      expect(responder.handshakeHash, isNotNull);
      expect(initiator.handshakeHash, equals(responder.handshakeHash));
    });

    test('transport encrypt/decrypt after handshake', () async {
      final responderStatic = await noise.KeyPair.generate();

      final initiator =
          await NoiseIK.initiator(rs: responderStatic.publicKey);
      final responder = await NoiseIK.responder(s: responderStatic);

      // Complete handshake.
      final msg1 = await initiator.writeHandshake(Uint8List(0));
      await responder.readHandshakeResponder(msg1);
      final msg2 = await responder.writeHandshakeResponder(Uint8List(0));
      await initiator.readHandshake(msg2);

      // Initiator encrypts -> responder decrypts.
      final plaintext1 = Uint8List.fromList('secret message 1'.codeUnits);
      final ciphertext1 = initiator.encrypt(plaintext1);
      final decrypted1 = responder.decrypt(ciphertext1);
      expect(decrypted1, equals(plaintext1));

      // Responder encrypts -> initiator decrypts.
      final plaintext2 = Uint8List.fromList('secret message 2'.codeUnits);
      final ciphertext2 = responder.encrypt(plaintext2);
      final decrypted2 = initiator.decrypt(ciphertext2);
      expect(decrypted2, equals(plaintext2));
    });

    test('transport with associated data', () async {
      final responderStatic = await noise.KeyPair.generate();

      final initiator =
          await NoiseIK.initiator(rs: responderStatic.publicKey);
      final responder = await NoiseIK.responder(s: responderStatic);

      // Complete handshake.
      final msg1 = await initiator.writeHandshake(Uint8List(0));
      await responder.readHandshakeResponder(msg1);
      final msg2 = await responder.writeHandshakeResponder(Uint8List(0));
      await initiator.readHandshake(msg2);

      // Encrypt with AD.
      final plaintext = Uint8List.fromList('authenticated message'.codeUnits);
      final ad = Uint8List.fromList('channel:api'.codeUnits);
      final ciphertext = initiator.encrypt(plaintext, ad: ad);

      // Decrypt with same AD.
      final decrypted = responder.decrypt(ciphertext, ad: ad);
      expect(decrypted, equals(plaintext));
    });

    test('wrong AD causes decryption failure', () async {
      final responderStatic = await noise.KeyPair.generate();

      final initiator =
          await NoiseIK.initiator(rs: responderStatic.publicKey);
      final responder = await NoiseIK.responder(s: responderStatic);

      // Complete handshake.
      final msg1 = await initiator.writeHandshake(Uint8List(0));
      await responder.readHandshakeResponder(msg1);
      final msg2 = await responder.writeHandshakeResponder(Uint8List(0));
      await initiator.readHandshake(msg2);

      // Encrypt with AD.
      final plaintext = Uint8List.fromList('secret'.codeUnits);
      final ad1 = Uint8List.fromList('correct-ad'.codeUnits);
      final ciphertext = initiator.encrypt(plaintext, ad: ad1);

      // Decrypt with wrong AD should fail (MAC check fails).
      final ad2 = Uint8List.fromList('wrong-ad'.codeUnits);
      expect(
        () => responder.decrypt(ciphertext, ad: ad2),
        throwsA(anything),
      );
    });

    test('prologue binding works', () async {
      final responderStatic = await noise.KeyPair.generate();
      final prologue = Uint8List.fromList('mydia-session-123'.codeUnits);

      final initiator = await NoiseIK.initiator(
        rs: responderStatic.publicKey,
        prologue: prologue,
      );
      final responder = await NoiseIK.responder(
        s: responderStatic,
        prologue: prologue,
      );

      // Complete handshake.
      final msg1 = await initiator.writeHandshake(Uint8List(0));
      await responder.readHandshakeResponder(msg1);
      final msg2 = await responder.writeHandshakeResponder(Uint8List(0));
      await initiator.readHandshake(msg2);

      // Handshake should succeed with matching prologue.
      expect(initiator.handshakeHash, equals(responder.handshakeHash));
    });

    test('rekey updates cipher state', () async {
      final responderStatic = await noise.KeyPair.generate();

      final initiator =
          await NoiseIK.initiator(rs: responderStatic.publicKey);
      final responder = await NoiseIK.responder(s: responderStatic);

      // Complete handshake.
      final msg1 = await initiator.writeHandshake(Uint8List(0));
      await responder.readHandshakeResponder(msg1);
      final msg2 = await responder.writeHandshakeResponder(Uint8List(0));
      await initiator.readHandshake(msg2);

      // Send a message before rekey.
      final plaintext1 = Uint8List.fromList('before rekey'.codeUnits);
      final ct1 = initiator.encrypt(plaintext1);
      final dec1 = responder.decrypt(ct1);
      expect(dec1, equals(plaintext1));

      // Both sides rekey their TX/RX.
      await initiator.rekeyTx();
      await responder.rekeyRx();

      // Message after rekey should still work.
      final plaintext2 = Uint8List.fromList('after rekey'.codeUnits);
      final ct2 = initiator.encrypt(plaintext2);
      final dec2 = responder.decrypt(ct2);
      expect(dec2, equals(plaintext2));
    });

    test('initiator static key is exposed', () async {
      final responderStatic = await noise.KeyPair.generate();

      final initiator =
          await NoiseIK.initiator(rs: responderStatic.publicKey);

      // Initiator should have a public key.
      expect(initiator.localStaticPublicKey, isNotNull);
      expect(initiator.localStaticPublicKey.length, equals(32));
    });

    test('custom initiator static key is used', () async {
      final responderStatic = await noise.KeyPair.generate();
      final initiatorStatic = await noise.KeyPair.generate();

      final initiator = await NoiseIK.initiator(
        rs: responderStatic.publicKey,
        s: initiatorStatic,
      );

      // Should use the provided key.
      expect(
          initiator.localStaticPublicKey, equals(initiatorStatic.publicKey));
    });
  });
}
