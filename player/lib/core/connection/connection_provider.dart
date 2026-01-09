/// Connection state provider for managing direct vs relay connections.
///
/// This provider manages the current connection mode and provides access to
/// the active relay tunnel when in relay mode. It integrates with the GraphQL
/// providers to ensure requests are routed correctly.
///
/// ## Connection Modes
///
/// - **Direct**: Standard HTTP/HTTPS connection to the Mydia instance
/// - **Relay**: WebSocket tunnel through metadata-relay service
///
/// ## Usage
///
/// ```dart
/// // After pairing with relay tunnel
/// ref.read(connectionProvider.notifier).setRelayTunnel(tunnel);
///
/// // Check connection mode
/// final state = ref.watch(connectionProvider);
/// if (state.isRelayMode) {
///   // Use tunnel for requests
/// }
/// ```
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../relay/relay_tunnel_service.dart';
import '../auth/auth_storage.dart';
import '../graphql/graphql_provider.dart' show serverUrlProvider;
import 'direct_prober.dart';

// Re-export ProbeResult for use in UI
export 'direct_prober.dart' show ProbeResult, UrlProbeResult;

/// Storage keys for relay credentials.
abstract class _ConnectionStorageKeys {
  static const instanceId = 'instance_id';
  static const relayUrl = 'relay_url';
}

/// Connection modes.
enum ConnectionType {
  /// Direct HTTP/HTTPS connection.
  direct,

  /// WebSocket tunnel through relay.
  relay,
}

/// State of the current connection.
class ConnectionState {
  const ConnectionState({
    this.type = ConnectionType.direct,
    this.tunnel,
    this.instanceId,
    this.relayUrl,
  });

  /// The current connection type.
  final ConnectionType type;

  /// The active relay tunnel (only set when [type] is [ConnectionType.relay]).
  final RelayTunnel? tunnel;

  /// The instance ID for relay connections.
  final String? instanceId;

  /// The relay URL for re-establishing connections.
  final String? relayUrl;

  /// Whether currently in relay mode.
  bool get isRelayMode => type == ConnectionType.relay;

  /// Whether the tunnel is active.
  bool get isTunnelActive => tunnel?.isActive ?? false;

  /// Creates a copy with updated fields.
  ConnectionState copyWith({
    ConnectionType? type,
    RelayTunnel? tunnel,
    String? instanceId,
    String? relayUrl,
    bool clearTunnel = false,
  }) {
    return ConnectionState(
      type: type ?? this.type,
      tunnel: clearTunnel ? null : (tunnel ?? this.tunnel),
      instanceId: instanceId ?? this.instanceId,
      relayUrl: relayUrl ?? this.relayUrl,
    );
  }

  /// Creates a direct connection state.
  factory ConnectionState.direct() {
    return const ConnectionState(type: ConnectionType.direct);
  }

  /// Creates a relay connection state with the given tunnel.
  factory ConnectionState.relay({
    required RelayTunnel tunnel,
    String? instanceId,
    String? relayUrl,
  }) {
    return ConnectionState(
      type: ConnectionType.relay,
      tunnel: tunnel,
      instanceId: instanceId,
      relayUrl: relayUrl,
    );
  }
}

/// Notifier for managing connection state.
class ConnectionNotifier extends Notifier<ConnectionState> {
  /// Background prober for testing direct URL connectivity.
  DirectProber? _prober;

  /// Subscription to prober results for auto-switching to direct mode.
  StreamSubscription<ProbeResult>? _proberSubscription;

  @override
  ConnectionState build() {
    // Initialize with direct connection by default
    // The actual mode will be set after checking stored state or pairing
    // Schedule the async load to run after build completes
    Future.microtask(_loadStoredState);
    return ConnectionState.direct();
  }

  AuthStorage get _authStorage => getAuthStorage();

  /// Loads stored connection state on startup.
  Future<void> _loadStoredState() async {
    final instanceId = await _authStorage.read(_ConnectionStorageKeys.instanceId);
    final relayUrl = await _authStorage.read(_ConnectionStorageKeys.relayUrl);

    // Check AFTER awaits - setRelayTunnel may have run during the async gap
    // If we already have an active relay tunnel (e.g., reconnection succeeded), don't overwrite
    if (state.isRelayMode && state.isTunnelActive) {
      debugPrint('[ConnectionNotifier] Already in relay mode with active tunnel, skipping stored state load');
      return;
    }

    // If we have relay credentials (instanceId), store them in state for later use.
    // The actual tunnel will be established by the reconnection service.
    if (instanceId != null) {
      debugPrint('[ConnectionNotifier] Found relay credentials, will reconnect via relay');
      state = ConnectionState(
        type: ConnectionType.direct, // Start as direct until tunnel is established
        instanceId: instanceId,
        relayUrl: relayUrl,
      );
    }
  }

  /// Sets the connection to relay mode with the given tunnel.
  ///
  /// Call this after successful relay pairing or reconnection.
  /// This also starts background probing of direct URLs.
  Future<void> setRelayTunnel(
    RelayTunnel tunnel, {
    String? instanceId,
    String? relayUrl,
  }) async {
    debugPrint('[ConnectionNotifier] Setting relay tunnel, active: ${tunnel.isActive}');

    // Store relay credentials for reconnection
    if (instanceId != null) {
      await _authStorage.write(_ConnectionStorageKeys.instanceId, instanceId);
    }
    if (relayUrl != null) {
      await _authStorage.write(_ConnectionStorageKeys.relayUrl, relayUrl);
    }

    // Update cached direct URLs from the tunnel info if available.
    // The relay server provides fresh direct URLs when establishing the tunnel,
    // which may have changed since initial pairing (e.g., server IP changed).
    await _updateDirectUrlsFromTunnel(tunnel);

    // Listen for tunnel errors
    tunnel.errors.listen((error) {
      debugPrint('[ConnectionNotifier] Tunnel error: $error');
    });

    state = ConnectionState.relay(
      tunnel: tunnel,
      instanceId: instanceId ?? state.instanceId,
      relayUrl: relayUrl ?? state.relayUrl,
    );

    // Start background probing of direct URLs
    await _startDirectProbing();
  }

  /// Updates the cached direct URLs from the relay tunnel info.
  ///
  /// When a relay tunnel is established, the server provides fresh direct URLs
  /// that may have changed since initial pairing. This ensures the cached URLs
  /// stay up-to-date for direct connection probing.
  Future<void> _updateDirectUrlsFromTunnel(RelayTunnel tunnel) async {
    final freshUrls = tunnel.info.directUrls;
    if (freshUrls.isEmpty) {
      debugPrint('[ConnectionNotifier] No direct URLs in tunnel info, keeping cached URLs');
      return;
    }

    // Read current cached URLs to compare
    final currentJson = await _authStorage.read('pairing_direct_urls');
    List<String> currentUrls = [];
    if (currentJson != null) {
      try {
        final decoded = jsonDecode(currentJson);
        if (decoded is List) {
          currentUrls = decoded.cast<String>();
        }
      } catch (e) {
        debugPrint('[ConnectionNotifier] Failed to parse current URLs: $e');
      }
    }

    // Check if URLs have changed
    final urlsChanged = !_listsEqual(currentUrls, freshUrls);
    if (!urlsChanged) {
      debugPrint('[ConnectionNotifier] Direct URLs unchanged (${freshUrls.length} URLs)');
      return;
    }

    debugPrint('[ConnectionNotifier] Updating direct URLs: $currentUrls -> $freshUrls');

    // Update the cached direct URLs
    await _authStorage.write('pairing_direct_urls', jsonEncode(freshUrls));

    // Also update the primary server URL if we have fresh URLs
    if (freshUrls.isNotEmpty) {
      await _authStorage.write('pairing_server_url', freshUrls.first);
      debugPrint('[ConnectionNotifier] Updated primary server URL to: ${freshUrls.first}');
    }
  }

  /// Compares two string lists for equality.
  bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Starts background probing of direct URLs.
  ///
  /// This probes direct URLs to test connectivity and stores results
  /// for display in the settings screen diagnostics.
  Future<void> _startDirectProbing() async {
    // Stop any existing prober
    _stopDirectProbing();

    // Load direct URLs from storage
    final directUrlsJson = await _authStorage.read('pairing_direct_urls');
    if (directUrlsJson == null) {
      debugPrint('[ConnectionNotifier] No direct URLs stored, skipping probing');
      return;
    }

    List<String> directUrls = [];
    try {
      final decoded = jsonDecode(directUrlsJson);
      if (decoded is List) {
        directUrls = decoded.cast<String>();
      }
    } catch (e) {
      debugPrint('[ConnectionNotifier] Failed to parse direct URLs: $e');
      return;
    }

    if (directUrls.isEmpty) {
      debugPrint('[ConnectionNotifier] No direct URLs to probe');
      return;
    }

    debugPrint('[ConnectionNotifier] Starting direct URL probing for ${directUrls.length} URLs');

    // Create and start the prober
    _prober = DirectProber(directUrls: directUrls);

    // Listen for probe results to auto-switch to direct mode
    _proberSubscription = _prober!.results.listen((result) {
      if (result.success && result.successfulUrl != null) {
        debugPrint('[ConnectionNotifier] Probe succeeded! Switching to direct mode: ${result.successfulUrl}');
        _switchToDirectMode(result.successfulUrl!);
      }
    });

    _prober!.startProbing();
  }

  /// Switches from relay to direct mode after successful probe.
  ///
  /// This is a **runtime-only** optimization. On app restart, we always use
  /// relay-first strategy (based on presence of instanceId). The hot-swap to
  /// direct is an ephemeral optimization for the current session only.
  Future<void> _switchToDirectMode(String successfulUrl) async {
    // Stop probing - we're switching now
    _stopDirectProbing();

    // Update the stored server URL to the successful direct URL
    await _authStorage.write('pairing_server_url', successfulUrl);
    debugPrint('[ConnectionNotifier] Updated server URL to: $successfulUrl');

    // Close existing tunnel if any
    if (state.tunnel != null) {
      debugPrint('[ConnectionNotifier] Closing relay tunnel');
      await state.tunnel!.close();
    }

    // Update state to direct mode (runtime state only)
    state = ConnectionState.direct();

    // Invalidate the serverUrlProvider so GraphQL client picks up the new URL
    ref.invalidate(serverUrlProvider);

    debugPrint('[ConnectionNotifier] Switched to direct mode (runtime only, relay-first on restart)');
  }

  /// Stops background probing.
  void _stopDirectProbing() {
    _proberSubscription?.cancel();
    _proberSubscription = null;

    if (_prober != null) {
      debugPrint('[ConnectionNotifier] Stopping direct URL probing');
      _prober!.dispose();
      _prober = null;
    }
  }

  /// Manually triggers a direct URL probe and returns the results.
  ///
  /// This is used by the settings UI to allow users to re-test direct
  /// connectivity on demand. Returns the probe results including individual
  /// URL statuses.
  ///
  /// Returns null if no direct URLs are configured.
  Future<ProbeResult?> probeDirectUrls() async {
    // Load direct URLs from storage
    final directUrlsJson = await _authStorage.read('pairing_direct_urls');
    if (directUrlsJson == null) {
      debugPrint('[ConnectionNotifier] No direct URLs stored for manual probe');
      return null;
    }

    List<String> directUrls = [];
    try {
      final decoded = jsonDecode(directUrlsJson);
      if (decoded is List) {
        directUrls = decoded.cast<String>();
      }
    } catch (e) {
      debugPrint('[ConnectionNotifier] Failed to parse direct URLs: $e');
      return null;
    }

    if (directUrls.isEmpty) {
      debugPrint('[ConnectionNotifier] No direct URLs to probe');
      return null;
    }

    debugPrint('[ConnectionNotifier] Manual probe triggered for ${directUrls.length} URLs');

    // Create a temporary prober for this manual probe
    final prober = DirectProber(directUrls: directUrls);

    // Listen for the result
    final resultFuture = prober.results.first;

    // Start probing
    prober.startProbing();

    // Wait for result
    final result = await resultFuture;

    // Clean up
    prober.dispose();

    debugPrint('[ConnectionNotifier] Manual probe complete: success=${result.success}');

    return result;
  }

  /// Sets the connection to direct mode.
  ///
  /// This updates the runtime state only. It does NOT persist 'direct' as
  /// the connection mode because on app restart, we should use relay-first
  /// strategy (if relay credentials exist). The direct mode is a runtime
  /// optimization when direct connectivity is available.
  ///
  /// For users who paired via relay, this ensures they can always reconnect
  /// via relay even if direct connectivity becomes unavailable later.
  Future<void> setDirectMode() async {
    debugPrint('[ConnectionNotifier] Setting direct mode (runtime only)');

    // Stop probing since we're now direct
    _stopDirectProbing();

    // Close existing tunnel if any
    if (state.tunnel != null) {
      await state.tunnel!.close();
    }

    // NOTE: We intentionally do NOT persist 'direct' as the connection mode.
    // On restart, relay-first strategy is used if relay credentials exist.

    state = ConnectionState.direct();
  }

  /// Clears all connection state.
  ///
  /// Call this when logging out or clearing credentials.
  Future<void> clear() async {
    debugPrint('[ConnectionNotifier] Clearing connection state');

    // Stop probing
    _stopDirectProbing();

    // Close existing tunnel if any
    if (state.tunnel != null) {
      await state.tunnel!.close();
    }

    // Clear stored relay credentials
    await _authStorage.delete(_ConnectionStorageKeys.instanceId);
    await _authStorage.delete(_ConnectionStorageKeys.relayUrl);

    state = ConnectionState.direct();
  }

  /// Reconnects the relay tunnel if needed.
  ///
  /// Returns true if reconnection was successful or not needed.
  Future<bool> ensureTunnelActive() async {
    if (!state.isRelayMode) {
      return true; // Direct mode, no tunnel needed
    }

    if (state.isTunnelActive) {
      return true; // Tunnel is already active
    }

    // Need to reconnect
    if (state.instanceId == null || state.relayUrl == null) {
      debugPrint('[ConnectionNotifier] Cannot reconnect: missing instance ID or relay URL');
      return false;
    }

    debugPrint('[ConnectionNotifier] Reconnecting relay tunnel...');
    try {
      final tunnelService = RelayTunnelService(relayUrl: state.relayUrl!);
      final result = await tunnelService.connectViaRelay(state.instanceId!);

      if (!result.success) {
        debugPrint('[ConnectionNotifier] Reconnection failed: ${result.error}');
        return false;
      }

      // Update state with new tunnel
      state = state.copyWith(tunnel: result.data);
      debugPrint('[ConnectionNotifier] Reconnection successful');
      return true;
    } catch (e) {
      debugPrint('[ConnectionNotifier] Reconnection error: $e');
      return false;
    }
  }
}

/// Provider for the current connection state.
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(ConnectionNotifier.new);
