/// Result types for connection operations.
///
/// This library provides result types for connection attempts using
/// direct URLs and relay fallback.
library;

import '../relay/relay_tunnel_service.dart';

/// Type of connection established.
enum ConnectionType {
  /// Direct HTTPS connection to instance.
  direct,

  /// WebSocket tunnel through relay.
  relay,
}

/// Result of a connection attempt.
class ConnectionResult {
  /// Whether the connection was successful.
  final bool success;

  /// The type of connection (if successful).
  final ConnectionType? type;

  /// The connected URL (for direct connections).
  final String? connectedUrl;

  /// The relay tunnel (for relay connections).
  final RelayTunnel? tunnel;

  /// Error message (if failed).
  final String? error;

  const ConnectionResult._({
    required this.success,
    this.type,
    this.connectedUrl,
    this.tunnel,
    this.error,
  });

  /// Creates a successful direct connection result.
  ///
  /// The [url] indicates which direct URL was successfully connected.
  /// The caller is responsible for joining channels as needed.
  factory ConnectionResult.direct({
    required String url,
  }) {
    return ConnectionResult._(
      success: true,
      type: ConnectionType.direct,
      connectedUrl: url,
    );
  }

  /// Creates a successful relay connection result.
  ///
  /// The [tunnel] is an active WebSocket tunnel through the relay.
  /// The caller is responsible for performing handshakes over the tunnel.
  factory ConnectionResult.relay({
    required RelayTunnel tunnel,
  }) {
    return ConnectionResult._(
      success: true,
      type: ConnectionType.relay,
      tunnel: tunnel,
    );
  }

  /// Creates a failed connection result.
  factory ConnectionResult.error(String error) {
    return ConnectionResult._(
      success: false,
      error: error,
    );
  }

  /// Whether this is a direct connection.
  bool get isDirect => type == ConnectionType.direct;

  /// Whether this is a relay connection.
  bool get isRelay => type == ConnectionType.relay;
}

/// Preferences for connection method ordering.
class ConnectionPreferences {
  /// Last successful connection method.
  final ConnectionType? lastSuccessful;

  /// Last successful direct URL.
  final String? lastSuccessfulUrl;

  const ConnectionPreferences({
    this.lastSuccessful,
    this.lastSuccessfulUrl,
  });

  /// Creates default preferences (no history).
  factory ConnectionPreferences.defaults() {
    return const ConnectionPreferences();
  }
}

/// Current connection mode for relay-first strategy.
///
/// This enum represents the active connection state:
/// - [relayOnly]: Connected via relay tunnel only
/// - [directOnly]: Connected via direct URL only
/// - [dual]: Both connections active during hot swap transition
enum ConnectionMode {
  /// Connected via relay tunnel only.
  ///
  /// This is the initial state after pairing/reconnection,
  /// and the fallback state when direct connection fails.
  relayOnly,

  /// Connected via direct URL only.
  ///
  /// This is the target state after successful hot swap
  /// from relay to direct connection.
  directOnly,

  /// Both connections active (hot swap in progress).
  ///
  /// During this state:
  /// - New requests are routed to direct connection
  /// - In-flight relay requests continue on relay
  /// - Once all relay requests complete, transition to directOnly
  dual,
}

/// Current connection state for relay-first strategy.
///
/// This class tracks all aspects of the current connection:
/// - Active connections (relay tunnel, direct URL)
/// - Pending request counts (for graceful switching)
/// - Background probing state
///
/// ## State Transitions
///
/// ```
/// Initial: relayOnly
///   |
///   v (probe succeeds)
/// dual (hot swap in progress)
///   |
///   v (relay requests drained)
/// directOnly
///   |
///   v (direct drops)
/// relayOnly (auto-fallback)
/// ```
class ConnectionState {
  /// Current connection mode.
  final ConnectionMode mode;

  /// Active relay tunnel (null if not connected via relay).
  final RelayTunnel? relayTunnel;

  /// Connected direct URL (null if not connected directly).
  final String? directUrl;

  /// Number of in-flight requests on relay connection.
  ///
  /// Used during hot swap to know when it's safe to close relay.
  final int pendingRelayRequests;

  /// Number of in-flight requests on direct connection.
  final int pendingDirectRequests;

  /// Timestamp of last direct URL probe attempt.
  final DateTime? lastDirectProbe;

  /// Number of consecutive probe failures.
  ///
  /// Used for exponential backoff: 5s, 10s, 30s, 60s, max 5min.
  final int probeFailureCount;

  const ConnectionState({
    required this.mode,
    this.relayTunnel,
    this.directUrl,
    this.pendingRelayRequests = 0,
    this.pendingDirectRequests = 0,
    this.lastDirectProbe,
    this.probeFailureCount = 0,
  });

  /// Creates initial relay-only state.
  factory ConnectionState.relayOnly({required RelayTunnel tunnel}) {
    return ConnectionState(
      mode: ConnectionMode.relayOnly,
      relayTunnel: tunnel,
    );
  }

  /// Creates direct-only state.
  factory ConnectionState.directOnly({required String url}) {
    return ConnectionState(
      mode: ConnectionMode.directOnly,
      directUrl: url,
    );
  }

  /// Creates dual connection state (hot swap in progress).
  factory ConnectionState.dual({
    required RelayTunnel tunnel,
    required String directUrl,
    int pendingRelayRequests = 0,
  }) {
    return ConnectionState(
      mode: ConnectionMode.dual,
      relayTunnel: tunnel,
      directUrl: directUrl,
      pendingRelayRequests: pendingRelayRequests,
    );
  }

  /// Whether relay connection is active.
  bool get hasRelay => relayTunnel != null;

  /// Whether direct connection is active.
  bool get hasDirect => directUrl != null;

  /// Whether currently in hot swap transition.
  bool get isHotSwapping => mode == ConnectionMode.dual;

  /// Whether safe to close relay (no pending requests).
  bool get canCloseRelay => pendingRelayRequests == 0;

  /// Returns the next probe delay based on failure count.
  ///
  /// Exponential backoff: 5s, 10s, 30s, 60s, then max 5min.
  Duration get nextProbeDelay {
    const delays = [
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(minutes: 5),
    ];
    final index = probeFailureCount.clamp(0, delays.length - 1);
    return delays[index];
  }

  /// Creates a copy with updated fields.
  ConnectionState copyWith({
    ConnectionMode? mode,
    RelayTunnel? relayTunnel,
    String? directUrl,
    int? pendingRelayRequests,
    int? pendingDirectRequests,
    DateTime? lastDirectProbe,
    int? probeFailureCount,
    bool clearRelayTunnel = false,
    bool clearDirectUrl = false,
  }) {
    return ConnectionState(
      mode: mode ?? this.mode,
      relayTunnel: clearRelayTunnel ? null : (relayTunnel ?? this.relayTunnel),
      directUrl: clearDirectUrl ? null : (directUrl ?? this.directUrl),
      pendingRelayRequests: pendingRelayRequests ?? this.pendingRelayRequests,
      pendingDirectRequests: pendingDirectRequests ?? this.pendingDirectRequests,
      lastDirectProbe: lastDirectProbe ?? this.lastDirectProbe,
      probeFailureCount: probeFailureCount ?? this.probeFailureCount,
    );
  }

  @override
  String toString() {
    return 'ConnectionState('
        'mode: $mode, '
        'hasRelay: $hasRelay, '
        'hasDirect: $hasDirect, '
        'pendingRelay: $pendingRelayRequests, '
        'pendingDirect: $pendingDirectRequests, '
        'probeFailures: $probeFailureCount)';
  }
}
