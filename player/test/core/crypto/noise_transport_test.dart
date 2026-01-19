import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydia/core/crypto/noise_transport.dart';

void main() {
  group('NoiseTransport', () {
    test('isTransportMessage identifies valid transport headers', () {
      // Valid API channel message
      final validApi = Uint8List.fromList([1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
      expect(NoiseTransport.isTransportMessage(validApi), isTrue);
      
      // Valid media channel message
      final validMedia = Uint8List.fromList([1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
      expect(NoiseTransport.isTransportMessage(validMedia), isTrue);
      
      // Invalid version
      final invalidVersion = Uint8List.fromList([2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
      expect(NoiseTransport.isTransportMessage(invalidVersion), isFalse);
      
      // Invalid channel
      final invalidChannel = Uint8List.fromList([1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
      expect(NoiseTransport.isTransportMessage(invalidChannel), isFalse);
      
      // Invalid flags
      final invalidFlags = Uint8List.fromList([1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
      expect(NoiseTransport.isTransportMessage(invalidFlags), isFalse);
      
      // Too short
      final tooShort = Uint8List.fromList([1, 1, 0, 0, 0]);
      expect(NoiseTransport.isTransportMessage(tooShort), isFalse);
      
      // Handshake message (random bytes starting with ephemeral key)
      final handshake = Uint8List.fromList([
        0x67, 0xEE, 0x52, 0xD8, // Random bytes (not version 1)
        0xDF, 0x91, 0x07, 0x5C,
        // ... more bytes
      ]);
      expect(NoiseTransport.isTransportMessage(handshake), isFalse);
    });
    
    test('encrypt throws before handshake complete', () async {
      // Create transport without completing handshake
      // We can't easily test this without a server, so just verify the state check
      final serverKey = Uint8List(32); // Dummy key
      final transport = await NoiseTransport.initiator(
        serverPublicKey: serverKey,
        sessionId: 'test-session',
        instanceId: 'test-instance',
      );
      
      expect(transport.isHandshakeComplete, isFalse);
      
      expect(
        () => transport.encrypt(NoiseChannel.api, Uint8List.fromList([1, 2, 3])),
        throwsA(isA<StateError>()),
      );
    });
    
    test('decrypt throws before handshake complete', () async {
      final serverKey = Uint8List(32);
      final transport = await NoiseTransport.initiator(
        serverPublicKey: serverKey,
        sessionId: 'test-session',
        instanceId: 'test-instance',
      );
      
      expect(transport.isHandshakeComplete, isFalse);
      
      final fakeEncrypted = Uint8List.fromList([1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
      expect(
        () => transport.decrypt(fakeEncrypted),
        throwsA(isA<StateError>()),
      );
    });
    
    test('writeHandshake produces message', () async {
      final serverKey = Uint8List(32);
      final transport = await NoiseTransport.initiator(
        serverPublicKey: serverKey,
        sessionId: 'test-session',
        instanceId: 'test-instance',
      );
      
      final msg1 = await transport.writeHandshake();
      
      // IK message 1 should be 96 bytes:
      // 32 (ephemeral) + 48 (encrypted static) + 16 (ciphertext tag for empty payload)
      expect(msg1.length, equals(96));
    });
  });
}
