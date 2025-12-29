/// Phoenix Channel service for WebSocket communication.
///
/// This service manages WebSocket connections to the Mydia server using Phoenix Channels.
/// It handles connecting to the server, joining channels, and managing message exchange.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:phoenix_socket/phoenix_socket.dart';

/// Result type for channel operations.
class ChannelResult<T> {
  final bool success;
  final T? data;
  final String? error;

  const ChannelResult._({
    required this.success,
    this.data,
    this.error,
  });

  factory ChannelResult.success(T data) {
    return ChannelResult._(success: true, data: data);
  }

  factory ChannelResult.error(String error) {
    return ChannelResult._(success: false, error: error);
  }
}

/// Service for managing Phoenix Channel WebSocket connections.
///
/// This service provides methods to:
/// - Connect to the server's WebSocket endpoint
/// - Join pairing and reconnection channels
/// - Send and receive messages over channels
///
/// ## Usage
///
/// ```dart
/// final service = ChannelService();
/// await service.connect('wss://mydia.example.com/ws/websocket');
/// final channel = await service.joinPairingChannel();
/// ```
class ChannelService {
  PhoenixSocket? _socket;
  PhoenixChannel? _activeChannel;

  /// Whether the socket is currently connected.
  bool get isConnected => _socket?.isConnected ?? false;

  /// Connects to the Phoenix WebSocket endpoint.
  ///
  /// The [serverUrl] should be the base URL of the server (e.g., 'https://mydia.example.com').
  /// This method will construct the WebSocket URL automatically.
  ///
  /// Returns a [ChannelResult] indicating success or failure.
  Future<ChannelResult<void>> connect(String serverUrl) async {
    try {
      // Close existing connection if any
      await disconnect();

      // Convert https:// to wss:// and http:// to ws://
      final wsUrl = _buildWebSocketUrl(serverUrl);
      debugPrint('[ChannelService] Connecting to $wsUrl...');

      // Create Phoenix socket
      _socket = PhoenixSocket(
        wsUrl,
        socketOptions: PhoenixSocketOptions(
          timeout: const Duration(seconds: 10),
        ),
      );

      debugPrint('[ChannelService] Socket connecting...');
      // Connect to the socket
      await _socket!.connect();

      // Wait a bit for connection to establish
      await Future.delayed(const Duration(milliseconds: 500));

      if (!_socket!.isConnected) {
        debugPrint('[ChannelService] Socket NOT connected after delay');
        return ChannelResult.error('Failed to establish WebSocket connection');
      }

      debugPrint('[ChannelService] Socket connected!');
      return ChannelResult.success(null);
    } catch (e) {
      debugPrint('[ChannelService] Connection error: $e');
      return ChannelResult.error('Connection error: $e');
    }
  }

  /// Disconnects from the WebSocket.
  Future<void> disconnect() async {
    if (_activeChannel != null) {
      _activeChannel!.leave();
      _activeChannel = null;
    }

    if (_socket != null) {
      _socket!.dispose();
      _socket = null;
    }
  }

  /// Joins the device pairing channel.
  ///
  /// This channel is used for initial device pairing using the Noise_NK protocol.
  /// The server will initialize a handshake when the client joins.
  ///
  /// Returns a [ChannelResult] with the joined channel on success.
  Future<ChannelResult<PhoenixChannel>> joinPairingChannel() async {
    debugPrint('[ChannelService] Joining pairing channel...');
    if (_socket == null || !_socket!.isConnected) {
      debugPrint('[ChannelService] ERROR: Not connected to server');
      return ChannelResult.error('Not connected to server');
    }

    try {
      // Leave any existing channel
      if (_activeChannel != null) {
        debugPrint('[ChannelService] Leaving existing channel...');
        _activeChannel!.leave();
      }

      // Create and join the pairing channel
      debugPrint('[ChannelService] Creating channel device:pair...');
      final channel = _socket!.addChannel(topic: 'device:pair');
      debugPrint('[ChannelService] Calling channel.join()...');
      final push = channel.join();
      debugPrint('[ChannelService] Awaiting join().future...');

      // Use the Push.future property to properly await the join response
      final response = await push.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[ChannelService] TIMEOUT waiting for channel join');
          throw TimeoutException('Channel join timed out');
        },
      );

      debugPrint('[ChannelService] Got join response: ${response.status} - ${response.response}');

      if (response.isOk) {
        debugPrint('[ChannelService] Channel joined successfully!');
        _activeChannel = channel;
        return ChannelResult.success(channel);
      } else {
        final error = response.response?['reason'] ?? 'Unknown error';
        debugPrint('[ChannelService] Channel join failed: $error');
        return ChannelResult.error('Failed to join pairing channel: $error');
      }
    } on TimeoutException {
      debugPrint('[ChannelService] Channel join timed out');
      return ChannelResult.error('Failed to join pairing channel: timeout');
    } catch (e) {
      debugPrint('[ChannelService] Exception joining channel: $e');
      return ChannelResult.error('Error joining pairing channel: $e');
    }
  }

  /// Joins the device reconnection channel.
  ///
  /// This channel is used for reconnecting paired devices using the Noise_IK protocol.
  /// The server will initialize a handshake when the client joins.
  ///
  /// Returns a [ChannelResult] with the joined channel on success.
  Future<ChannelResult<PhoenixChannel>> joinReconnectChannel() async {
    debugPrint('[ChannelService] Joining reconnect channel...');
    if (_socket == null || !_socket!.isConnected) {
      debugPrint('[ChannelService] ERROR: Not connected to server');
      return ChannelResult.error('Not connected to server');
    }

    try {
      // Leave any existing channel
      if (_activeChannel != null) {
        debugPrint('[ChannelService] Leaving existing channel...');
        _activeChannel!.leave();
      }

      // Create and join the reconnect channel
      debugPrint('[ChannelService] Creating channel device:reconnect...');
      final channel = _socket!.addChannel(topic: 'device:reconnect');
      debugPrint('[ChannelService] Calling channel.join()...');
      final push = channel.join();
      debugPrint('[ChannelService] Awaiting join().future...');

      // Use the Push.future property to properly await the join response
      final response = await push.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[ChannelService] TIMEOUT waiting for channel join');
          throw TimeoutException('Channel join timed out');
        },
      );

      debugPrint('[ChannelService] Got join response: ${response.status} - ${response.response}');

      if (response.isOk) {
        debugPrint('[ChannelService] Channel joined successfully!');
        _activeChannel = channel;
        return ChannelResult.success(channel);
      } else {
        final error = response.response?['reason'] ?? 'Unknown error';
        debugPrint('[ChannelService] Channel join failed: $error');
        return ChannelResult.error('Failed to join reconnect channel: $error');
      }
    } on TimeoutException {
      debugPrint('[ChannelService] Channel join timed out');
      return ChannelResult.error('Failed to join reconnect channel: timeout');
    } catch (e) {
      debugPrint('[ChannelService] Exception joining channel: $e');
      return ChannelResult.error('Error joining reconnect channel: $e');
    }
  }

  /// Sends a pairing handshake message.
  ///
  /// The [channel] should be a pairing channel obtained from [joinPairingChannel].
  /// The [message] is the Noise handshake message as bytes.
  ///
  /// Returns a [ChannelResult] with the server's response message on success.
  Future<ChannelResult<Uint8List>> sendPairingHandshake(
    PhoenixChannel channel,
    Uint8List message,
  ) async {
    debugPrint('[ChannelService] Sending pairing_handshake...');
    try {
      final push = channel.push(
        'pairing_handshake',
        {'message': base64Encode(message)},
      );

      // Use the Push.future property to properly await the response
      final response = await push.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[ChannelService] TIMEOUT waiting for handshake response');
          throw TimeoutException('Handshake timed out');
        },
      );

      debugPrint('[ChannelService] Got handshake response: ${response.status}');

      if (response.isOk) {
        final messageB64 = response.response?['message'] as String?;
        if (messageB64 == null) {
          debugPrint('[ChannelService] No message in handshake response');
          return ChannelResult.error('No message in response');
        }
        debugPrint('[ChannelService] Handshake successful!');
        return ChannelResult.success(
            Uint8List.fromList(base64Decode(messageB64)));
      } else {
        final error = response.response?['reason'] ?? 'Unknown error';
        debugPrint('[ChannelService] Handshake failed: $error');
        return ChannelResult.error('Handshake failed: $error');
      }
    } on TimeoutException {
      debugPrint('[ChannelService] Handshake timed out');
      return ChannelResult.error('Handshake failed: timeout');
    } catch (e) {
      debugPrint('[ChannelService] Exception in handshake: $e');
      return ChannelResult.error('Error sending handshake: $e');
    }
  }

  /// Sends a reconnection handshake message.
  ///
  /// The [channel] should be a reconnect channel obtained from [joinReconnectChannel].
  /// The [message] is the Noise handshake message as bytes.
  ///
  /// Returns a [ChannelResult] with the server's response containing the handshake
  /// response message, media token, and device ID.
  Future<ChannelResult<ReconnectResponse>> sendReconnectHandshake(
    PhoenixChannel channel,
    Uint8List message,
  ) async {
    debugPrint('[ChannelService] Sending handshake_init for reconnect...');
    try {
      final push = channel.push(
        'handshake_init',
        {'message': base64Encode(message)},
      );

      // Use the Push.future property to properly await the response
      final response = await push.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[ChannelService] TIMEOUT waiting for reconnect handshake');
          throw TimeoutException('Reconnect handshake timed out');
        },
      );

      debugPrint('[ChannelService] Got reconnect response: ${response.status}');

      if (response.isOk) {
        final responseData = response.response;
        if (responseData == null) {
          debugPrint('[ChannelService] No response data');
          return ChannelResult.error('No response data');
        }

        final messageB64 = responseData['message'] as String?;
        final token = responseData['token'] as String?;
        final deviceId = responseData['device_id'] as String?;

        if (messageB64 == null || token == null || deviceId == null) {
          debugPrint('[ChannelService] Incomplete response data');
          return ChannelResult.error('Incomplete response data');
        }

        debugPrint('[ChannelService] Reconnect handshake successful!');
        return ChannelResult.success(
          ReconnectResponse(
            message: Uint8List.fromList(base64Decode(messageB64)),
            mediaToken: token,
            deviceId: deviceId,
          ),
        );
      } else {
        final error = response.response?['reason'] ?? 'Unknown error';
        debugPrint('[ChannelService] Reconnect handshake failed: $error');
        return ChannelResult.error('Handshake failed: $error');
      }
    } on TimeoutException {
      debugPrint('[ChannelService] Reconnect handshake timed out');
      return ChannelResult.error('Handshake failed: timeout');
    } catch (e) {
      debugPrint('[ChannelService] Exception in reconnect handshake: $e');
      return ChannelResult.error('Error sending handshake: $e');
    }
  }

  /// Submits a claim code to complete pairing.
  ///
  /// The [channel] should be a pairing channel with a completed handshake.
  /// The [claimCode] is the user-provided pairing code.
  /// The [deviceName] is a friendly name for this device.
  /// The [platform] identifies the device platform (e.g., 'android', 'ios', 'web').
  ///
  /// Returns a [ChannelResult] with the pairing credentials on success.
  Future<ChannelResult<PairingResponse>> submitClaimCode(
    PhoenixChannel channel, {
    required String claimCode,
    required String deviceName,
    required String platform,
  }) async {
    debugPrint('[ChannelService] Submitting claim_code...');
    try {
      final push = channel.push('claim_code', {
        'code': claimCode,
        'device_name': deviceName,
        'platform': platform,
      });

      // Use the Push.future property to properly await the response
      final response = await push.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[ChannelService] TIMEOUT waiting for claim_code response');
          throw TimeoutException('Claim code submission timed out');
        },
      );

      debugPrint('[ChannelService] Got claim_code response: ${response.status}');

      if (response.isOk) {
        final responseData = response.response;
        if (responseData == null) {
          debugPrint('[ChannelService] No response data');
          return ChannelResult.error('No response data');
        }

        final deviceId = responseData['device_id'] as String?;
        final mediaToken = responseData['media_token'] as String?;
        final devicePublicKeyB64 = responseData['device_public_key'] as String?;
        final devicePrivateKeyB64 =
            responseData['device_private_key'] as String?;

        if (deviceId == null ||
            mediaToken == null ||
            devicePublicKeyB64 == null ||
            devicePrivateKeyB64 == null) {
          debugPrint('[ChannelService] Incomplete pairing response');
          return ChannelResult.error('Incomplete pairing response');
        }

        debugPrint('[ChannelService] Claim code submission successful!');
        return ChannelResult.success(
          PairingResponse(
            deviceId: deviceId,
            mediaToken: mediaToken,
            devicePublicKey:
                Uint8List.fromList(base64Decode(devicePublicKeyB64)),
            devicePrivateKey:
                Uint8List.fromList(base64Decode(devicePrivateKeyB64)),
          ),
        );
      } else {
        final error = response.response?['reason'] ?? 'Unknown error';
        debugPrint('[ChannelService] Claim code failed: $error');
        return ChannelResult.error(_formatErrorReason(error));
      }
    } on TimeoutException {
      debugPrint('[ChannelService] Claim code submission timed out');
      return ChannelResult.error('Claim code submission timed out');
    } catch (e) {
      debugPrint('[ChannelService] Exception submitting claim code: $e');
      return ChannelResult.error('Error submitting claim code: $e');
    }
  }

  // Helper methods

  String _buildWebSocketUrl(String serverUrl) {
    // Remove trailing slash
    final baseUrl = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    // Convert protocol
    String wsUrl;
    if (baseUrl.startsWith('https://')) {
      wsUrl = baseUrl.replaceFirst('https://', 'wss://');
    } else if (baseUrl.startsWith('http://')) {
      wsUrl = baseUrl.replaceFirst('http://', 'ws://');
    } else if (baseUrl.startsWith('wss://') || baseUrl.startsWith('ws://')) {
      wsUrl = baseUrl;
    } else {
      // Assume https
      wsUrl = 'wss://$baseUrl';
    }

    // Append WebSocket path (Phoenix channel is mounted at /ws)
    return '$wsUrl/ws/websocket';
  }

  String _formatErrorReason(String reason) {
    switch (reason) {
      case 'invalid_claim_code':
        return 'Invalid claim code';
      case 'claim_code_used':
        return 'This claim code has already been used';
      case 'claim_code_expired':
        return 'This claim code has expired';
      case 'handshake_incomplete':
        return 'Handshake must be completed before submitting claim code';
      case 'device_creation_failed':
        return 'Failed to create device registration';
      case 'device_not_found':
        return 'Device not found';
      case 'device_revoked':
        return 'Device has been revoked';
      case 'handshake_failed':
        return 'Handshake failed';
      case 'invalid_message':
        return 'Invalid message format';
      default:
        return reason;
    }
  }
}

/// Response from a successful pairing operation.
class PairingResponse {
  /// The device ID assigned by the server.
  final String deviceId;

  /// The media access token for API requests.
  final String mediaToken;

  /// The device's public key (32 bytes).
  final Uint8List devicePublicKey;

  /// The device's private key (32 bytes).
  final Uint8List devicePrivateKey;

  const PairingResponse({
    required this.deviceId,
    required this.mediaToken,
    required this.devicePublicKey,
    required this.devicePrivateKey,
  });
}

/// Response from a successful reconnection operation.
class ReconnectResponse {
  /// The server's handshake response message.
  final Uint8List message;

  /// The refreshed media access token.
  final String mediaToken;

  /// The device ID.
  final String deviceId;

  const ReconnectResponse({
    required this.message,
    required this.mediaToken,
    required this.deviceId,
  });
}
