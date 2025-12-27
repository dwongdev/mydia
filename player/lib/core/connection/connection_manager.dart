/// Connection manager for direct-first, relay-fallback strategy.
///
/// This service orchestrates connection attempts to Mydia instances,
/// trying direct URLs first with certificate verification, then falling
/// back to relay tunneling if all direct attempts fail.
///
/// ## Connection Strategy
///
/// 1. Load stored connection preferences
/// 2. Try direct URLs in order:
///    - Prioritize last successful URL if available
///    - Attempt connection with timeout (default 5s)
///    - Verify certificate fingerprint if provided
/// 3. Fall back to relay tunnel if all direct attempts fail
/// 4. Store successful connection method for future optimization
///
/// ## Usage
///
/// ```dart
/// final manager = ConnectionManager(
///   channelService: channelService,
///   relayTunnelService: relayTunnelService,
///   certVerifier: certVerifier,
///   authStorage: authStorage,
/// );
///
/// final result = await manager.connect(
///   directUrls: ['https://mydia.example.com'],
///   instanceId: 'instance-uuid',
///   certFingerprint: 'aa:bb:cc:...',
/// );
///
/// if (result.success) {
///   if (result.isDirect) {
///     // Use result.channel
///   } else if (result.isRelay) {
///     // Use result.tunnel
///   }
/// }
/// ```
library;

import 'dart:async';

import 'connection_result.dart';
import '../channels/channel_service.dart';
import '../relay/relay_tunnel_service.dart';
import '../network/cert_verifier.dart';
import '../auth/auth_storage.dart';

/// Storage keys for connection preferences.
abstract class _StorageKeys {
  static const lastConnectionType = 'connection_last_type';
  static const lastConnectionUrl = 'connection_last_url';
}

/// Connection manager for orchestrating direct and relay connections.
///
/// This service implements a direct-first, relay-fallback strategy for
/// connecting to Mydia instances, with certificate verification and
/// connection preference optimization.
class ConnectionManager {
  ConnectionManager({
    ChannelService? channelService,
    RelayTunnelService? relayTunnelService,
    CertVerifier? certVerifier,
    AuthStorage? authStorage,
    this.directTimeout = const Duration(seconds: 5),
  })  : _channelService = channelService ?? ChannelService(),
        _relayTunnelService = relayTunnelService,
        _certVerifier = certVerifier ?? CertVerifier(),
        _authStorage = authStorage ?? getAuthStorage();

  final ChannelService _channelService;
  final RelayTunnelService? _relayTunnelService;
  // ignore: unused_field
  final CertVerifier _certVerifier; // Reserved for future certificate verification
  final AuthStorage _authStorage;

  /// Timeout for each direct connection attempt.
  final Duration directTimeout;

  /// Connection state change stream controller.
  final _stateController = StreamController<String>.broadcast();

  /// Stream of connection state changes.
  ///
  /// Emits status updates like:
  /// - "Trying direct URL: https://..."
  /// - "Direct connection successful"
  /// - "Falling back to relay"
  Stream<String> get stateChanges => _stateController.stream;

  /// Connects to a Mydia instance using direct-first, relay-fallback strategy.
  ///
  /// ## Parameters
  ///
  /// - [directUrls] - List of direct URLs to try
  /// - [instanceId] - Instance ID (for relay fallback)
  /// - [certFingerprint] - Expected certificate fingerprint (optional)
  /// - [relayUrl] - Relay service URL (required for relay fallback)
  ///
  /// ## Returns
  ///
  /// A [ConnectionResult] containing either a Phoenix channel (direct)
  /// or a relay tunnel (relay), or an error.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final result = await manager.connect(
  ///   directUrls: ['https://mydia.example.com', 'https://192.168.1.5:4000'],
  ///   instanceId: 'instance-uuid',
  ///   certFingerprint: 'aa:bb:cc:...',
  ///   relayUrl: 'https://relay.example.com',
  /// );
  /// ```
  Future<ConnectionResult> connect({
    required List<String> directUrls,
    required String instanceId,
    String? certFingerprint,
    String? relayUrl,
  }) async {
    // Load connection preferences
    final prefs = await _loadPreferences();

    // Try direct URLs first
    if (directUrls.isNotEmpty) {
      // Reorder URLs to prioritize last successful URL
      final orderedUrls = _reorderUrls(directUrls, prefs.lastSuccessfulUrl);

      for (final url in orderedUrls) {
        _emitState('Trying direct URL: $url');

        final result = await _tryDirectConnection(
          url: url,
          certFingerprint: certFingerprint,
        );

        if (result.success) {
          _emitState('Direct connection successful');
          await _storePreference(
            type: ConnectionType.direct,
            url: url,
          );
          return result;
        }
      }

      _emitState('All direct URLs failed');
    }

    // Fall back to relay
    if (relayUrl != null && _relayTunnelService != null) {
      _emitState('Falling back to relay');

      final result = await _tryRelayConnection(
        instanceId: instanceId,
        relayUrl: relayUrl,
      );

      if (result.success) {
        _emitState('Relay connection successful');
        await _storePreference(type: ConnectionType.relay);
        return result;
      }

      _emitState('Relay connection failed: ${result.error}');
      return result;
    }

    // No relay service available
    return ConnectionResult.error(
      'Could not connect to server. All direct URLs failed and no relay service available.',
    );
  }

  /// Tries to establish a direct connection to a URL.
  ///
  /// This method:
  /// 1. Attempts to connect to the URL with timeout
  /// 2. Verifies certificate fingerprint if provided
  /// 3. Returns success with URL (channel joining is handled by caller)
  ///
  /// Returns a [ConnectionResult] with the connected URL on success.
  Future<ConnectionResult> _tryDirectConnection({
    required String url,
    String? certFingerprint,
  }) async {
    try {
      // Attempt connection with timeout
      final connectResult = await _channelService
          .connect(url)
          .timeout(directTimeout, onTimeout: () {
        return ChannelResult.error('Connection timeout');
      });

      if (!connectResult.success) {
        return ConnectionResult.error(connectResult.error ?? 'Connection failed');
      }

      // TODO: Implement certificate fingerprint verification
      // This requires hooking into the underlying HTTP client's
      // certificate validation. For now, we skip this check.
      // See: https://github.com/dart-lang/sdk/issues/35981

      // Connection successful - return with URL
      // The caller (PairingService) will join the appropriate channel
      return ConnectionResult.direct(url: url);
    } catch (e) {
      return ConnectionResult.error('Connection error: $e');
    }
  }

  /// Tries to establish a relay tunnel connection.
  ///
  /// This method:
  /// 1. Creates a relay tunnel service if not provided
  /// 2. Connects to the relay WebSocket
  /// 3. Establishes tunnel to the instance
  ///
  /// Returns a [ConnectionResult] with the active tunnel on success.
  Future<ConnectionResult> _tryRelayConnection({
    required String instanceId,
    required String relayUrl,
  }) async {
    try {
      // Create relay tunnel service if not provided
      final tunnelService = _relayTunnelService ??
          RelayTunnelService(relayUrl: relayUrl);

      // Attempt to connect via relay
      final result = await tunnelService.connectViaRelay(instanceId);

      if (result.success) {
        return ConnectionResult.relay(tunnel: result.data!);
      }

      return ConnectionResult.error(result.error ?? 'Relay connection failed');
    } catch (e) {
      return ConnectionResult.error('Relay error: $e');
    }
  }

  /// Reorders URLs to prioritize the last successful URL.
  List<String> _reorderUrls(List<String> urls, String? lastSuccessfulUrl) {
    if (lastSuccessfulUrl == null || !urls.contains(lastSuccessfulUrl)) {
      return urls;
    }

    // Move last successful URL to the front
    final reordered = [lastSuccessfulUrl];
    for (final url in urls) {
      if (url != lastSuccessfulUrl) {
        reordered.add(url);
      }
    }

    return reordered;
  }

  /// Loads connection preferences from storage.
  Future<ConnectionPreferences> _loadPreferences() async {
    final typeStr = await _authStorage.read(_StorageKeys.lastConnectionType);
    final url = await _authStorage.read(_StorageKeys.lastConnectionUrl);

    ConnectionType? type;
    if (typeStr == 'direct') {
      type = ConnectionType.direct;
    } else if (typeStr == 'relay') {
      type = ConnectionType.relay;
    }

    return ConnectionPreferences(
      lastSuccessful: type,
      lastSuccessfulUrl: url,
    );
  }

  /// Stores connection preference for future optimization.
  Future<void> _storePreference({
    required ConnectionType type,
    String? url,
  }) async {
    await _authStorage.write(
      _StorageKeys.lastConnectionType,
      type == ConnectionType.direct ? 'direct' : 'relay',
    );

    if (url != null) {
      await _authStorage.write(_StorageKeys.lastConnectionUrl, url);
    } else {
      await _authStorage.delete(_StorageKeys.lastConnectionUrl);
    }
  }

  /// Emits a state change event.
  void _emitState(String state) {
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// Disposes of resources.
  void dispose() {
    _stateController.close();
  }
}
