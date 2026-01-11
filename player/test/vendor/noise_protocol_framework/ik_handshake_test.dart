import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:player/vendor/noise_protocol_framework/noise_protocol_framework.dart';

void main() {
  group('IK Handshake', () {
    CipherState createCipherState() => CipherState.empty();

    test('completes handshake successfully', () async {
      // Generate responder's static key pair.
      final responderStatic = await KeyPair.generate();

      // Create initiator with responder's public key.
      final initiatorStatic = await KeyPair.generate();
      final initiator = NoiseProtocol.getIKInitiator(
        initiatorStatic,
        responderStatic.publicKey,
        NoiseHash(sha256),
      );
      initiator.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Create responder.
      final responder = NoiseProtocol.getIKResponder(
        responderStatic,
        NoiseHash(sha256),
      );
      responder.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Initiator writes message 1.
      final msg1Payload = Uint8List.fromList('hello from initiator'.codeUnits);
      final msg1 = await initiator.sendMessage(msg1Payload);

      // Responder reads message 1.
      final msg1Received = await responder.readMessage(msg1);
      expect(msg1Received, equals(msg1Payload));

      // Responder writes message 2.
      final msg2Payload = Uint8List.fromList('hello from responder'.codeUnits);
      final msg2 = await responder.sendMessage(msg2Payload);

      // Initiator reads message 2.
      final msg2Received = await initiator.readMessage(msg2);
      expect(msg2Received, equals(msg2Payload));

      // Both sides should have matching handshake hashes.
      expect(initiator.handshakeHash, isNotNull);
      expect(responder.handshakeHash, isNotNull);
      expect(initiator.handshakeHash, equals(responder.handshakeHash));
    });

    test('transport messages work after handshake', () async {
      final responderStatic = await KeyPair.generate();
      final initiatorStatic = await KeyPair.generate();

      final initiator = NoiseProtocol.getIKInitiator(
        initiatorStatic,
        responderStatic.publicKey,
        NoiseHash(sha256),
      );
      initiator.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      final responder = NoiseProtocol.getIKResponder(
        responderStatic,
        NoiseHash(sha256),
      );
      responder.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Complete handshake.
      final msg1 = await initiator.sendMessage(Uint8List(0));
      await responder.readMessage(msg1);
      final msg2 = await responder.sendMessage(Uint8List(0));
      await initiator.readMessage(msg2);

      // Send transport messages (initiator -> responder).
      final transportPayload1 =
          Uint8List.fromList('transport message 1'.codeUnits);
      final encrypted1 = await initiator.sendMessage(transportPayload1);
      final decrypted1 = await responder.readMessage(encrypted1);
      expect(decrypted1, equals(transportPayload1));

      // Send transport messages (responder -> initiator).
      final transportPayload2 =
          Uint8List.fromList('transport message 2'.codeUnits);
      final encrypted2 = await responder.sendMessage(transportPayload2);
      final decrypted2 = await initiator.readMessage(encrypted2);
      expect(decrypted2, equals(transportPayload2));
    });

    test('handshake with prologue binds correctly', () async {
      final responderStatic = await KeyPair.generate();
      final initiatorStatic = await KeyPair.generate();
      final prologue = Uint8List.fromList('mydia-v1'.codeUnits);

      final initiator = NoiseProtocol.getIKInitiator(
        initiatorStatic,
        responderStatic.publicKey,
        NoiseHash(sha256),
        prologue: prologue,
      );
      initiator.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      final responder = NoiseProtocol.getIKResponder(
        responderStatic,
        NoiseHash(sha256),
        prologue: prologue,
      );
      responder.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Complete handshake.
      final msg1 = await initiator.sendMessage(Uint8List(0));
      await responder.readMessage(msg1);
      final msg2 = await responder.sendMessage(Uint8List(0));
      await initiator.readMessage(msg2);

      // Handshake hashes should match and include prologue binding.
      expect(initiator.handshakeHash, equals(responder.handshakeHash));
    });

    test('mismatched prologue causes decryption failure', () async {
      final responderStatic = await KeyPair.generate();
      final initiatorStatic = await KeyPair.generate();

      final initiator = NoiseProtocol.getIKInitiator(
        initiatorStatic,
        responderStatic.publicKey,
        NoiseHash(sha256),
        prologue: Uint8List.fromList('prologue-a'.codeUnits),
      );
      initiator.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      final responder = NoiseProtocol.getIKResponder(
        responderStatic,
        NoiseHash(sha256),
        prologue: Uint8List.fromList('prologue-b'.codeUnits),
      );
      responder.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Initiator sends message 1.
      final msg1 = await initiator.sendMessage(Uint8List(0));

      // Responder should fail to decrypt (mismatched transcript).
      // The MAC check fails because the transcript hash differs.
      expect(
        () async => await responder.readMessage(msg1),
        throwsA(anything),
      );
    });

    test('wrong responder static key causes handshake failure', () async {
      final responderStatic = await KeyPair.generate();
      final wrongStatic = await KeyPair.generate();
      final initiatorStatic = await KeyPair.generate();

      // Initiator thinks responder has wrongStatic.
      final initiator = NoiseProtocol.getIKInitiator(
        initiatorStatic,
        wrongStatic.publicKey,
        NoiseHash(sha256),
      );
      initiator.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Responder uses actual responderStatic.
      final responder = NoiseProtocol.getIKResponder(
        responderStatic,
        NoiseHash(sha256),
      );
      responder.initialize(
          createCipherState(), 'Noise_IK_25519_ChaChaPoly_SHA256');

      // Initiator sends message 1.
      final msg1 = await initiator.sendMessage(Uint8List(0));

      // Responder should fail to decrypt (wrong DH result).
      // The MAC check fails because the DH-derived key differs.
      expect(
        () async => await responder.readMessage(msg1),
        throwsA(anything),
      );
    });
  });
}
