/// Service for reconnecting to a paired Mydia instance after app restart.
///
/// This service implements the reconnection flow using X25519 key exchange
/// for establishing encrypted sessions. It tries direct URLs first, then
/// falls back to relay.
///
/// ## Reconnection Flow
///
/// 1. Load stored credentials (direct URLs, cert fingerprint, device token)
/// 2. Try each direct URL in order:
///    - Verify certificate fingerprint
///    - Connect to WebSocket
///    - Join reconnect channel
///    - Perform X25519 key exchange
///    - Send encrypted device token for authentication
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
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

import '../auth/auth_storage.dart';
import '../channels/channel_service.dart';
import '../crypto/crypto_manager.dart';
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

/// Active reconnection session with established encrypted channel.
class ReconnectionSession {
  /// The server URL that was successfully connected to.
  final String serverUrl;

  /// The device ID.
  final String deviceId;

  /// The refreshed media access token.
  final String mediaToken;

  /// The established crypto manager for transport encryption.
  final CryptoManager cryptoManager;

  /// Whether this connection is via relay tunnel (vs direct).
  final bool isRelayConnection;

  /// The relay tunnel (only set when [isRelayConnection] is true).
  final RelayTunnel? relayTunnel;

  /// The instance ID (for relay reconnection).
  final String? instanceId;

  /// The relay URL (for relay reconnection).
  final String? relayUrl;

  const ReconnectionSession({
    required this.serverUrl,
    required this.deviceId,
    required this.mediaToken,
    required this.cryptoManager,
    required this.isRelayConnection,
    this.relayTunnel,
    this.instanceId,
    this.relayUrl,
  });
}

/// Default relay URL for fallback connections.
const _defaultRelayUrl = String.fromEnvironment(
  'RELAY_URL',
  defaultValue: 'https://relay.mydia.dev',
);

/// Service for reconnecting to paired Mydia instances.
///
/// This service manages the reconnection logic after app restart,
/// using X25519 key exchange for establishing encrypted sessions.
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

  /// Connection timeout for each direct URL attempt.
  static const _directUrlTimeout = Duration(seconds: 5);

  /// Reconnects to the paired instance using stored credentials.
  ///
  /// This method tries direct URLs or relay based on [preferRelay]:
  /// - If [preferRelay] is true: tries relay first, then falls back to direct
  /// - If [preferRelay] is false (default): tries direct first, then relay
  ///
  /// ## Parameters
  ///
  /// - [preferRelay]: If true, prioritizes relay connection over direct URLs.
  ///   Use this when the stored connection mode was relay to preserve the
  ///   user's connection preference.
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
  Future<ReconnectionResult> reconnect({bool preferRelay = false}) async {
    // Load stored credentials
    final credentials = await _loadCredentials();
    if (credentials == null) {
      return ReconnectionResult.error('Device not paired');
    }

    if (preferRelay) {
      // Try relay first when the stored mode was relay
      debugPrint('[ReconnectionService] Preferring relay mode, trying relay first');
      if (credentials.instanceId != null) {
        final relayResult = await _tryRelayConnection(credentials);
        if (relayResult.success) {
          return relayResult;
        }
        debugPrint('[ReconnectionService] Relay failed, falling back to direct URLs');
      }

      // Fall back to direct URLs
      if (credentials.directUrls.isNotEmpty) {
        final result = await _tryDirectUrlsInParallel(credentials);
        if (result != null && result.success) {
          return result;
        }
      }
    } else {
      // Try direct URLs first (default behavior)
      if (credentials.directUrls.isNotEmpty) {
        final result = await _tryDirectUrlsInParallel(credentials);
        if (result != null && result.success) {
          return result;
        }
      }

      // Fall back to relay tunnel
      if (credentials.instanceId != null) {
        final relayResult = await _tryRelayConnection(credentials);
        if (relayResult.success) {
          return relayResult;
        }
      }
    }

    return ReconnectionResult.error(
      'All connection attempts failed. Please check your network connection.',
    );
  }

  /// Tries all direct URLs in parallel and returns the first successful connection.
  ///
  /// This method races all URL attempts simultaneously:
  /// - All URLs are tried in parallel with individual timeouts
  /// - Returns immediately when the first connection succeeds
  /// - Returns null if all connections fail
  ///
  /// Each parallel attempt uses its own [ChannelService] instance to avoid
  /// conflicts when multiple connections are attempted simultaneously.
  Future<ReconnectionResult?> _tryDirectUrlsInParallel(
    _StoredCredentials credentials,
  ) async {
    final urls = credentials.directUrls;
    if (urls.isEmpty) return null;

    // Create a completer that resolves on first success
    final completer = Completer<ReconnectionResult?>();
    var pendingCount = urls.length;
    final failedChannelServices = <ChannelService>[];

    for (final url in urls) {
      // Create a dedicated ChannelService for each parallel attempt
      final channelService = ChannelService();

      // ignore: unawaited_futures
      _tryDirectConnectionWithService(url, credentials, channelService)
          .then((result) {
        if (completer.isCompleted) {
          // Another attempt already won - clean up this connection
          channelService.disconnect();
          return;
        }

        if (result.success) {
          // This attempt won - disconnect any failed services
          for (final failed in failedChannelServices) {
            failed.disconnect();
          }
          // Update the main channel service to the winning one
          // Note: The caller should use the session, which has its own state
          completer.complete(result);
        } else {
          failedChannelServices.add(channelService);
          pendingCount--;
          if (pendingCount == 0) {
            // All attempts failed - clean up
            for (final failed in failedChannelServices) {
              failed.disconnect();
            }
            completer.complete(null);
          }
        }
      }).catchError((Object e) {
        if (completer.isCompleted) {
          channelService.disconnect();
          return;
        }

        failedChannelServices.add(channelService);
        pendingCount--;
        if (pendingCount == 0) {
          // All attempts failed - clean up
          for (final failed in failedChannelServices) {
            failed.disconnect();
          }
          completer.complete(null);
        }
      });
    }

    return completer.future;
  }

  /// Tries to connect to a direct URL using a specific [ChannelService].
  ///
  /// This variant is used for parallel connection attempts where each
  /// attempt needs its own channel service to avoid conflicts.
  Future<ReconnectionResult> _tryDirectConnectionWithService(
    String url,
    _StoredCredentials credentials,
    ChannelService channelService,
  ) async {
    try {
      final result = await _connectToDirectWithService(
        url,
        credentials,
        channelService,
      ).timeout(_directUrlTimeout);
      return result;
    } on TimeoutException {
      return ReconnectionResult.error('Connection timeout for $url');
    } catch (e) {
      return ReconnectionResult.error('Connection failed for $url: $e');
    }
  }

  /// Connects to a direct URL using a specific [ChannelService].
  ///
  /// This variant is used for parallel connection attempts where each
  /// attempt needs its own channel service to avoid conflicts.
  Future<ReconnectionResult> _connectToDirectWithService(
    String url,
    _StoredCredentials credentials,
    ChannelService channelService,
  ) async {
    try {
      // Step 1: Verify certificate fingerprint if stored
      if (credentials.certFingerprint != null && !kIsWeb) {
        final certVerified =
            await _verifyCertificateForUrl(url, credentials.certFingerprint!);
        if (!certVerified) {
          return ReconnectionResult.error('Certificate verification failed');
        }
      }

      // Step 2: Connect to WebSocket
      final connectResult = await channelService.connect(url);
      if (!connectResult.success) {
        return ReconnectionResult.error(
          connectResult.error ?? 'Failed to connect',
        );
      }

      // Step 3: Join reconnect channel
      final joinResult = await channelService.joinReconnectChannel();
      if (!joinResult.success) {
        await channelService.disconnect();
        return ReconnectionResult.error(
          joinResult.error ?? 'Failed to join reconnect channel',
        );
      }
      final channel = joinResult.data!;

      // Step 4: Perform X25519 key exchange
      final cryptoManager = CryptoManager();
      final clientPublicKey = await cryptoManager.generateKeyPair();

      // Send client public key to server via key_exchange message
      final keyExchangeResult = await channelService.sendKeyExchange(
        channel,
        clientPublicKey,
        credentials.deviceToken!,
      );

      if (!keyExchangeResult.success) {
        cryptoManager.dispose();
        await channelService.disconnect();
        return ReconnectionResult.error(
          keyExchangeResult.error ?? 'Key exchange failed',
        );
      }

      // Derive session key from server's public key
      final response = keyExchangeResult.data!;
      await cryptoManager.deriveSessionKey(response.serverPublicKey);

      // Success! Return established session
      return ReconnectionResult.success(
        ReconnectionSession(
          serverUrl: url,
          deviceId: response.deviceId,
          mediaToken: response.mediaToken,
          cryptoManager: cryptoManager,
          isRelayConnection: false,
        ),
      );
    } catch (e) {
      await channelService.disconnect();
      return ReconnectionResult.error('Connection error: $e');
    }
  }

  /// Tries to connect via relay tunnel.
  Future<ReconnectionResult> _tryRelayConnection(
    _StoredCredentials credentials,
  ) async {
    if (credentials.instanceId == null) {
      return ReconnectionResult.error(
        'Relay connection not available: no instance ID',
      );
    }

    if (credentials.deviceToken == null) {
      return ReconnectionResult.error(
        'Relay connection not available: no device token',
      );
    }

    try {
      // Use provided service or create one with default relay URL
      final tunnelService =
          _relayTunnelService ?? RelayTunnelService(relayUrl: _relayUrl);

      // Connect to relay tunnel
      final tunnelResult =
          await tunnelService.connectViaRelay(credentials.instanceId!);

      if (!tunnelResult.success) {
        return ReconnectionResult.error(
          tunnelResult.error ?? 'Failed to connect via relay',
        );
      }

      final tunnel = tunnelResult.data!;

      // Perform X25519 key exchange through tunnel
      final cryptoManager = CryptoManager();
      final clientPublicKey = await cryptoManager.generateKeyPair();

      // Send key exchange request through tunnel (wrapped in JSON for server)
      final keyExchangeRequest = jsonEncode({
        'type': 'key_exchange',
        'data': {
          'client_public_key': clientPublicKey,
          'device_token': credentials.deviceToken,
        },
      });
      tunnel.sendMessage(Uint8List.fromList(utf8.encode(keyExchangeRequest)));

      // Wait for server response
      final responseBytes = await tunnel.messages.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Key exchange response timeout'),
      );

      // Parse response
      final responseJson =
          jsonDecode(utf8.decode(responseBytes)) as Map<String, dynamic>;

      if (responseJson['type'] == 'error') {
        cryptoManager.dispose();
        await tunnel.close();
        return ReconnectionResult.error(
          responseJson['message'] as String? ?? 'Key exchange failed',
        );
      }

      final serverPublicKey = responseJson['server_public_key'] as String?;
      if (serverPublicKey == null) {
        cryptoManager.dispose();
        await tunnel.close();
        return ReconnectionResult.error('Invalid key exchange response');
      }

      // Derive session key from server's public key
      await cryptoManager.deriveSessionKey(serverPublicKey);

      // Enable encryption on the tunnel for subsequent API calls
      final sessionKeyBytes = await cryptoManager.getSessionKeyBytes();
      if (sessionKeyBytes != null) {
        tunnel.enableEncryption(sessionKeyBytes);
        debugPrint('[ReconnectionService] Encryption enabled on relay tunnel');
      }

      // Extract device ID and media token from response
      final deviceId =
          responseJson['device_id'] as String? ?? credentials.deviceId;
      final mediaToken =
          responseJson['token'] as String? ?? credentials.mediaToken;

      if (deviceId == null || mediaToken == null) {
        cryptoManager.dispose();
        await tunnel.close();
        return ReconnectionResult.error('Missing credentials in relay response');
      }

      // Success! Return established session with the tunnel
      return ReconnectionResult.success(
        ReconnectionSession(
          serverUrl: tunnel.info.directUrls.isNotEmpty
              ? tunnel.info.directUrls.first
              : '',
          deviceId: deviceId,
          mediaToken: mediaToken,
          cryptoManager: cryptoManager,
          isRelayConnection: true,
          relayTunnel: tunnel,
          instanceId: credentials.instanceId,
          relayUrl: _relayUrl,
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
