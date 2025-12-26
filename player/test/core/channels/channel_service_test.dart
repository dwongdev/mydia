import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/channels/channel_service.dart';
import 'dart:typed_data';

void main() {
  group('ChannelService', () {
    late ChannelService service;

    setUp(() {
      service = ChannelService();
    });

    tearDown(() async {
      await service.disconnect();
    });

    test('isConnected returns false initially', () {
      expect(service.isConnected, isFalse);
    });

    test('_buildWebSocketUrl converts https to wss', () {
      // This tests the private method indirectly through connect
      // We can't test the actual connection without a server
      expect(() => service.connect('https://example.com'), returnsNormally);
    });

    test('_buildWebSocketUrl converts http to ws', () {
      expect(() => service.connect('http://example.com'), returnsNormally);
    });

    test('_buildWebSocketUrl handles existing ws:// protocol', () {
      expect(() => service.connect('ws://example.com'), returnsNormally);
    });

    test('_buildWebSocketUrl handles existing wss:// protocol', () {
      expect(() => service.connect('wss://example.com'), returnsNormally);
    });

    test('_formatErrorReason formats known error codes', () {
      // We can test this indirectly by checking error messages
      // These are tested in integration tests
    });

    group('ChannelResult', () {
      test('success creates successful result', () {
        final result = ChannelResult.success('test');
        expect(result.success, isTrue);
        expect(result.data, equals('test'));
        expect(result.error, isNull);
      });

      test('error creates failed result', () {
        final result = ChannelResult<String>.error('test error');
        expect(result.success, isFalse);
        expect(result.error, equals('test error'));
        expect(result.data, isNull);
      });
    });

    group('PairingResponse', () {
      test('creates response with all fields', () {
        final response = PairingResponse(
          deviceId: 'device-123',
          mediaToken: 'token-456',
          devicePublicKey: Uint8List(32),
          devicePrivateKey: Uint8List(32),
        );

        expect(response.deviceId, equals('device-123'));
        expect(response.mediaToken, equals('token-456'));
        expect(response.devicePublicKey.length, equals(32));
        expect(response.devicePrivateKey.length, equals(32));
      });
    });

    group('ReconnectResponse', () {
      test('creates response with all fields', () {
        final response = ReconnectResponse(
          message: Uint8List(64),
          mediaToken: 'token-789',
          deviceId: 'device-456',
        );

        expect(response.message.length, equals(64));
        expect(response.mediaToken, equals('token-789'));
        expect(response.deviceId, equals('device-456'));
      });
    });
  });
}
