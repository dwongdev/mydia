import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/network/cert_verifier.dart';
import 'package:player/core/auth/cert_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CertVerifier', () {
    late CertVerifier verifier;
    late CertStorage certStorage;
    const testInstanceId = 'https://test.example.com';

    setUp(() {
      verifier = CertVerifier();
      certStorage = CertStorage();
    });

    tearDown(() async {
      // Clean up stored fingerprints after each test
      await certStorage.clearAll();
    });

    group('computeFingerprint', () {
      test('computes SHA-256 fingerprint in colon-separated hex format',
          () async {
        // Create a mock certificate by connecting to a real HTTPS server
        final client = HttpClient();
        X509Certificate? capturedCert;

        client.badCertificateCallback = (cert, host, port) {
          capturedCert = cert;
          return true; // Accept for testing
        };

        try {
          // Connect to any HTTPS server to get a real certificate
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          expect(capturedCert, isNotNull, reason: 'Should capture certificate');

          final fingerprint = CertVerifier.computeFingerprint(capturedCert!);

          // Verify format: hex bytes separated by colons
          expect(fingerprint, matches(RegExp(r'^[0-9a-f]{2}(:[0-9a-f]{2})+$')),
              reason: 'Fingerprint should be colon-separated hex');

          // SHA-256 produces 32 bytes = 64 hex chars + 31 colons = 95 total
          expect(fingerprint.length, equals(95),
              reason: 'SHA-256 fingerprint should be 95 characters');
        } finally {
          client.close();
        }
      });

      test('produces consistent fingerprints for same certificate', () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          final fp1 = CertVerifier.computeFingerprint(cert!);
          final fp2 = CertVerifier.computeFingerprint(cert!);

          expect(fp1, equals(fp2),
              reason: 'Same certificate should produce same fingerprint');
        } finally {
          client.close();
        }
      });
    });

    group('verifyCertificate', () {
      test('returns verified with firstTime=true when no fingerprint stored',
          () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          final result = await verifier.verifyCertificate(cert!, testInstanceId);

          expect(result.verified, isTrue,
              reason: 'Should be verified on first connection');
          expect(result.firstTime, isTrue,
              reason: 'Should indicate first-time connection');
          expect(result.error, isNull, reason: 'Should have no error');
        } finally {
          client.close();
        }
      });

      test('returns verified when fingerprint matches stored value', () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          // Store the fingerprint first
          await verifier.trustCertificate(cert!, testInstanceId);

          // Verify the same certificate
          final result = await verifier.verifyCertificate(cert!, testInstanceId);

          expect(result.verified, isTrue,
              reason: 'Should verify matching fingerprint');
          expect(result.firstTime, isFalse,
              reason: 'Should not be first time');
          expect(result.error, isNull, reason: 'Should have no error');
        } finally {
          client.close();
        }
      });

      test('returns failed when fingerprint does not match stored value',
          () async {
        // This test uses two different certificates to test mismatch
        X509Certificate? cert1;
        X509Certificate? cert2;

        // Get first certificate
        final client1 = HttpClient();
        client1.badCertificateCallback = (c, host, port) {
          cert1 = c;
          return true;
        };

        try {
          final request = await client1.getUrl(Uri.parse('https://google.com'));
          await request.close();
        } finally {
          client1.close();
        }

        // Store first certificate's fingerprint
        await verifier.trustCertificate(cert1!, testInstanceId);

        // Get second certificate from a different server
        final client2 = HttpClient();
        client2.badCertificateCallback = (c, host, port) {
          cert2 = c;
          return true;
        };

        try {
          final request = await client2.getUrl(Uri.parse('https://github.com'));
          await request.close();
        } finally {
          client2.close();
        }

        // Verify second certificate (should fail)
        final result = await verifier.verifyCertificate(cert2!, testInstanceId);

        expect(result.verified, isFalse,
            reason: 'Should fail on fingerprint mismatch');
        expect(result.firstTime, isFalse,
            reason: 'Should not be first time');
        expect(result.error, isNotNull,
            reason: 'Should have error message');
        expect(result.error, contains('mismatch'),
            reason: 'Error should mention mismatch');
      });
    });

    group('trustCertificate', () {
      test('stores certificate fingerprint for instance', () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          // Trust the certificate
          await verifier.trustCertificate(cert!, testInstanceId);

          // Verify it was stored
          final stored = await verifier.getStoredFingerprint(testInstanceId);
          final expected = CertVerifier.computeFingerprint(cert!);

          expect(stored, equals(expected),
              reason: 'Stored fingerprint should match computed fingerprint');
        } finally {
          client.close();
        }
      });
    });

    group('getStoredFingerprint', () {
      test('returns null when no fingerprint stored', () async {
        final stored = await verifier.getStoredFingerprint(testInstanceId);
        expect(stored, isNull,
            reason: 'Should return null when no fingerprint stored');
      });

      test('returns stored fingerprint when present', () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          await verifier.trustCertificate(cert!, testInstanceId);
          final stored = await verifier.getStoredFingerprint(testInstanceId);

          expect(stored, isNotNull,
              reason: 'Should return stored fingerprint');
        } finally {
          client.close();
        }
      });
    });

    group('clearFingerprint', () {
      test('removes stored fingerprint for instance', () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          // Store and verify it exists
          await verifier.trustCertificate(cert!, testInstanceId);
          var stored = await verifier.getStoredFingerprint(testInstanceId);
          expect(stored, isNotNull, reason: 'Fingerprint should be stored');

          // Clear and verify it's gone
          await verifier.clearFingerprint(testInstanceId);
          stored = await verifier.getStoredFingerprint(testInstanceId);
          expect(stored, isNull,
              reason: 'Fingerprint should be cleared');
        } finally {
          client.close();
        }
      });
    });

    group('formatFingerprint', () {
      test('formats fingerprint with default 16 bytes per line', () {
        const fingerprint =
            'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99';

        final formatted = CertVerifier.formatFingerprint(fingerprint);
        final lines = formatted.split('\n');

        expect(lines.length, equals(2),
            reason: '32 bytes should split into 2 lines');
        expect(lines[0].split(':').length, equals(16),
            reason: 'First line should have 16 bytes');
        expect(lines[1].split(':').length, equals(16),
            reason: 'Second line should have 16 bytes');
      });

      test('formats fingerprint with custom bytes per line', () {
        const fingerprint = 'aa:bb:cc:dd:ee:ff:00:11';

        final formatted = CertVerifier.formatFingerprint(
          fingerprint,
          bytesPerLine: 4,
        );
        final lines = formatted.split('\n');

        expect(lines.length, equals(2),
            reason: '8 bytes with 4 per line = 2 lines');
        expect(lines[0].split(':').length, equals(4),
            reason: 'Each line should have 4 bytes');
      });

      test('handles fingerprint shorter than bytes per line', () {
        const fingerprint = 'aa:bb:cc:dd';

        final formatted = CertVerifier.formatFingerprint(
          fingerprint,
          bytesPerLine: 16,
        );

        expect(formatted, equals(fingerprint),
            reason: 'Short fingerprint should remain on one line');
      });
    });
  });
}
