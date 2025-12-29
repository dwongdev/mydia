/// Relay tunnel service for WebSocket-based connection fallback.
///
/// This service connects to the metadata-relay's tunnel endpoint when
/// direct connections to the Mydia instance fail, providing NAT traversal
/// and connection fallback.
///
/// ## Architecture
///
/// ```
/// Client <-WebSocket-> Relay <-WebSocket-> Instance
/// ```
///
/// The tunnel:
/// - Connects to relay at wss://relay/relay/client/websocket
/// - Establishes E2E encrypted Noise channel through relay
/// - Relay only sees ciphertext (cannot read messages)
///
/// ## Usage
///
/// ```dart
/// final service = RelayTunnelService(relayUrl: 'https://relay.example.com');
/// final result = await service.connectViaRelay(instanceId);
/// if (result.success) {
///   final tunnel = result.data!;
///   // Use tunnel.sendMessage() and listen to tunnel.messages
/// }
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Result of a relay tunnel operation.
class RelayTunnelResult<T> {
  final bool success;
  final T? data;
  final String? error;

  const RelayTunnelResult._({
    required this.success,
    this.data,
    this.error,
  });

  factory RelayTunnelResult.success(T data) {
    return RelayTunnelResult._(success: true, data: data);
  }

  factory RelayTunnelResult.error(String error) {
    return RelayTunnelResult._(success: false, error: error);
  }
}

/// Connection info returned when tunnel is established.
class RelayTunnelInfo {
  /// The session ID for this tunnel connection.
  final String sessionId;

  /// The instance ID being connected to.
  final String instanceId;

  /// The instance's public key (base64).
  final String publicKey;

  /// Direct URLs to the instance (for fallback).
  final List<String> directUrls;

  const RelayTunnelInfo({
    required this.sessionId,
    required this.instanceId,
    required this.publicKey,
    required this.directUrls,
  });

  factory RelayTunnelInfo.fromJson(Map<String, dynamic> json) {
    return RelayTunnelInfo(
      sessionId: json['session_id'] as String,
      instanceId: json['instance_id'] as String,
      publicKey: json['public_key'] as String,
      directUrls: (json['direct_urls'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }
}

/// Active relay tunnel connection.
///
/// This class manages an active WebSocket tunnel through the relay,
/// handling message serialization and providing a stream of incoming messages.
class RelayTunnel {
  RelayTunnel._(this._channel, this._broadcastStream, this._info) {
    _messageController = StreamController<Uint8List>.broadcast();
    _errorController = StreamController<String>.broadcast();

    // Listen to WebSocket messages via the broadcast stream
    _broadcastStream.listen(
      _handleMessage,
      onError: (error) {
        _errorController.add('WebSocket error: $error');
      },
      onDone: () {
        _messageController.close();
        _errorController.close();
      },
      cancelOnError: false,
    );
  }

  final WebSocketChannel _channel;
  final Stream<dynamic> _broadcastStream;
  final RelayTunnelInfo _info;
  late final StreamController<Uint8List> _messageController;
  late final StreamController<String> _errorController;

  /// Information about this tunnel connection.
  RelayTunnelInfo get info => _info;

  /// Stream of incoming messages from the instance.
  Stream<Uint8List> get messages => _messageController.stream;

  /// Stream of error messages.
  Stream<String> get errors => _errorController.stream;

  /// Whether the tunnel is still active.
  bool get isActive => !_messageController.isClosed;

  /// Sends a message to the instance through the tunnel.
  ///
  /// The message is serialized to JSON and sent over the WebSocket.
  void sendMessage(Uint8List payload) {
    if (!isActive) {
      throw StateError('Tunnel is closed');
    }

    final message = jsonEncode({
      'type': 'message',
      'payload': base64Encode(payload),
    });

    _channel.sink.add(message);
  }

  /// Closes the tunnel connection.
  Future<void> close() async {
    if (!isActive) return;

    try {
      // Send close message
      final message = jsonEncode({'type': 'close'});
      _channel.sink.add(message);
    } catch (e) {
      // Ignore errors when closing
    }

    await _channel.sink.close();
    await _messageController.close();
    await _errorController.close();
  }

  void _handleMessage(dynamic rawMessage) {
    try {
      if (rawMessage is! String) {
        _errorController.add('Unexpected message type: ${rawMessage.runtimeType}');
        return;
      }

      final json = jsonDecode(rawMessage) as Map<String, dynamic>;
      final type = json['type'] as String?;

      switch (type) {
        case 'message':
          final payloadB64 = json['payload'] as String?;
          if (payloadB64 == null) {
            _errorController.add('Message missing payload');
            return;
          }

          final payload = Uint8List.fromList(base64Decode(payloadB64));
          _messageController.add(payload);
          break;

        case 'error':
          final errorMsg = json['message'] as String? ?? 'Unknown error';
          _errorController.add(errorMsg);
          break;

        default:
          // Ignore unknown message types
          break;
      }
    } catch (e) {
      _errorController.add('Failed to parse message: $e');
    }
  }
}

/// Service for establishing relay tunnel connections.
///
/// This service manages WebSocket connections to the metadata-relay
/// service, enabling clients to connect to Mydia instances when
/// direct connections fail.
class RelayTunnelService {
  RelayTunnelService({required String relayUrl})
      : _relayUrl = _normalizeRelayUrl(relayUrl);

  final String _relayUrl;

  /// Connects to an instance via the relay tunnel.
  ///
  /// ## Parameters
  ///
  /// - `instanceId` - The instance to connect to
  ///
  /// ## Returns
  ///
  /// A [RelayTunnelResult] containing the active [RelayTunnel] on success.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final result = await service.connectViaRelay('instance-uuid');
  /// if (result.success) {
  ///   final tunnel = result.data!;
  ///   // Perform Noise handshake through tunnel
  ///   tunnel.sendMessage(handshakeMessage);
  /// }
  /// ```
  Future<RelayTunnelResult<RelayTunnel>> connectViaRelay(
      String instanceId) async {
    try {
      // Build WebSocket URL for client tunnel
      final wsUrl = _relayUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
      // Phoenix WebSocket endpoints require /websocket suffix
      final uri = Uri.parse('$wsUrl/relay/client/websocket');

      // Establish WebSocket connection
      final channel = WebSocketChannel.connect(uri);

      // Convert to broadcast stream so multiple listeners can subscribe
      final broadcastStream = channel.stream.asBroadcastStream();

      // Wait for first message (the response to our connect request)
      final responseCompleter = Completer<String>();

      broadcastStream.listen(
        (message) {
          if (!responseCompleter.isCompleted && message is String) {
            responseCompleter.complete(message);
          }
        },
        onError: (error) {
          if (!responseCompleter.isCompleted) {
            responseCompleter.completeError(error);
          }
        },
        cancelOnError: false,
      );

      // Send connect message
      final connectMsg = jsonEncode({
        'type': 'connect',
        'instance_id': instanceId,
      });
      channel.sink.add(connectMsg);

      // Wait for response or timeout
      final String firstMessage;
      try {
        firstMessage = await responseCompleter.future
            .timeout(const Duration(seconds: 10), onTimeout: () {
          throw TimeoutException('Connection timeout');
        });
      } catch (e) {
        await channel.sink.close();
        return RelayTunnelResult.error('Failed to connect: $e');
      }

      // Parse the connected response
      final json = jsonDecode(firstMessage) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'error') {
        final errorMsg = json['message'] as String? ?? 'Connection failed';
        await channel.sink.close();
        return RelayTunnelResult.error(errorMsg);
      }

      if (type != 'connected') {
        await channel.sink.close();
        return RelayTunnelResult.error('Unexpected response type: $type');
      }

      // Parse connection info
      final info = RelayTunnelInfo.fromJson(json);

      // Create and return tunnel with broadcast stream
      final tunnel = RelayTunnel._(channel, broadcastStream, info);
      return RelayTunnelResult.success(tunnel);
    } catch (e) {
      if (e.toString().contains('SocketException') ||
          e.toString().contains('WebSocketChannelException')) {
        return RelayTunnelResult.error('Cannot reach relay service');
      }
      return RelayTunnelResult.error('Connection error: $e');
    }
  }

  /// Connects to an instance via claim code through the relay tunnel.
  ///
  /// This is used during initial pairing when the client needs to connect
  /// via a claim code rather than an instance ID.
  ///
  /// ## Parameters
  ///
  /// - `claimCode` - The claim code from the user
  ///
  /// ## Returns
  ///
  /// A [RelayTunnelResult] containing the active [RelayTunnel] on success.
  Future<RelayTunnelResult<RelayTunnel>> connectViaClaimCode(
      String claimCode) async {
    try {
      // Build WebSocket URL for client tunnel
      final wsUrl = _relayUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
      // Phoenix WebSocket endpoints require /websocket suffix
      final uri = Uri.parse('$wsUrl/relay/client/websocket');

      // Establish WebSocket connection
      final channel = WebSocketChannel.connect(uri);

      // Convert to broadcast stream so multiple listeners can subscribe
      final broadcastStream = channel.stream.asBroadcastStream();

      // Wait for first message (the response to our connect request)
      final responseCompleter = Completer<String>();

      broadcastStream.listen(
        (message) {
          if (!responseCompleter.isCompleted && message is String) {
            responseCompleter.complete(message);
          }
        },
        onError: (error) {
          if (!responseCompleter.isCompleted) {
            responseCompleter.completeError(error);
          }
        },
        cancelOnError: false,
      );

      // Send connect message with claim code
      final connectMsg = jsonEncode({
        'type': 'connect',
        'claim_code': claimCode,
      });
      channel.sink.add(connectMsg);

      // Wait for response or timeout
      final String firstMessage;
      try {
        firstMessage = await responseCompleter.future
            .timeout(const Duration(seconds: 10), onTimeout: () {
          throw TimeoutException('Connection timeout');
        });
      } catch (e) {
        await channel.sink.close();
        return RelayTunnelResult.error('Failed to connect: $e');
      }

      // Parse the connected response
      final json = jsonDecode(firstMessage) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'error') {
        final errorMsg = json['message'] as String? ?? 'Connection failed';
        await channel.sink.close();
        return RelayTunnelResult.error(errorMsg);
      }

      if (type != 'connected') {
        await channel.sink.close();
        return RelayTunnelResult.error('Unexpected response type: $type');
      }

      // Parse connection info
      final info = RelayTunnelInfo.fromJson(json);

      // Create and return tunnel with broadcast stream
      final tunnel = RelayTunnel._(channel, broadcastStream, info);
      return RelayTunnelResult.success(tunnel);
    } catch (e) {
      if (e.toString().contains('SocketException') ||
          e.toString().contains('WebSocketChannelException')) {
        return RelayTunnelResult.error('Cannot reach relay service');
      }
      return RelayTunnelResult.error('Connection error: $e');
    }
  }

  static String _normalizeRelayUrl(String url) {
    // Remove trailing slash
    if (url.endsWith('/')) {
      return url.substring(0, url.length - 1);
    }
    return url;
  }
}
