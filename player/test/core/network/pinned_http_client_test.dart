import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/network/pinned_http_client.dart';
import 'package:player/core/network/cert_verifier.dart';
import 'package:player/core/auth/cert_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PinnedHttpClient', () {
    late CertStorage certStorage;
    late CertVerifier certVerifier;
    const testInstanceId = 'https://test.example.com';

    setUp(() {
      certStorage = CertStorage();
      certVerifier = CertVerifier();
    });

    tearDown(() async {
      await certStorage.clearAll();
    });

    group('createClient with allowUnknown=false', () {
      test('rejects certificate when no fingerprint stored', () async {
        final pinnedClient = PinnedHttpClient();
        final client = await pinnedClient.createClient(testInstanceId);

        try {
          // Try connecting to HTTPS server
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          // Should reject the connection
          fail('Should have thrown HandshakeException');
        } on HandshakeException {
          // Expected - certificate was rejected
          expect(true, isTrue);
        } finally {
          client.close();
        }
      });

      test('accepts certificate when fingerprint matches', () async {
        // First, get a certificate and store its fingerprint
        final setupClient = HttpClient();
        X509Certificate? cert;

        setupClient.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request =
              await setupClient.getUrl(Uri.parse('https://google.com'));
          await request.close();
        } finally {
          setupClient.close();
        }

        // Store the fingerprint
        await certVerifier.trustCertificate(cert!, testInstanceId);

        // Now create a pinned client and try to connect
        final pinnedClient = PinnedHttpClient();
        final client = await pinnedClient.createClient(testInstanceId);

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          final response = await request.close();

          // Should succeed because fingerprint matches
          expect(response.statusCode, isNotNull);
        } finally {
          client.close();
        }
      });

      test('rejects certificate when fingerprint does not match', () async {
        // Store a fingerprint for a different certificate
        await certStorage.storeFingerprint(
          testInstanceId,
          'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb',
        );

        final pinnedClient = PinnedHttpClient();
        final client = await pinnedClient.createClient(testInstanceId);

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          fail('Should have thrown HandshakeException');
        } on HandshakeException {
          // Expected - fingerprint mismatch
          expect(true, isTrue);
        } finally {
          client.close();
        }
      });
    });

    group('createClient with allowUnknown=true', () {
      test('accepts certificate on first connection', () async {
        final pinnedClient = PinnedHttpClient();
        final client = await pinnedClient.createClient(
          testInstanceId,
          allowUnknown: true,
        );

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          final response = await request.close();

          // Should succeed even without stored fingerprint
          expect(response.statusCode, isNotNull);
        } finally {
          client.close();
        }
      });

      test('still validates fingerprint if one is stored', () async {
        // Store a mismatched fingerprint
        await certStorage.storeFingerprint(
          testInstanceId,
          'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb',
        );

        final pinnedClient = PinnedHttpClient();
        final client = await pinnedClient.createClient(
          testInstanceId,
          allowUnknown: true,
        );

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          fail('Should have thrown HandshakeException');
        } on HandshakeException {
          // Expected - allowUnknown only affects missing fingerprints
          expect(true, isTrue);
        } finally {
          client.close();
        }
      });
    });

    group('computeFingerprint', () {
      test('delegates to CertVerifier.computeFingerprint', () async {
        final client = HttpClient();
        X509Certificate? cert;

        client.badCertificateCallback = (c, host, port) {
          cert = c;
          return true;
        };

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          await request.close();

          final fp1 = PinnedHttpClient.computeFingerprint(cert!);
          final fp2 = CertVerifier.computeFingerprint(cert!);

          expect(fp1, equals(fp2),
              reason: 'Should delegate to CertVerifier');
        } finally {
          client.close();
        }
      });
    });

    group('TOFU workflow integration', () {
      test('allows first connection, then enforces pinning', () async {
        X509Certificate? capturedCert;

        // Step 1: First connection with allowUnknown=true
        // We need a setup client to capture the certificate first
        final setupClient = HttpClient();
        setupClient.badCertificateCallback = (cert, host, port) {
          capturedCert = cert;
          return true;
        };

        try {
          final request =
              await setupClient.getUrl(Uri.parse('https://google.com'));
          await request.close();
        } finally {
          setupClient.close();
        }

        expect(capturedCert, isNotNull,
            reason: 'Should capture certificate');

        // User would see TOFU dialog here and trust the certificate
        await certVerifier.trustCertificate(capturedCert!, testInstanceId);

        // Step 2: Subsequent connection with allowUnknown=false (default)
        final pinnedClient = PinnedHttpClient();
        final client = await pinnedClient.createClient(testInstanceId);

        try {
          final request = await client.getUrl(Uri.parse('https://google.com'));
          final response = await request.close();

          // Should succeed because fingerprint is now stored
          expect(response.statusCode, isNotNull);
        } finally {
          client.close();
        }
      });
    });
  });
}
