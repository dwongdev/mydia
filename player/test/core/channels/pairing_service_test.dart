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
          mediaToken: 'token-456',
          devicePublicKey: Uint8List(32),
          devicePrivateKey: Uint8List(32),
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
          mediaToken: 'token-xyz',
          devicePublicKey: Uint8List(32),
          devicePrivateKey: Uint8List(32),
        );

        expect(credentials.serverUrl, equals('https://mydia.example.com'));
        expect(credentials.deviceId, equals('device-abc'));
        expect(credentials.mediaToken, equals('token-xyz'));
        expect(credentials.devicePublicKey.length, equals(32));
        expect(credentials.devicePrivateKey.length, equals(32));
      });
    });
  });
}
