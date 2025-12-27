/// Service for reconnecting to a paired Mydia instance after app restart.
///
/// This service implements the reconnection flow using Noise_IK pattern for
/// mutual authentication. It tries direct URLs first, then falls back to relay.
///
/// ## Reconnection Flow
///
/// 1. Load stored credentials (direct URLs, cert fingerprint, server public key)
/// 2. Try each direct URL in order:
///    - Verify certificate fingerprint
///    - Connect to WebSocket
///    - Join reconnect channel
///    - Perform Noise_IK handshake (mutual auth)
/// 3. If all direct URLs fail, fall back to relay tunnel
///
/// ## Usage
///
/// ```dart
/// final service = ReconnectionService();
/// final result = await service.reconnect();
/// if (result.success) {
///   final session = result.data!;
///   // Use session for GraphQL and media requests
/// } else {
///   // Show error, return to pairing flow
/// }
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../auth/auth_storage.dart';
import '../channels/channel_service.dart';
import '../crypto/noise_service.dart';
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

/// Active reconnection session with established Noise channel.
class ReconnectionSession {
  /// The server URL that was successfully connected to.
  final String serverUrl;

  /// The device ID.
  final String deviceId;

  /// The refreshed media access token.
  final String mediaToken;

  /// The established Noise session for transport encryption.
  final NoiseSession noiseSession;

  /// Whether this connection is via relay tunnel (vs direct).
  final bool isRelayConnection;

  const ReconnectionSession({
    required this.serverUrl,
    required this.deviceId,
    required this.mediaToken,
    required this.noiseSession,
    required this.isRelayConnection,
  });
}

/// Service for reconnecting to paired Mydia instances.
///
/// This service manages the reconnection logic after app restart,
/// using the Noise_IK pattern for mutual authentication.
class ReconnectionService {
  ReconnectionService({
    ChannelService? channelService,
    NoiseService? noiseService,
    AuthStorage? authStorage,
    RelayTunnelService? relayTunnelService,
  })  : _channelService = channelService ?? ChannelService(),
        _noiseService = noiseService ?? NoiseService(),
        _authStorage = authStorage ?? getAuthStorage(),
        _relayTunnelService = relayTunnelService;

  final ChannelService _channelService;
  final NoiseService _noiseService;
  final AuthStorage _authStorage;
  final RelayTunnelService? _relayTunnelService;

  /// Connection timeout for each direct URL attempt.
  static const _directUrlTimeout = Duration(seconds: 5);

  /// Reconnects to the paired instance using stored credentials.
  ///
  /// This method tries each stored direct URL in order with a timeout.
  /// If all direct URLs fail, it falls back to relay tunnel if available.
  ///
  /// ## Returns
  ///
  /// A [ReconnectionResult] with an established [ReconnectionSession] on success,
  /// or an error message on failure.
  ///
  /// ## Errors
  ///
  /// - 'Device not paired' - No stored credentials found
  /// - 'Certificate verification failed' - Certificate fingerprint mismatch
  /// - 'All connection attempts failed' - Neither direct nor relay succeeded
  Future<ReconnectionResult> reconnect() async {
    // Load stored credentials
    final credentials = await _loadCredentials();
    if (credentials == null) {
      return ReconnectionResult.error('Device not paired');
    }

    // Try direct URLs first
    for (final url in credentials.directUrls) {
      final result = await _tryDirectConnection(url, credentials);
      if (result.success) {
        return result;
      }
      // Continue to next URL on failure
    }

    // Fall back to relay tunnel if available
    if (_relayTunnelService != null && credentials.instanceId != null) {
      return await _tryRelayConnection(credentials);
    }

    return ReconnectionResult.error(
      'All connection attempts failed. Please check your network connection.',
    );
  }

  /// Tries to connect to a direct URL.
  Future<ReconnectionResult> _tryDirectConnection(
    String url,
    _StoredCredentials credentials,
  ) async {
    try {
      // Set up connection with timeout
      final result = await _connectToDirect(url, credentials)
          .timeout(_directUrlTimeout);
      return result;
    } on TimeoutException {
      return ReconnectionResult.error('Connection timeout for $url');
    } catch (e) {
      return ReconnectionResult.error('Connection failed for $url: $e');
    }
  }

  /// Connects to a direct URL and performs Noise_IK handshake.
  Future<ReconnectionResult> _connectToDirect(
    String url,
    _StoredCredentials credentials,
  ) async {
    try {
      // Step 1: Verify certificate fingerprint if stored
      if (credentials.certFingerprint != null && !kIsWeb) {
        // Certificate verification only applies to non-web platforms
        // Web platforms handle TLS through the browser
        final certVerified =
            await _verifyCertificateForUrl(url, credentials.certFingerprint!);
        if (!certVerified) {
          return ReconnectionResult.error('Certificate verification failed');
        }
      }

      // Step 2: Connect to WebSocket
      final connectResult = await _channelService.connect(url);
      if (!connectResult.success) {
        return ReconnectionResult.error(
          connectResult.error ?? 'Failed to connect',
        );
      }

      // Step 3: Join reconnect channel
      final joinResult = await _channelService.joinReconnectChannel();
      if (!joinResult.success) {
        await _channelService.disconnect();
        return ReconnectionResult.error(
          joinResult.error ?? 'Failed to join reconnect channel',
        );
      }
      final channel = joinResult.data!;

      // Step 4: Perform Noise_IK handshake
      final serverPublicKey = _base64ToBytes(credentials.serverPublicKey);
      final noiseSession =
          await _noiseService.startReconnectHandshake(serverPublicKey);

      // Send handshake message to server
      final handshakeMessage = await noiseSession.writeHandshakeMessage();
      final handshakeResult = await _channelService.sendReconnectHandshake(
        channel,
        handshakeMessage,
      );

      if (!handshakeResult.success) {
        await _channelService.disconnect();
        return ReconnectionResult.error(
          handshakeResult.error ?? 'Handshake failed',
        );
      }

      // Process server's handshake response
      final response = handshakeResult.data!;
      await noiseSession.readHandshakeMessage(response.message);

      if (!noiseSession.isComplete) {
        await _channelService.disconnect();
        return ReconnectionResult.error('Handshake incomplete');
      }

      // Success! Return established session
      return ReconnectionResult.success(
        ReconnectionSession(
          serverUrl: url,
          deviceId: response.deviceId,
          mediaToken: response.mediaToken,
          noiseSession: noiseSession,
          isRelayConnection: false,
        ),
      );
    } catch (e) {
      await _channelService.disconnect();
      return ReconnectionResult.error('Connection error: $e');
    }
  }

  /// Tries to connect via relay tunnel.
  Future<ReconnectionResult> _tryRelayConnection(
    _StoredCredentials credentials,
  ) async {
    if (_relayTunnelService == null || credentials.instanceId == null) {
      return ReconnectionResult.error('Relay connection not available');
    }

    try {
      // Connect to relay tunnel
      final tunnelResult =
          await _relayTunnelService.connectViaRelay(credentials.instanceId!);

      if (!tunnelResult.success) {
        return ReconnectionResult.error(
          tunnelResult.error ?? 'Failed to connect via relay',
        );
      }

      final tunnel = tunnelResult.data!;

      // Perform Noise_IK handshake through tunnel
      final serverPublicKey = _base64ToBytes(credentials.serverPublicKey);
      final noiseSession =
          await _noiseService.startReconnectHandshake(serverPublicKey);

      // Send handshake message through tunnel
      final handshakeMessage = await noiseSession.writeHandshakeMessage();
      tunnel.sendMessage(handshakeMessage);

      // Wait for server response
      final responseMessage = await tunnel.messages.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Handshake response timeout'),
      );

      // Process server's handshake response
      await noiseSession.readHandshakeMessage(responseMessage);

      if (!noiseSession.isComplete) {
        await tunnel.close();
        return ReconnectionResult.error('Handshake incomplete');
      }

      // Extract device ID and media token from response
      // Note: In relay mode, we need to get these from the tunnel info or credentials
      final deviceId = credentials.deviceId;
      final mediaToken = credentials.mediaToken;

      if (deviceId == null || mediaToken == null) {
        await tunnel.close();
        return ReconnectionResult.error('Missing credentials for relay mode');
      }

      // Success! Return established session
      return ReconnectionResult.success(
        ReconnectionSession(
          serverUrl:
              tunnel.info.directUrls.isNotEmpty ? tunnel.info.directUrls.first : '',
          deviceId: deviceId,
          mediaToken: mediaToken,
          noiseSession: noiseSession,
          isRelayConnection: true,
        ),
      );
    } catch (e) {
      return ReconnectionResult.error('Relay connection error: $e');
    }
  }

  /// Verifies the certificate fingerprint for a URL.
  ///
  /// This is a placeholder for actual certificate verification.
  /// In a real implementation, this would:
  /// 1. Establish TLS connection
  /// 2. Extract certificate
  /// 3. Compute fingerprint
  /// 4. Compare with stored fingerprint
  Future<bool> _verifyCertificateForUrl(
    String url,
    String expectedFingerprint,
  ) async {
    // TODO: Implement certificate pinning with actual TLS connection
    // For now, we assume certificate verification passes
    // This requires platform-specific HTTP client with certificate callback

    // On native platforms, we would:
    // 1. Create HttpClient with badCertificateCallback
    // 2. Extract X509Certificate from callback
    // 3. Use CertVerifier.computeFingerprint() to verify

    // For web platform, certificate pinning is not supported
    // as the browser handles TLS

    return true;
  }

  /// Loads stored credentials from auth storage.
  Future<_StoredCredentials?> _loadCredentials() async {
    final serverPublicKey = await _authStorage.read('server_public_key');
    final deviceId = await _authStorage.read('pairing_device_id');
    final mediaToken = await _authStorage.read('pairing_media_token');
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
      directUrls: directUrls,
      certFingerprint: certFingerprint,
      instanceId: instanceId,
    );
  }

  Uint8List _base64ToBytes(String str) {
    return Uint8List.fromList(base64Decode(str));
  }
}

/// Internal class for stored credentials.
class _StoredCredentials {
  final String serverPublicKey;
  final String? deviceId;
  final String? mediaToken;
  final List<String> directUrls;
  final String? certFingerprint;
  final String? instanceId;

  const _StoredCredentials({
    required this.serverPublicKey,
    this.deviceId,
    this.mediaToken,
    required this.directUrls,
    this.certFingerprint,
    this.instanceId,
  });
}
