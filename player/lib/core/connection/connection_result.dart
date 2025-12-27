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
