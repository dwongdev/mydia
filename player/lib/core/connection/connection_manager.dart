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
import '../relay/relay_tunnel_service.dart';
import '../webrtc/webrtc_connection_manager.dart';
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
    RelayTunnelService? relayTunnelService,
    CertVerifier? certVerifier,
    AuthStorage? authStorage,
    this.directTimeout = const Duration(seconds: 5),
  })  : _relayTunnelService = relayTunnelService,
        _certVerifier = certVerifier ?? CertVerifier(),
        _authStorage = authStorage ?? getAuthStorage();

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

  /// Connects to a Mydia instance using relay-first strategy.
  ///
  /// ## Parameters
  ///
  /// - [directUrls] - List of direct URLs (ignored in WebRTC-only mode)
  /// - [instanceId] - Instance ID (for relay fallback)
  /// - [certFingerprint] - Expected certificate fingerprint (optional)
  /// - [relayUrl] - Relay service URL (required for relay fallback)
  ///
  /// ## Returns
  ///
  /// A [ConnectionResult] containing a WebRTC connection (webrtc), or an error.
  Future<ConnectionResult> connect({
    required List<String> directUrls,
    required String instanceId,
    String? certFingerprint,
    String? relayUrl,
  }) async {
    // Load connection preferences
    await _loadPreferences();

    // In "all-in" WebRTC mode, we skip direct URLs and go straight to Relay/WebRTC.
    
    // Connect via Relay (WebRTC)
    if (relayUrl != null) {
      _emitState('Connecting via WebRTC Relay');

      final result = await _tryWebRTCConnection(
        instanceId: instanceId,
        relayUrl: relayUrl,
      );

      if (result.success) {
        _emitState('WebRTC connection successful');
        await _storePreference(type: ConnectionType.webrtc);
        return result;
      }

      _emitState('WebRTC connection failed: ${result.error}');
      return result;
    }

    // No relay service available
    return ConnectionResult.error(
      'Could not connect to server. Relay service required.',
    );
  }

  /// Tries to establish a WebRTC connection via relay.
  ///
  /// This method:
  /// 1. Creates a relay tunnel service if not provided
  /// 2. Creates a WebRTCConnectionManager
  /// 3. Establishes WebRTC connection via relay signaling
  ///
  /// Returns a [ConnectionResult] with the active WebRTC manager on success.
  Future<ConnectionResult> _tryWebRTCConnection({
    required String instanceId,
    required String relayUrl,
  }) async {
    try {
      // Create relay tunnel service if not provided
      final tunnelService = _relayTunnelService ??
          RelayTunnelService(relayUrl: relayUrl);

      final webrtcManager = WebRTCConnectionManager(tunnelService);
      
      // Attempt to connect via WebRTC
      await webrtcManager.connect(instanceId);

      return ConnectionResult.webrtc(manager: webrtcManager);
    } catch (e) {
      return ConnectionResult.error('WebRTC error: $e');
    }
  }

  /// Loads connection preferences from storage.
  Future<void> _loadPreferences() async {
    // Just load to ensure storage is ready, logic mostly unused in forced WebRTC mode
    await _authStorage.read(_StorageKeys.lastConnectionType);
  }

  /// Stores connection preference.
  Future<void> _storePreference({
    required ConnectionType type,
    String? url,
  }) async {
    await _authStorage.write(
      _StorageKeys.lastConnectionType,
      'webrtc',
    );
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
