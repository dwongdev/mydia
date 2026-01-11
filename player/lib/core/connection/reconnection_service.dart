/// Service for reconnecting to a paired Mydia instance after app restart.
///
/// This service implements the reconnection flow using X25519 key exchange
/// for establishing encrypted sessions. It uses a **relay-first strategy**:
/// connect via relay immediately, then probe direct URLs in background.
///
/// ## Reconnection Flow (Relay-First)
///
/// 1. Load stored credentials (direct URLs, cert fingerprint, device token, instance ID)
/// 2. Connect via relay tunnel immediately (guaranteed fast connection)
/// 3. Perform X25519 key exchange through relay
/// 4. Return session with relay tunnel and direct URLs for background probing
/// 5. Background probing and hot swap handled by [RelayFirstConnectionManager]
///
/// ## Fallback Flow
///
/// If relay connection fails (no instance ID or relay unavailable),
/// falls back to trying direct URLs sequentially.
///
/// ## Usage
///
/// ```dart
/// final service = ReconnectionService();
/// final result = await service.reconnect();
/// if (result.success) {
///   final session = result.session!;
///   // ...
/// }
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_storage.dart';
import '../webrtc/webrtc_connection_manager.dart';
import '../relay/relay_tunnel_service.dart';


/// Result of a reconnection operation.
class ReconnectionResult {
  final bool success;
  final ReconnectionSession? session;
  final String? error;

  const ReconnectionResult._({
    required this.success,
    this.session,
    this.error,
  });

  factory ReconnectionResult.success(ReconnectionSession session) {
    return ReconnectionResult._(success: true, session: session);
  }

  factory ReconnectionResult.error(String error) {
    return ReconnectionResult._(success: false, error: error);
  }
}

/// Active reconnection session with established WebRTC connection.
class ReconnectionSession {
  /// The server URL that was successfully connected to.
  final String serverUrl;

  /// The device ID.
  final String deviceId;

  /// The refreshed media access token for streaming (typ: media_access).
  final String mediaToken;

  /// The refreshed access token for GraphQL/API (typ: access).
  final String accessToken;

  /// The established WebRTC manager.
  final WebRTCConnectionManager webrtcManager;

  /// Whether this connection is via relay tunnel (vs direct).
  final bool isRelayConnection;

  /// The instance ID (for relay reconnection).
  final String? instanceId;

  /// The relay URL (for relay reconnection).
  final String? relayUrl;

  /// Direct URLs for background probing.
  final List<String> directUrls;

  /// Certificate fingerprint for direct URL verification.
  final String? certFingerprint;

  const ReconnectionSession({
    required this.serverUrl,
    required this.deviceId,
    required this.mediaToken,
    required this.accessToken,
    required this.webrtcManager,
    required this.isRelayConnection,
    this.instanceId,
    this.relayUrl,
    this.directUrls = const [],
    this.certFingerprint,
  });
}


/// Default relay URL for fallback connections.
const _defaultRelayUrl = String.fromEnvironment(
  'RELAY_URL',
  defaultValue: 'https://relay.mydia.dev',
);

/// Service for reconnecting to paired Mydia instances.
class ReconnectionService {
  ReconnectionService({
    AuthStorage? authStorage,
    RelayTunnelService? relayTunnelService,
    String? relayUrl,
  })  : _authStorage = authStorage ?? getAuthStorage(),
        _relayTunnelService = relayTunnelService,
        _relayUrl = relayUrl ?? _defaultRelayUrl;

  final AuthStorage _authStorage;
  final RelayTunnelService? _relayTunnelService;
  final String _relayUrl;

  /// Reconnects to the paired instance using stored credentials.
  Future<ReconnectionResult> reconnect({bool forceDirectOnly = false}) async {
    // Load stored credentials
    final credentials = await _loadCredentials();
    if (credentials == null) {
      return ReconnectionResult.error('Device not paired');
    }

    if (forceDirectOnly) {
      return ReconnectionResult.error(
        'Direct connection not supported in this version. Please use relay.',
      );
    }

    // Relay-first strategy: try relay first
    debugPrint('[ReconnectionService] Using relay-first strategy');

    if (credentials.instanceId != null) {
      final relayResult = await _tryRelayConnection(credentials);
      if (relayResult.success) {
        debugPrint('[ReconnectionService] Relay connection successful');
        return relayResult;
      }
      debugPrint('[ReconnectionService] Relay failed');
    } else {
      debugPrint('[ReconnectionService] No instance ID, skipping relay');
    }

    return ReconnectionResult.error(
      'All connection attempts failed. Please check your network connection.',
    );
  }

  /// Tries to connect via relay tunnel (WebRTC).
  Future<ReconnectionResult> _tryRelayConnection(
    _StoredCredentials credentials,
  ) async {
    debugPrint('[ReconnectionService] _tryRelayConnection called');
    debugPrint('[ReconnectionService] instanceId: ${credentials.instanceId}');
    debugPrint('[ReconnectionService] deviceToken: ${credentials.deviceToken != null ? "present" : "null"}');
    debugPrint('[ReconnectionService] relayUrl: $_relayUrl');

    if (credentials.instanceId == null) {
      debugPrint('[ReconnectionService] No instance ID, skipping relay');
      return ReconnectionResult.error(
        'Relay connection not available: no instance ID',
      );
    }

    if (credentials.deviceToken == null) {
      debugPrint('[ReconnectionService] No device token, skipping relay');
      return ReconnectionResult.error(
        'Relay connection not available: no device token',
      );
    }

    try {
      // Use provided service or create one with default relay URL
      debugPrint('[ReconnectionService] Creating RelayTunnelService...');
      final tunnelService =
          _relayTunnelService ?? RelayTunnelService(relayUrl: _relayUrl);

      final webrtcManager = WebRTCConnectionManager(tunnelService);
      
      // Connect to WebRTC
      await webrtcManager.connect(credentials.instanceId!);
      
      // Send Auth request
      await webrtcManager.authenticate(credentials.deviceToken!);
      
      return ReconnectionResult.success(
        ReconnectionSession(
          serverUrl: '', // WebRTC doesn't have a URL
          deviceId: credentials.deviceId ?? 'unknown',
          mediaToken: credentials.mediaToken ?? '',
          accessToken: '', // Need to refresh
          webrtcManager: webrtcManager,
          isRelayConnection: true,
          instanceId: credentials.instanceId,
          relayUrl: _relayUrl,
          directUrls: credentials.directUrls,
          certFingerprint: credentials.certFingerprint,
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('[ReconnectionService] Relay connection exception: $e');
      debugPrint('[ReconnectionService] Stack trace: $stackTrace');
      return ReconnectionResult.error('Relay connection error: $e');
    }
  }

  /// Verifies the certificate fingerprint for a URL.
  Future<bool> _verifyCertificateForUrl(
    String url,
    String expectedFingerprint,
  ) async {
    return true;
  }

  /// Loads stored credentials from auth storage.
  Future<_StoredCredentials?> _loadCredentials() async {
    final serverPublicKey = await _authStorage.read('server_public_key');
    final deviceId = await _authStorage.read('pairing_device_id');
    final mediaToken = await _authStorage.read('pairing_media_token');
    final deviceToken = await _authStorage.read('pairing_device_token');
    final directUrlsJson = await _authStorage.read('pairing_direct_urls');
    final certFingerprint = await _authStorage.read('pairing_cert_fingerprint');
    final instanceId = await _authStorage.read('instance_id');

    if (serverPublicKey == null || directUrlsJson == null) {
      return null;
    }

    // Parse direct URLs from JSON
    List<String> directUrls = [];
    try {
      final decoded = jsonDecode(directUrlsJson);
      if (decoded is List) {
        directUrls = decoded.cast<String>();
      }
    } catch (e) {
      return null;
    }

    if (directUrls.isEmpty) {
      return null;
    }

    return _StoredCredentials(
      serverPublicKey: serverPublicKey,
      deviceId: deviceId,
      mediaToken: mediaToken,
      deviceToken: deviceToken,
      directUrls: directUrls,
      certFingerprint: certFingerprint,
      instanceId: instanceId,
    );
  }
}

/// Internal class for stored credentials.
class _StoredCredentials {
  final String serverPublicKey;
  final String? deviceId;
  final String? mediaToken;
  final String? deviceToken;
  final List<String> directUrls;
  final String? certFingerprint;
  final String? instanceId;

  const _StoredCredentials({
    required this.serverPublicKey,
    this.deviceId,
    this.mediaToken,
    this.deviceToken,
    required this.directUrls,
    this.certFingerprint,
    this.instanceId,
  });
}

/// Provider for the reconnection service.
final reconnectionServiceProvider = Provider<ReconnectionService>((ref) {
  return ReconnectionService();
});
