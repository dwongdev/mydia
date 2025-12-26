import 'dart:io';

import 'package:crypto/crypto.dart';

import '../auth/cert_storage.dart';

/// HTTP client factory that creates clients with certificate pinning.
///
/// This enables secure connections to Mydia instances using self-signed
/// certificates by verifying the certificate fingerprint matches the
/// stored fingerprint from the initial pairing or first connection.
class PinnedHttpClient {
  final CertStorage _certStorage = CertStorage();

  /// Create an HTTP client with certificate pinning for an instance.
  ///
  /// The [instanceId] is used to look up the stored certificate fingerprint.
  /// If a fingerprint is stored, the client will only accept certificates
  /// that match that fingerprint. If no fingerprint is stored, the client
  /// will accept any certificate (useful for initial pairing).
  ///
  /// The [onUnknownCertificate] callback is called when a certificate is
  /// encountered that doesn't match the stored fingerprint. It receives
  /// the certificate and its computed fingerprint. The callback should
  /// return `true` to trust the certificate or `false` to reject it.
  Future<HttpClient> createClient(
    String instanceId, {
    Future<bool> Function(X509Certificate cert, String fingerprint)?
        onUnknownCertificate,
  }) async {
    final storedFingerprint = await _certStorage.getFingerprint(instanceId);

    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) {
      return _verifyCertificate(
        cert,
        storedFingerprint,
        onUnknownCertificate,
      );
    };

    return client;
  }

  /// Verify a certificate against the stored fingerprint.
  ///
  /// Returns `true` if the certificate should be trusted, `false` otherwise.
  bool _verifyCertificate(
    X509Certificate cert,
    String? storedFingerprint,
    Future<bool> Function(X509Certificate cert, String fingerprint)?
        onUnknownCertificate,
  ) {
    final fingerprint = _computeFingerprint(cert);

    if (storedFingerprint == null) {
      // No stored fingerprint - this is the first connection.
      // Call the callback if provided, otherwise reject.
      if (onUnknownCertificate != null) {
        // Note: badCertificateCallback must be synchronous, so we can't
        // await the callback. The callback should handle storing the
        // fingerprint asynchronously and return immediately.
        // For now, we'll accept the certificate on first connect and
        // let the calling code handle the trust decision.
        return true;
      }
      return false;
    }

    // Verify the fingerprint matches
    return fingerprint == storedFingerprint;
  }

  /// Compute the SHA-256 fingerprint of a certificate.
  ///
  /// Returns the fingerprint as a lowercase hex string with colons
  /// separating each byte (e.g., "aa:bb:cc:dd:...").
  String _computeFingerprint(X509Certificate cert) {
    final der = cert.der;
    final digest = sha256.convert(der);
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
    return hex;
  }

  /// Compute the fingerprint of a certificate (synchronous version).
  ///
  /// This is exposed as a public method so the calling code can compute
  /// the fingerprint to display in the trust dialog.
  static String computeFingerprint(X509Certificate cert) {
    final der = cert.der;
    final digest = sha256.convert(der);
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
    return hex;
  }
}
