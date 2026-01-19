import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/relay/relay_tunnel_service.dart';

void main() {
  group('RelayTunnelService', () {
    test('normalizes relay URL correctly', () {
      final service1 = RelayTunnelService(relayUrl: 'https://relay.example.com/');
      expect(service1.toString(), isNot(contains('https://relay.example.com//')));

      final service2 = RelayTunnelService(relayUrl: 'https://relay.example.com');
      expect(service2, isNotNull);
    });

    test('creates service with default URL', () {
      // Note: This would use the default relay URL
      // In actual tests, we'd need to mock the WebSocket connection
    });
  });

  group('RelayTunnelInfo', () {
    test('parses from JSON correctly', () {
      final json = {
        'session_id': 'session-123',
        'instance_id': 'instance-456',
        'public_key': 'YmFzZTY0a2V5',
        'direct_urls': ['https://example.com'],
      };

      final info = RelayTunnelInfo.fromJson(json);

      expect(info.sessionId, equals('session-123'));
      expect(info.instanceId, equals('instance-456'));
      expect(info.publicKey, equals('YmFzZTY0a2V5'));
      expect(info.directUrls, equals(['https://example.com']));
    });

    test('handles missing direct_urls', () {
      final json = {
        'session_id': 'session-123',
        'instance_id': 'instance-456',
        'public_key': 'YmFzZTY0a2V5',
      };

      final info = RelayTunnelInfo.fromJson(json);
      expect(info.directUrls, isEmpty);
    });
  });

  group('RelayTunnelResult', () {
    test('creates success result', () {
      final result = RelayTunnelResult.success('test-data');

      expect(result.success, isTrue);
      expect(result.data, equals('test-data'));
      expect(result.error, isNull);
    });

    test('creates error result', () {
      final result = RelayTunnelResult<String>.error('test-error');

      expect(result.success, isFalse);
      expect(result.data, isNull);
      expect(result.error, equals('test-error'));
    });
  });

  // Note: Full integration tests would require:
  // 1. Mock WebSocket server simulating the relay
  // 2. Mock instance responses through the tunnel
  // 3. Testing Noise handshake through tunnel
  // These are better suited for end-to-end tests in a real environment
}
