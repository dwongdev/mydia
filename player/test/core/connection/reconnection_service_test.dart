import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/connection/reconnection_service.dart';
import 'package:player/core/crypto/crypto_manager.dart';

import 'reconnection_service_test.mocks.dart';

/// Fake CryptoManager for testing
class FakeCryptoManager implements CryptoManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

@GenerateMocks([AuthStorage])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Test data
  const testServerPublicKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  const testDeviceId = 'device-123';
  const testMediaToken = 'token-456';
  const testDirectUrls = '["https://mydia.example.com", "https://192.168.1.100:4000"]';
  const testInstanceId = 'instance-789';

  group('ReconnectionService', () {
    group('ReconnectionResult', () {
      test('creates error result', () {
        final result = ReconnectionResult.error('Connection failed');

        expect(result.success, isFalse);
        expect(result.session, isNull);
        expect(result.error, equals('Connection failed'));
      });

      // Note: Success result tests require a valid session. See integration test scenarios below.
    });

    group('credential loading', () {
      late MockAuthStorage mockAuthStorage;

      setUp(() {
        mockAuthStorage = MockAuthStorage();
      });

      test('returns error when device not paired (no credentials)', () async {
        when(mockAuthStorage.read(any)).thenAnswer((_) async => null);

        final service = ReconnectionService(authStorage: mockAuthStorage);
        final result = await service.reconnect();

        expect(result.success, isFalse);
        expect(result.error, equals('Device not paired'));
      });

      test('returns error when server_public_key is missing', () async {
        when(mockAuthStorage.read('server_public_key'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('pairing_direct_urls'))
            .thenAnswer((_) async => testDirectUrls);
        when(mockAuthStorage.read('pairing_device_id'))
            .thenAnswer((_) async => testDeviceId);
        when(mockAuthStorage.read('pairing_media_token'))
            .thenAnswer((_) async => testMediaToken);
        when(mockAuthStorage.read('pairing_device_token'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('pairing_cert_fingerprint'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('instance_id'))
            .thenAnswer((_) async => testInstanceId);

        final service = ReconnectionService(authStorage: mockAuthStorage);
        final result = await service.reconnect();

        expect(result.success, isFalse);
        expect(result.error, equals('Device not paired'));
      });

      test('returns error when direct_urls is empty', () async {
        when(mockAuthStorage.read('server_public_key'))
            .thenAnswer((_) async => testServerPublicKey);
        when(mockAuthStorage.read('pairing_direct_urls'))
            .thenAnswer((_) async => '[]');
        when(mockAuthStorage.read('pairing_device_id'))
            .thenAnswer((_) async => testDeviceId);
        when(mockAuthStorage.read('pairing_media_token'))
            .thenAnswer((_) async => testMediaToken);
        when(mockAuthStorage.read('pairing_device_token'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('pairing_cert_fingerprint'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('instance_id'))
            .thenAnswer((_) async => testInstanceId);

        final service = ReconnectionService(authStorage: mockAuthStorage);
        final result = await service.reconnect();

        expect(result.success, isFalse);
        expect(result.error, equals('Device not paired'));
      });

      test('returns error when direct_urls JSON is malformed', () async {
        when(mockAuthStorage.read('server_public_key'))
            .thenAnswer((_) async => testServerPublicKey);
        when(mockAuthStorage.read('pairing_direct_urls'))
            .thenAnswer((_) async => 'not-valid-json');
        when(mockAuthStorage.read('pairing_device_id'))
            .thenAnswer((_) async => testDeviceId);
        when(mockAuthStorage.read('pairing_media_token'))
            .thenAnswer((_) async => testMediaToken);
        when(mockAuthStorage.read('pairing_device_token'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('pairing_cert_fingerprint'))
            .thenAnswer((_) async => null);
        when(mockAuthStorage.read('instance_id'))
            .thenAnswer((_) async => testInstanceId);

        final service = ReconnectionService(authStorage: mockAuthStorage);
        final result = await service.reconnect();

        expect(result.success, isFalse);
        expect(result.error, equals('Device not paired'));
      });
    });
  });

  group('relay-first strategy', () {
    late MockAuthStorage mockAuthStorage;

    setUp(() {
      mockAuthStorage = MockAuthStorage();
      // Set up complete credentials for relay-first tests
      when(mockAuthStorage.read('server_public_key'))
          .thenAnswer((_) async => testServerPublicKey);
      when(mockAuthStorage.read('pairing_device_id'))
          .thenAnswer((_) async => testDeviceId);
      when(mockAuthStorage.read('pairing_media_token'))
          .thenAnswer((_) async => testMediaToken);
      when(mockAuthStorage.read('pairing_device_token'))
          .thenAnswer((_) async => 'device-token-123');
      when(mockAuthStorage.read('pairing_direct_urls'))
          .thenAnswer((_) async => testDirectUrls);
      when(mockAuthStorage.read('pairing_cert_fingerprint'))
          .thenAnswer((_) async => null);
      when(mockAuthStorage.read('instance_id'))
          .thenAnswer((_) async => testInstanceId);
    });

    test('reconnect uses relay-first by default', () async {
      // This test verifies the parameter default value
      final service = ReconnectionService(authStorage: mockAuthStorage);

      // Without a real relay service, this will fail, but we're testing
      // that it attempts relay first (not direct)
      final result = await service.reconnect();

      // Should fail because no relay service is available, but importantly
      // it should NOT return "Certificate verification failed" which would
      // indicate it tried direct first
      expect(result.success, isFalse);
      expect(result.error, isNot(contains('Certificate verification')));
    });

    test('reconnect with forceDirectOnly skips relay', () async {
      // When forcing direct only, relay should not be attempted
      final service = ReconnectionService(authStorage: mockAuthStorage);

      final result = await service.reconnect(forceDirectOnly: true);

      // Should fail trying direct (no real server)
      expect(result.success, isFalse);
      expect(result.error, contains('Direct connection failed'));
    });

    test('ReconnectionSession includes directUrls', () {
      // Test that ReconnectionSession can store direct URLs for probing
      // Note: cryptoManager is required but we test with a null placeholder
      // In real usage, it would be a valid CryptoManager instance
      expect(
        () => ReconnectionSession(
          serverUrl: 'https://mydia.local',
          deviceId: 'device-123',
          mediaToken: 'media-token-456',
          accessToken: 'access-token-789',
          cryptoManager: FakeCryptoManager(),
          isRelayConnection: true,
          directUrls: const ['https://192.168.1.100:4000', 'https://mydia.local'],
          certFingerprint: 'aa:bb:cc',
        ),
        returnsNormally,
      );
    });

    test('ReconnectionSession includes relay info', () {
      // Test that ReconnectionSession stores relay connection info
      final session = ReconnectionSession(
        serverUrl: 'https://mydia.local',
        deviceId: 'device-123',
        mediaToken: 'media-token-456',
        accessToken: 'access-token-789',
        cryptoManager: FakeCryptoManager(),
        isRelayConnection: true,
        instanceId: 'instance-789',
        relayUrl: 'https://relay.example.com',
        directUrls: const [],
      );

      expect(session.instanceId, equals('instance-789'));
      expect(session.relayUrl, equals('https://relay.example.com'));
    });
  });

  // Note: Full integration tests for reconnection with network mocks are
  // better suited for end-to-end tests. The scenarios include:
  //
  // RELAY-FIRST STRATEGY SCENARIOS:
  //
  // 1. reconnect() tries relay first (default behavior)
  //    - Should attempt relay connection before trying direct URLs
  //    - Should return session with isRelayConnection=true on success
  //
  // 2. reconnect() falls back to direct when relay fails
  //    - Should try direct URLs if relay connection fails
  //    - Should return session with isRelayConnection=false on success
  //
  // 3. reconnect(forceDirectOnly: true) skips relay entirely
  //    - Should only try direct URLs, never relay
  //
  // 4. Successful reconnection includes directUrls for probing
  //    - Session should contain direct URLs for RelayFirstConnectionManager
  //
  // 5. Successful reconnection includes relay info
  //    - Session should contain instanceId and relayUrl for fallback
  //
  // ORIGINAL SCENARIOS:
  //
  // 6. reconnect() with valid credentials and working direct URL
  //    - Should succeed when relay fails and direct works
  //
  // 7. reconnect() verifies certificate fingerprint before connecting
  //    - Should fail if fingerprint doesn't match (non-web platforms)
  //
  // 8. reconnect() performs Noise_IK handshake for mutual auth
  //    - Should use server public key to verify server identity
  //
  // 9. reconnect() does not attempt relay when no instance_id stored
  //    - Should skip relay and try direct URLs only
  //
  // 10. reconnect() returns error when all connections fail
  //     - Should include helpful error message about network connectivity
}
