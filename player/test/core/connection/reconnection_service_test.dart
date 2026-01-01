import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/connection/reconnection_service.dart';

import 'reconnection_service_test.mocks.dart';

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

  // Note: Full integration tests for reconnection with network mocks are
  // better suited for end-to-end tests. The scenarios include:
  //
  // 1. reconnect() with valid credentials and working direct URL
  //    - Should succeed and return session with isRelayConnection=false
  //
  // 2. reconnect() retries multiple direct URLs with timeout
  //    - Should try each URL with 5s timeout before moving to next
  //
  // 3. reconnect() falls back to relay when all direct URLs fail
  //    - Should connect via relay and return session with isRelayConnection=true
  //
  // 4. reconnect() verifies certificate fingerprint before connecting
  //    - Should fail if fingerprint doesn't match (non-web platforms)
  //
  // 5. reconnect() performs Noise_IK handshake for mutual auth
  //    - Should use server public key to verify server identity
  //
  // 6. reconnect() does not attempt relay when no instance_id stored
  //    - Should fail if direct URLs fail and no relay option available
  //
  // 7. reconnect() returns error when all connections fail
  //    - Should include helpful error message about network connectivity
}
