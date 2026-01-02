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
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart' show debugPrint;
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
  late final Map<String, Completer<TunnelResponse>> _pendingRequests;
  int _requestCounter = 0;

  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  bool _pendingHeartbeat = false;

  /// Session key for end-to-end encryption (null before handshake).
  SecretKey? _sessionKey;

  /// ChaCha20-Poly1305 cipher for encryption/decryption.
  final _cipher = DartCryptography.defaultInstance.chacha20Poly1305Aead();

  /// Whether encryption is enabled (handshake complete).
  bool get isEncryptionEnabled => _sessionKey != null;

  /// Information about this tunnel connection.
  RelayTunnelInfo get info => _info;

  /// Stream of incoming messages from the instance.
  Stream<Uint8List> get messages => _messageController.stream;

  /// Stream of error messages.
  Stream<String> get errors => _errorController.stream;

  /// Whether the tunnel is still active.
  bool get isActive => !_messageController.isClosed;

  /// Enables end-to-end encryption for all subsequent messages.
  ///
  /// This should be called after the handshake is complete. Once enabled,
  /// all messages sent via [sendMessage], [sendJsonMessage], and [request]
  /// will be encrypted, and all incoming messages will be decrypted.
  ///
  /// ## Parameters
  ///
  /// - [sessionKeyBytes] - The 32-byte session key derived from the handshake.
  ///
  /// ## Example
  ///
  /// ```dart
  /// // After handshake completes
  /// final sessionKey = await cryptoManager.getSessionKeyBytes();
  /// tunnel.enableEncryption(sessionKey!);
  ///
  /// // All subsequent messages are now encrypted
  /// await tunnel.sendJsonMessage('{"type": "claim_code", ...}');
  /// ```
  void enableEncryption(Uint8List sessionKeyBytes) {
    if (sessionKeyBytes.length != 32) {
      throw ArgumentError(
        'Session key must be 32 bytes, got ${sessionKeyBytes.length}',
      );
    }
    _sessionKey = SecretKey(sessionKeyBytes);

    // Debug: Log session key fingerprint for cross-platform crypto troubleshooting
    final sessionKeyHex = sessionKeyBytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    debugPrint(
      '[RelayTunnel] Encryption enabled: session=${_info.sessionId}, session_key_first8=$sessionKeyHex',
    );
  }

  /// Sends a JSON message to the instance through the tunnel.
  ///
  /// If encryption is enabled, the message will be automatically encrypted
  /// before sending. This is the preferred method for sending messages after
  /// the handshake is complete.
  ///
  /// ## Parameters
  ///
  /// - [jsonMessage] - The JSON string to send.
  ///
  /// ## Example
  ///
  /// ```dart
  /// await tunnel.sendJsonMessage(jsonEncode({
  ///   'type': 'claim_code',
  ///   'data': {'code': 'ABC123', 'device_name': 'My Phone', 'platform': 'ios'},
  /// }));
  /// ```
  Future<void> sendJsonMessage(String jsonMessage) async {
    if (!isActive) {
      throw StateError('Tunnel is closed');
    }

    String payload;
    if (_sessionKey != null) {
      // Encrypt the message
      final keyBytes = await _sessionKey!.extractBytes();
      final sessionKeyHex = keyBytes
          .take(8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      debugPrint(
        '[RelayTunnel] sendJsonMessage: encrypting with session_key_first8=$sessionKeyHex',
      );
      payload = await _encryptMessage(jsonMessage);
      debugPrint('[RelayTunnel] Sending encrypted message (${payload.length} chars)');
    } else {
      // Send plaintext (only during handshake)
      payload = base64Encode(utf8.encode(jsonMessage));
      debugPrint('[RelayTunnel] sendJsonMessage: NO SESSION KEY - sending plaintext!');
    }

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
    } catch (e) {
      // Ignore errors when closing
    }

    await _channel.sink.close();
    await _messageController.close();
    await _errorController.close();
  }

  /// Sends an HTTP request through the tunnel.
  ///
  /// This method proxies HTTP requests through the relay tunnel to the
  /// Mydia instance, allowing API communication when direct connection
  /// is not possible.
  ///
  /// ## Parameters
  ///
  /// - [method] - HTTP method (GET, POST, PUT, DELETE, etc.)
  /// - [path] - Request path (e.g., '/api/graphql')
  /// - [headers] - Optional request headers
  /// - [body] - Optional request body
  ///
  /// ## Returns
  ///
  /// A [TunnelResponse] containing the response status, headers, and body.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final response = await tunnel.request(
  ///   method: 'POST',
  ///   path: '/api/graphql',
  ///   headers: {'Content-Type': 'application/json'},
  ///   body: '{"query": "{ me { id } }"}',
  /// );
  /// if (response.isSuccess) {
  ///   print('Response: ${response.bodyAsString}');
  /// }
  /// ```
  Future<TunnelResponse> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    String? body,
  }) async {
    if (!isActive) {
      throw StateError('Tunnel is closed');
    }

    // Generate unique request ID
    final requestId = '${_info.sessionId}-${++_requestCounter}';

    // Create completer for the response
    final completer = Completer<TunnelResponse>();
    _pendingRequests[requestId] = completer;

    // Build and send request message
    final requestMessage = jsonEncode({
      'type': 'request',
      'id': requestId,
      'method': method,
      'path': path,
      'headers': headers ?? {},
      'body': body,
    });

    try {
      // Encrypt if encryption is enabled
      String payload;
      if (_sessionKey != null) {
        payload = await _encryptMessage(requestMessage);
        debugPrint('[RelayTunnel] Sending encrypted request: $method $path');
      } else {
        payload = base64Encode(utf8.encode(requestMessage));
      }

      final wrappedMessage = jsonEncode({
        'type': 'message',
        'payload': payload,
      });
      _channel.sink.add(wrappedMessage);
    } catch (e) {
      _pendingRequests.remove(requestId);
      rethrow;
    }

    // Wait for response with timeout
    try {
      return await completer.future.timeout(
        _requestTimeout,
        onTimeout: () {
          _pendingRequests.remove(requestId);
          return const TunnelResponse(
            status: 504,
            headers: {},
            body: '{"error": "Request timeout"}',
          );
        },
      );
    } catch (e) {
      _pendingRequests.remove(requestId);
      rethrow;
    }
  }

  /// Starts the periodic heartbeat mechanism.
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
        case 'message':
          final payloadB64 = json['payload'] as String?;
          if (payloadB64 == null) {
            _errorController.add('Message missing payload');
            return;
          }

          // If encryption is enabled, decrypt the payload
          String payloadString;
          if (_sessionKey != null) {
            try {
              // Debug: Log session key for cross-platform crypto troubleshooting
              final keyBytes = await _sessionKey!.extractBytes();
              final sessionKeyHex = keyBytes
                  .take(8)
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join();
              debugPrint(
                '[RelayTunnel] Attempting decryption: payload_size=${payloadB64.length}, session_key_first8=$sessionKeyHex',
              );
              payloadString = await _decryptMessage(payloadB64);
              debugPrint('[RelayTunnel] Decrypted incoming message successfully');
            } catch (e) {
              // Log session key on failure for debugging
              final keyBytes = await _sessionKey!.extractBytes();
              final sessionKeyHex = keyBytes
                  .take(8)
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join();
              debugPrint(
                '[RelayTunnel] Decryption FAILED: $e, session_key_first8=$sessionKeyHex',
              );
              _errorController.add('Failed to decrypt message: $e');
              return;
            }
          } else {
            // No encryption - decode as plaintext
            final payload = Uint8List.fromList(base64Decode(payloadB64));
            payloadString = utf8.decode(payload);
          }

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

  // ============================================================================
  // End-to-End Encryption Methods
  // ============================================================================

  /// Direction for AAD binding.
  /// - toServer: client→server messages
  /// - toClient: server→client messages

  /// Builds AAD (Additional Authenticated Data) for encryption/decryption.
  ///
  /// Format: "{session_id}:{direction}"
  /// This binds the ciphertext to a specific session and direction,
  /// preventing cross-session and reflection attacks.
  List<int> _buildAad({required bool toServer}) {
    final direction = toServer ? 'to-server' : 'to-client';
    return utf8.encode('${_info.sessionId}:$direction');
  }

  /// Encrypts a JSON message for transmission.
  ///
  /// Returns base64(nonce || ciphertext || mac) as expected by the server.
  /// AAD format: "{session_id}:to-server" for client→server messages.
  Future<String> _encryptMessage(String jsonMessage) async {
    if (_sessionKey == null) {
      throw StateError('Encryption not enabled');
    }

    final plaintextBytes = utf8.encode(jsonMessage);
    final aad = _buildAad(toServer: true);

    // Generate 12-byte nonce using secure random
    final random = Random.secure();
    final nonce = Uint8List(_nonceSize);
    for (var i = 0; i < _nonceSize; i++) {
      nonce[i] = random.nextInt(256);
    }

    final secretBox = await _cipher.encrypt(
      plaintextBytes,
      secretKey: _sessionKey!,
      nonce: nonce,
      aad: aad,
    );

    // Wire format: nonce (12 bytes) || ciphertext || mac (16 bytes)
    final payload = Uint8List.fromList([
      ...nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return base64Encode(payload);
  }

  /// Decrypts a base64-encoded encrypted message from the server.
  ///
  /// Expects base64(nonce || ciphertext || mac) format.
  /// AAD format: "{session_id}:to-client" for server→client messages.
  Future<String> _decryptMessage(String base64Payload) async {
    if (_sessionKey == null) {
      throw StateError('Encryption not enabled');
    }

    final binary = base64Decode(base64Payload);
    final aad = _buildAad(toServer: false);

    // Minimum size: 12 (nonce) + 0 (empty ciphertext) + 16 (mac) = 28 bytes
    if (binary.length < _nonceSize + _macSize) {
      throw ArgumentError(
        'Payload too short: expected at least ${_nonceSize + _macSize} bytes, got ${binary.length}',
      );
    }

    // Extract components: nonce (12 bytes) || ciphertext || mac (16 bytes)
    final nonce = Uint8List.fromList(binary.sublist(0, _nonceSize));
    final ciphertextWithMac = binary.sublist(_nonceSize);
    final macStart = ciphertextWithMac.length - _macSize;
    final ciphertext = Uint8List.fromList(ciphertextWithMac.sublist(0, macStart));
    final mac = Uint8List.fromList(ciphertextWithMac.sublist(macStart));

    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: Mac(mac),
    );

    final plaintextBytes = await _cipher.decrypt(
      secretBox,
      secretKey: _sessionKey!,
      aad: aad,
    );

    return utf8.decode(plaintextBytes);
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
        final errorMsg = json['message'] as String? ?? 'Connection failed';
        await channel.sink.close();
        return RelayTunnelResult.error(errorMsg);
      }

      if (type != 'connected') {
        await channel.sink.close();
        return RelayTunnelResult.error('Unexpected response type: $type');
      }

      debugPrint('[RelayTunnelService] Received connected response');

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
