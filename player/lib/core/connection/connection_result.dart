/// Result types for connection operations.
///
/// This library provides result types for connection attempts using
/// direct URLs and relay fallback.
library;

import '../webrtc/webrtc_connection_manager.dart';

/// Type of connection established.
enum ConnectionType {
  /// Direct HTTPS connection to instance.
  direct,

  /// WebRTC connection via relay signaling.
  webrtc,
}

/// Result of a connection attempt.
class ConnectionResult {
  /// Whether the connection was successful.
  final bool success;

  /// The type of connection (if successful).
  final ConnectionType? type;

  /// The connected URL (for direct connections).
  final String? connectedUrl;

  /// The WebRTC connection manager (for WebRTC connections).
  final WebRTCConnectionManager? webrtc;

  /// Error message (if failed).
  final String? error;

  const ConnectionResult._({
    required this.success,
    this.type,
    this.connectedUrl,
    this.webrtc,
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

  /// Creates a successful WebRTC connection result.
  factory ConnectionResult.webrtc({
    required WebRTCConnectionManager manager,
  }) {
    return ConnectionResult._(
      success: true,
      type: ConnectionType.webrtc,
      webrtc: manager,
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

  /// Whether this is a WebRTC connection.
  bool get isWebRTC => type == ConnectionType.webrtc;
}

