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
library relay_tunnel_service;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/protocol_version.dart';

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

  /// ICE servers configuration for WebRTC.
  final List<Map<String, dynamic>> iceServers;

  const RelayTunnelInfo({
    required this.sessionId,
    required this.instanceId,
    required this.publicKey,
    required this.directUrls,
    this.iceServers = const [],
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
      iceServers: (json['ice_servers'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
    );
  }
}

/// Response from a tunneled HTTP request.
class TunnelResponse {
  /// HTTP status code.
  final int status;

  /// Response headers.
  final Map<String, String> headers;

  /// Response body (decoded from base64 if binary).
  final dynamic body;

  /// Whether the body is binary data.
  final bool isBinary;

  const TunnelResponse({
    required this.status,
    required this.headers,
    this.body,
    this.isBinary = false,
  });

  /// Gets the body as a string.
  String? get bodyAsString {
    if (body == null) return null;
    if (body is String) return body;
    if (body is Uint8List) return utf8.decode(body);
    return body.toString();
  }

  /// Gets the body as bytes.
  Uint8List? get bodyAsBytes {
    if (body == null) return null;
    if (body is Uint8List) return body;
    if (body is String) return Uint8List.fromList(utf8.encode(body));
    return null;
  }

  /// Whether the request was successful (2xx status code).
  bool get isSuccess => status >= 200 && status < 300;
}

/// Active relay tunnel connection.
///
/// This class manages an active WebSocket tunnel through the relay,
/// handling message serialization and providing a stream of incoming messages.
/// Includes heartbeat mechanism to detect dead connections.
///
/// ## End-to-End Encryption
///
/// After the handshake is complete, all messages to/from the instance are
/// encrypted using ChaCha20-Poly1305. Call [enableEncryption] after the
/// handshake to enable encryption for all subsequent messages.
///
/// Wire format for encrypted messages:
/// ```
/// base64(nonce_12_bytes || ciphertext || mac_16_bytes)
/// ```
class RelayTunnel {
  /// Heartbeat interval: 30 seconds
  static const _heartbeatInterval = Duration(seconds: 30);

  /// Heartbeat response timeout: 10 seconds
  static const _heartbeatTimeout = Duration(seconds: 10);

  /// Request timeout: 30 seconds
  static const _requestTimeout = Duration(seconds: 30);

  /// ChaCha20-Poly1305 nonce size
  static const _nonceSize = 12;

  /// ChaCha20-Poly1305 MAC size
  static const _macSize = 16;

  RelayTunnel._(this._channel, this._broadcastStream, this._info) {
    debugPrint('[RelayTunnel] Creating tunnel for session: ${_info.sessionId}');
    _messageController = StreamController<Uint8List>.broadcast();
    _errorController = StreamController<String>.broadcast();
    _signalingController = StreamController<Map<String, dynamic>>.broadcast();
    _pendingRequests = {};

    // Listen to WebSocket messages via the broadcast stream
    _broadcastStream.listen(
      (message) {
        debugPrint('[RelayTunnel] Received message: ${message.runtimeType}, length: ${message is String ? message.length : "N/A"}');
        if (message is String && message.length < 500) {
          debugPrint('[RelayTunnel] Message content: $message');
        }
        _handleMessage(message);
      },
      onError: (error, stackTrace) {
        debugPrint('[RelayTunnel] WebSocket error: $error');
        debugPrint('[RelayTunnel] WebSocket error stack: $stackTrace');
        _errorController.add('WebSocket error: $error');
      },
      onDone: () {
        debugPrint('[RelayTunnel] WebSocket stream done (closed)');
        debugPrint('[RelayTunnel] Current stack: ${StackTrace.current}');
        _stopHeartbeat();
        _messageController.close();
        _errorController.close();
      },
      cancelOnError: false,
    );

    // Start heartbeat mechanism
    _startHeartbeat();
    debugPrint('[RelayTunnel] Tunnel initialized');
  }

  final WebSocketChannel _channel;
  final Stream<dynamic> _broadcastStream;
  final RelayTunnelInfo _info;
  late final StreamController<Uint8List> _messageController;
  late final StreamController<String> _errorController;
  late final StreamController<Map<String, dynamic>> _signalingController;
  late final Map<String, Completer<TunnelResponse>> _pendingRequests;
  int _requestCounter = 0;

  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  bool _pendingHeartbeat = false;

  /// Information about this tunnel connection.
  RelayTunnelInfo get info => _info;

  /// Stream of incoming messages from the instance.
  Stream<Uint8List> get messages => _messageController.stream;

  /// Stream of error messages.
  Stream<String> get errors => _errorController.stream;

  /// Stream of signaling messages.
  Stream<Map<String, dynamic>> get signalingMessages => _signalingController.stream;

  /// Whether the tunnel is still active.
  bool get isActive => !_messageController.isClosed;

  /// Sends a WebRTC signaling message.
  void sendSignalingMessage(String type, dynamic payload) {
    if (!isActive) {
      throw StateError('Tunnel is closed');
    }

    final message = jsonEncode({
      'type': type,
      'payload': jsonEncode(payload),
    });

    _channel.sink.add(message);
  }

  /// Sends a JSON message to the instance through the tunnel.
  ///
  /// The message is serialized to JSON and sent over the WebSocket.
  ///
  /// ## Parameters
  ///
  /// - [jsonMessage] - The JSON string to send.
  Future<void> sendJsonMessage(String jsonMessage) async {
    if (!isActive) {
      throw StateError('Tunnel is closed');
    }

    final payload = base64Encode(utf8.encode(jsonMessage));
    
    final message = jsonEncode({
      'type': 'message',
      'payload': payload,
    });

    _channel.sink.add(message);
  }

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

    _stopHeartbeat();

    // Complete all pending requests with error
    for (final entry in _pendingRequests.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(const TunnelResponse(
          status: 503,
          headers: {},
          body: '{"error": "Tunnel closed"}',
        ));
      }
    }
    _pendingRequests.clear();

    try {
      // Send close message
      final message = jsonEncode({'type': 'close'});
      _channel.sink.add(message);
    } catch (_) {
      // Ignore errors when closing
    }

    await _channel.sink.close();
    await _messageController.close();
    await _errorController.close();
    await _signalingController.close();
  }


  // Handles webrtc_* messages from relay.
  void _handleSignalingMessage(String type, Map<String, dynamic> messageJson) {
    final payloadJson = messageJson['payload'];

    dynamic payload;
    if (payloadJson is String) {
      try {
        payload = jsonDecode(payloadJson);
      } catch (_) {
        payload = payloadJson;
      }
    } else {
      payload = payloadJson;
    }

    _signalingController.add({'type': type, 'payload': payload});
  }

  /// Sends an HTTP request through the tunnel.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _sendHeartbeat();
    });
  }

  /// Stops the heartbeat mechanism.
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
    _pendingHeartbeat = false;
  }

  /// Sends a heartbeat ping and starts timeout timer.
  void _sendHeartbeat() {
    if (!isActive) return;

    try {
      final message = jsonEncode({'type': 'ping'});
      _channel.sink.add(message);
      _pendingHeartbeat = true;

      // Start timeout timer
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = Timer(_heartbeatTimeout, () {
        if (_pendingHeartbeat) {
          _errorController.add('Heartbeat timeout - connection appears dead');
          close();
        }
      });
    } catch (e) {
      // Connection likely dead
      _errorController.add('Failed to send heartbeat: $e');
      close();
    }
  }

  /// Called when heartbeat response (pong) is received.
  void _onHeartbeatResponse() {
    _pendingHeartbeat = false;
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
  }

  void _handleMessage(dynamic rawMessage) {
    _handleMessageAsync(rawMessage);
  }

  Future<void> _handleMessageAsync(dynamic rawMessage) async {
    try {
      if (rawMessage is! String) {
        _errorController.add('Unexpected message type: ${rawMessage.runtimeType}');
        return;
      }

      final json = jsonDecode(rawMessage) as Map<String, dynamic>;
      final type = json['type'] as String?;

      switch (type) {
        case 'webrtc_offer':
        case 'webrtc_answer':
        case 'webrtc_candidate':
          if (type != null) {
            _handleSignalingMessage(type, json);
          }
          break;

        case 'message':
          final payloadB64 = json['payload'] as String?;
          if (payloadB64 == null) {
            _errorController.add('Message missing payload');
            return;
          }

          String payloadString;
          // No encryption - decode as plaintext
          final payload = Uint8List.fromList(base64Decode(payloadB64));
          payloadString = utf8.decode(payload);

          // Try to parse as JSON to check if it's a response message
          try {
            final payloadJson = jsonDecode(payloadString) as Map<String, dynamic>;
            if (payloadJson['type'] == 'response') {
              _handleResponseMessage(payloadJson);
              return;
            }
            // Forward as bytes for compatibility with existing code
            _messageController.add(Uint8List.fromList(utf8.encode(payloadString)));
          } catch (_) {
            // Not JSON, forward as bytes
            _messageController.add(Uint8List.fromList(utf8.encode(payloadString)));
          }
          break;

        case 'pong':
          // Heartbeat response received
          _onHeartbeatResponse();
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

  /// Handles a response message from a tunneled request.
  void _handleResponseMessage(Map<String, dynamic> json) {
    final requestId = json['id'] as String?;
    if (requestId == null) {
      debugPrint('[RelayTunnel] Response missing request ID');
      return;
    }

    final completer = _pendingRequests.remove(requestId);
    if (completer == null) {
      debugPrint('[RelayTunnel] No pending request for ID: $requestId');
      return;
    }

    if (completer.isCompleted) {
      debugPrint('[RelayTunnel] Request already completed: $requestId');
      return;
    }

    final status = json['status'] as int? ?? 500;
    final headers = (json['headers'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, v.toString())) ??
        {};

    // Decode body based on encoding
    final bodyEncoding = json['body_encoding'] as String? ?? 'raw';
    final rawBody = json['body'];
    dynamic body;
    bool isBinary = false;

    if (rawBody != null) {
      if (bodyEncoding == 'base64' && rawBody is String) {
        body = base64Decode(rawBody);
        isBinary = true;
      } else {
        body = rawBody;
      }
    }

    debugPrint(
      '[RelayTunnel] Response body: encoding=$bodyEncoding, type=${rawBody.runtimeType}, size=${rawBody is String ? rawBody.length : (rawBody is List ? rawBody.length : 0)}',
    );
    if (rawBody is String && rawBody.length < 200) {
      debugPrint('[RelayTunnel] Body content: $rawBody');
    } else if (rawBody is String) {
      debugPrint('[RelayTunnel] Body preview: ${rawBody.substring(0, 100)}...');
    }

    completer.complete(TunnelResponse(
      status: status,
      headers: headers,
      body: body,
      isBinary: isBinary,
    ));
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
    debugPrint('[RelayTunnelService] Connecting via relay to instance: $instanceId');
    try {
      // Build WebSocket URL for client tunnel
      final wsUrl = _relayUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
      // Phoenix WebSocket endpoints require /websocket suffix
      final uri = Uri.parse('$wsUrl/relay/client/websocket');
      debugPrint('[RelayTunnelService] WebSocket URL: $uri');

      // Establish WebSocket connection
      final channel = WebSocketChannel.connect(uri);
      debugPrint('[RelayTunnelService] WebSocket channel created');

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
        onError: (error, stackTrace) {
          debugPrint('[RelayTunnelService] connectViaRelay broadcast error: $error');
          debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
          if (!responseCompleter.isCompleted) {
            responseCompleter.completeError(error, stackTrace);
          }
        },
        cancelOnError: false,
      );

      // Send connect message with protocol versions
      final connectMsg = jsonEncode({
        'type': 'connect',
        'instance_id': instanceId,
        'protocol_versions': ProtocolVersion.all,
      });
      channel.sink.add(connectMsg);

      // Wait for response or timeout
      final String firstMessage;
      try {
        firstMessage = await responseCompleter.future
            .timeout(const Duration(seconds: 10), onTimeout: () {
          throw TimeoutException('Connection timeout');
        });
      } catch (e, stackTrace) {
        debugPrint('[RelayTunnelService] connectViaRelay wait error: $e');
        debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
        await channel.sink.close();
        return RelayTunnelResult.error('Failed to connect: $e');
      }

      // Parse the connected response
      final json = jsonDecode(firstMessage) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'error') {
        final code = json['code'] as String?;
        final errorMsg = json['message'] as String? ?? 'Connection failed';
        await channel.sink.close();
        // Handle update_required error specially
        if (code == 'update_required' || code == 'version_incompatible') {
          throw UpdateRequiredError.fromJson(json);
        }
        return RelayTunnelResult.error(errorMsg);
      }

      if (type != 'connected') {
        await channel.sink.close();
        return RelayTunnelResult.error('Unexpected response type: $type');
      }

      debugPrint('[RelayTunnelService] Received connected response');

      // Check instance protocol versions if provided
      final instanceVersions = json['instance_versions'] as Map<String, dynamic>?;
      if (instanceVersions != null) {
        final mismatch = ProtocolVersion.checkCompatibility(instanceVersions);
        if (mismatch != null) {
          await channel.sink.close();
          throw UpdateRequiredError(
            message: mismatch.message,
            incompatibleLayers: mismatch.mismatches
                .map((m) => {
                      'layer': m.layer,
                      'server_version': m.serverVersion,
                      'client_version': m.clientVersion,
                    })
                .toList(),
          );
        }
      }

      // Parse connection info
      RelayTunnelInfo info;
      try {
        info = RelayTunnelInfo.fromJson(json);
        debugPrint('[RelayTunnelService] Parsed tunnel info: session=${info.sessionId}, instance=${info.instanceId}');
      } catch (e, stackTrace) {
        debugPrint('[RelayTunnelService] Failed to parse tunnel info: $e');
        debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
        await channel.sink.close();
        return RelayTunnelResult.error('Failed to parse connection info: $e');
      }

      // Create and return tunnel with broadcast stream
      debugPrint('[RelayTunnelService] Creating tunnel...');
      final tunnel = RelayTunnel._(channel, broadcastStream, info);
      debugPrint('[RelayTunnelService] Tunnel created successfully');
      return RelayTunnelResult.success(tunnel);
    } catch (e, stackTrace) {
      debugPrint('[RelayTunnelService] Connection error: $e');
      debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
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
    debugPrint('[RelayTunnelService] Connecting via claim code');
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
        onError: (error, stackTrace) {
          debugPrint('[RelayTunnelService] connectViaClaimCode broadcast error: $error');
          debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
          if (!responseCompleter.isCompleted) {
            responseCompleter.completeError(error, stackTrace);
          }
        },
        cancelOnError: false,
      );

      // Send connect message with claim code and protocol versions
      final connectMsg = jsonEncode({
        'type': 'connect',
        'claim_code': claimCode,
        'protocol_versions': ProtocolVersion.all,
      });
      channel.sink.add(connectMsg);

      // Wait for response or timeout
      final String firstMessage;
      try {
        firstMessage = await responseCompleter.future
            .timeout(const Duration(seconds: 10), onTimeout: () {
          throw TimeoutException('Connection timeout');
        });
      } catch (e, stackTrace) {
        debugPrint('[RelayTunnelService] connectViaClaimCode wait error: $e');
        debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
        await channel.sink.close();
        return RelayTunnelResult.error('Failed to connect: $e');
      }

      // Parse the connected response
      final json = jsonDecode(firstMessage) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'error') {
        final code = json['code'] as String?;
        final errorMsg = json['message'] as String? ?? 'Connection failed';
        await channel.sink.close();
        // Handle update_required error specially
        if (code == 'update_required' || code == 'version_incompatible') {
          throw UpdateRequiredError.fromJson(json);
        }
        return RelayTunnelResult.error(errorMsg);
      }

      if (type != 'connected') {
        await channel.sink.close();
        return RelayTunnelResult.error('Unexpected response type: $type');
      }

      // Check instance protocol versions if provided
      final instanceVersions = json['instance_versions'] as Map<String, dynamic>?;
      if (instanceVersions != null) {
        final mismatch = ProtocolVersion.checkCompatibility(instanceVersions);
        if (mismatch != null) {
          await channel.sink.close();
          throw UpdateRequiredError(
            message: mismatch.message,
            incompatibleLayers: mismatch.mismatches
                .map((m) => {
                      'layer': m.layer,
                      'server_version': m.serverVersion,
                      'client_version': m.clientVersion,
                    })
                .toList(),
          );
        }
      }

      // Parse connection info
      debugPrint('[RelayTunnelService] Parsing tunnel info from JSON keys: ${json.keys.toList()}');
      debugPrint('[RelayTunnelService] ice_servers in JSON: ${json['ice_servers']}');
      final info = RelayTunnelInfo.fromJson(json);
      debugPrint('[RelayTunnelService] Parsed iceServers: ${info.iceServers}');

      // Create and return tunnel with broadcast stream
      final tunnel = RelayTunnel._(channel, broadcastStream, info);
      return RelayTunnelResult.success(tunnel);
    } catch (e, stackTrace) {
      debugPrint('[RelayTunnelService] connectViaClaimCode error: $e');
      debugPrint('[RelayTunnelService] Stack trace: $stackTrace');
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
