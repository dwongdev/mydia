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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../relay/relay_tunnel_service.dart';
import '../auth/auth_storage.dart';

/// Storage keys for connection state.
abstract class _ConnectionStorageKeys {
  static const connectionMode = 'connection_mode';
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
    // If we already have an active relay tunnel (e.g., just paired), don't overwrite
    // Now safe to access state since build() has completed
    if (state.isRelayMode && state.isTunnelActive) {
      debugPrint('[ConnectionNotifier] Already in relay mode with active tunnel, skipping stored state load');
      return;
    }

    final modeStr = await _authStorage.read(_ConnectionStorageKeys.connectionMode);
    final instanceId = await _authStorage.read(_ConnectionStorageKeys.instanceId);
    final relayUrl = await _authStorage.read(_ConnectionStorageKeys.relayUrl);

    if (modeStr == 'relay' && instanceId != null) {
      debugPrint('[ConnectionNotifier] Stored mode is relay, will need to reconnect');
      // Don't set relay mode yet - the tunnel needs to be re-established
      // The reconnection service will handle this and call setRelayTunnel
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
  Future<void> setRelayTunnel(
    RelayTunnel tunnel, {
    String? instanceId,
    String? relayUrl,
  }) async {
    debugPrint('[ConnectionNotifier] Setting relay tunnel, active: ${tunnel.isActive}');

    // Store connection mode for persistence
    await _authStorage.write(_ConnectionStorageKeys.connectionMode, 'relay');
    if (instanceId != null) {
      await _authStorage.write(_ConnectionStorageKeys.instanceId, instanceId);
    }
    if (relayUrl != null) {
      await _authStorage.write(_ConnectionStorageKeys.relayUrl, relayUrl);
    }

    // Listen for tunnel errors
    tunnel.errors.listen((error) {
      debugPrint('[ConnectionNotifier] Tunnel error: $error');
    });

    state = ConnectionState.relay(
      tunnel: tunnel,
      instanceId: instanceId ?? state.instanceId,
      relayUrl: relayUrl ?? state.relayUrl,
    );
  }

  /// Sets the connection to direct mode.
  ///
  /// Call this after successful direct connection or when clearing relay mode.
  Future<void> setDirectMode() async {
    debugPrint('[ConnectionNotifier] Setting direct mode');

    // Close existing tunnel if any
    if (state.tunnel != null) {
      await state.tunnel!.close();
    }

    // Store connection mode
    await _authStorage.write(_ConnectionStorageKeys.connectionMode, 'direct');

    state = ConnectionState.direct();
  }

  /// Clears all connection state.
  ///
  /// Call this when logging out or clearing credentials.
  Future<void> clear() async {
    debugPrint('[ConnectionNotifier] Clearing connection state');

    // Close existing tunnel if any
    if (state.tunnel != null) {
      await state.tunnel!.close();
    }

    // Clear stored state
    await _authStorage.delete(_ConnectionStorageKeys.connectionMode);
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
