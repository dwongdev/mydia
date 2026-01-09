import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'dart:typed_data';

// Mock implementations would go here for full testing
// For now, we test the basic structure and validation

void main() {
  // Initialize Flutter bindings for tests that use platform channels
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PairingService', () {
    // Note: Tests that require FlutterSecureStorage are skipped because
    // they need mock implementations. These tests verify the data structures
    // and basic logic that doesn't require platform channels.

    group('PairingResult', () {
      test('success creates successful result', () {
        final credentials = PairingCredentials(
          serverUrl: 'https://example.com',
          deviceId: 'device-123',
          mediaToken: 'media-token-456',
          accessToken: 'access-token-789',
          devicePublicKey: Uint8List(32),
          devicePrivateKey: Uint8List(32),
          serverPublicKey: Uint8List(32),
          directUrls: ['https://example.com'],
        );
        final result = PairingResult.success(credentials);
        expect(result.success, isTrue);
        expect(result.credentials, equals(credentials));
        expect(result.error, isNull);
      });

      test('error creates failed result', () {
        final result = PairingResult.error('test error');
        expect(result.success, isFalse);
        expect(result.error, equals('test error'));
        expect(result.credentials, isNull);
      });
    });

    group('PairingCredentials', () {
      test('creates credentials with all fields', () {
        final credentials = PairingCredentials(
          serverUrl: 'https://mydia.example.com',
          deviceId: 'device-abc',
          mediaToken: 'media-token-xyz',
          accessToken: 'access-token-abc',
          devicePublicKey: Uint8List(32),
          devicePrivateKey: Uint8List(32),
          serverPublicKey: Uint8List(32),
          directUrls: ['https://mydia.example.com', 'https://192.168.1.100:4000'],
          certFingerprint: 'AA:BB:CC:DD:EE:FF',
          instanceName: 'My Mydia',
          instanceId: 'instance-123',
        );

        expect(credentials.serverUrl, equals('https://mydia.example.com'));
        expect(credentials.deviceId, equals('device-abc'));
        expect(credentials.mediaToken, equals('media-token-xyz'));
        expect(credentials.accessToken, equals('access-token-abc'));
        expect(credentials.devicePublicKey.length, equals(32));
        expect(credentials.devicePrivateKey.length, equals(32));
        expect(credentials.serverPublicKey.length, equals(32));
        expect(credentials.directUrls.length, equals(2));
        expect(credentials.certFingerprint, equals('AA:BB:CC:DD:EE:FF'));
        expect(credentials.instanceName, equals('My Mydia'));
        expect(credentials.instanceId, equals('instance-123'));
      });
    });
  });
}
