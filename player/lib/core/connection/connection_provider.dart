library connection_provider;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../webrtc/webrtc_connection_manager.dart';
import '../auth/auth_storage.dart';

/// Storage keys for relay credentials.
abstract class _ConnectionStorageKeys {
  static const instanceId = 'instance_id';
  static const relayUrl = 'relay_url';
}

/// Connection modes.
enum ConnectionType {
  /// Direct HTTP/HTTPS connection.
  direct,

  /// WebRTC connection via relay signaling.
  webrtc,
}

/// State of the current connection.
class ConnectionState {
  const ConnectionState({
    this.type = ConnectionType.direct,
    this.webrtcManager,
    this.instanceId,
    this.relayUrl,
  });

  /// The current connection type.
  final ConnectionType type;

  /// The active WebRTC manager (only set when [type] is [ConnectionType.webrtc]).
  final WebRTCConnectionManager? webrtcManager;

  /// The instance ID for relay connections.
  final String? instanceId;

  /// The relay URL for re-establishing connections.
  final String? relayUrl;

  /// Whether currently in WebRTC mode.
  bool get isWebRTCMode => type == ConnectionType.webrtc;

  /// Creates a copy with updated fields.
  ConnectionState copyWith({
    ConnectionType? type,
    WebRTCConnectionManager? webrtcManager,
    String? instanceId,
    String? relayUrl,
    bool clearManager = false,
  }) {
    return ConnectionState(
      type: type ?? this.type,
      webrtcManager: clearManager ? null : (webrtcManager ?? this.webrtcManager),
      instanceId: instanceId ?? this.instanceId,
      relayUrl: relayUrl ?? this.relayUrl,
    );
  }

  /// Creates a direct connection state.
  factory ConnectionState.direct() {
    return const ConnectionState(type: ConnectionType.direct);
  }

  /// Creates a WebRTC connection state.
  factory ConnectionState.webrtc({
    required WebRTCConnectionManager manager,
    String? instanceId,
    String? relayUrl,
  }) {
    return ConnectionState(
      type: ConnectionType.webrtc,
      webrtcManager: manager,
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
    final instanceId = await _authStorage.read(_ConnectionStorageKeys.instanceId);
    final relayUrl = await _authStorage.read(_ConnectionStorageKeys.relayUrl);

    // Check AFTER awaits - setWebRTCManager may have run during the async gap
    if (state.isWebRTCMode && state.webrtcManager != null) {
      debugPrint('[ConnectionNotifier] Already in WebRTC mode, skipping stored state load');
      return;
    }

    // If we have relay credentials (instanceId), store them in state for later use.
    if (instanceId != null) {
      debugPrint('[ConnectionNotifier] Found relay credentials, will reconnect via relay');
      state = ConnectionState(
        type: ConnectionType.direct, // Start as direct until WebRTC is established
        instanceId: instanceId,
        relayUrl: relayUrl,
      );
    }
  }

  /// Sets the connection to WebRTC mode with the given manager.
  Future<void> setWebRTCManager(
    WebRTCConnectionManager manager, {
    String? instanceId,
    String? relayUrl,
  }) async {
    debugPrint('[ConnectionNotifier] Setting WebRTC manager');

    // Store relay credentials for reconnection
    if (instanceId != null) {
      await _authStorage.write(_ConnectionStorageKeys.instanceId, instanceId);
    }
    if (relayUrl != null) {
      await _authStorage.write(_ConnectionStorageKeys.relayUrl, relayUrl);
    }

    state = ConnectionState.webrtc(
      manager: manager,
      instanceId: instanceId ?? state.instanceId,
      relayUrl: relayUrl ?? state.relayUrl,
    );
  }

  /// Sets the connection to direct mode.
  Future<void> setDirectMode() async {
    debugPrint('[ConnectionNotifier] Setting direct mode (runtime only)');
    
    // Close existing manager if any
    if (state.webrtcManager != null) {
      state.webrtcManager!.dispose();
    }

    state = ConnectionState.direct();
  }
  
  Future<void> clear() async {
    debugPrint('[ConnectionNotifier] Clearing connection state');
    state.webrtcManager?.dispose();
    
    await _authStorage.delete(_ConnectionStorageKeys.instanceId);
    await _authStorage.delete(_ConnectionStorageKeys.relayUrl);

    state = ConnectionState.direct();
  }

  /// Reconnects the relay tunnel if needed.
  Future<bool> ensureTunnelActive() async {
    // WebRTC handles its own connection state mostly.
    // If we need to reconnect, we might need to create a new manager.
    // For now, assume active if manager exists.
    return state.webrtcManager != null;
  }
}

/// Provider for the current connection state.
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(ConnectionNotifier.new);
