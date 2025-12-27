/// Device pairing service using Noise protocol and Phoenix Channels.
///
/// This service orchestrates the complete device pairing flow:
/// 1. Look up claim code via relay to get instance info
/// 2. Connect to server WebSocket (using direct URLs from relay)
/// 3. Join pairing channel
/// 4. Perform Noise_NK handshake
/// 5. Submit claim code
/// 6. Receive and store device credentials
/// 7. Consume claim on relay to mark it as used
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'channel_service.dart';
import '../crypto/noise_service.dart';
import '../auth/auth_storage.dart';
import '../relay/relay_service.dart';
import '../connection/connection_manager.dart';

/// Storage keys for pairing credentials.
abstract class _StorageKeys {
  static const serverUrl = 'pairing_server_url';
  static const deviceId = 'pairing_device_id';
  static const mediaToken = 'pairing_media_token';
  static const devicePublicKey = 'pairing_device_public_key';
  static const devicePrivateKey = 'pairing_device_private_key';
  static const directUrls = 'pairing_direct_urls';
  static const certFingerprint = 'pairing_cert_fingerprint';
  static const instanceName = 'pairing_instance_name';
  static const serverPublicKey = 'server_public_key';
  static const instanceId = 'instance_id';
}

/// Result of a pairing operation.
class PairingResult {
  final bool success;
  final String? error;
  final PairingCredentials? credentials;

  const PairingResult._({
    required this.success,
    this.error,
    this.credentials,
  });

  factory PairingResult.success(PairingCredentials credentials) {
    return PairingResult._(success: true, credentials: credentials);
  }

  factory PairingResult.error(String error) {
    return PairingResult._(success: false, error: error);
  }
}

/// Credentials obtained from successful pairing.
class PairingCredentials {
  /// The server URL.
  final String serverUrl;

  /// The device ID assigned by the server.
  final String deviceId;

  /// The media access token for API requests.
  final String mediaToken;

  /// The device's public key (32 bytes).
  final Uint8List devicePublicKey;

  /// The device's private key (32 bytes).
  final Uint8List devicePrivateKey;

  /// The server's static public key (32 bytes).
  final Uint8List serverPublicKey;

  /// Direct URLs for connecting to the instance.
  final List<String> directUrls;

  /// Certificate fingerprint for TLS validation.
  final String? certFingerprint;

  /// Instance name (friendly identifier).
  final String? instanceName;

  /// Instance ID for relay connections.
  final String? instanceId;

  const PairingCredentials({
    required this.serverUrl,
    required this.deviceId,
    required this.mediaToken,
    required this.devicePublicKey,
    required this.devicePrivateKey,
    required this.serverPublicKey,
    required this.directUrls,
    this.certFingerprint,
    this.instanceName,
    this.instanceId,
  });
}

/// Service for pairing new devices with a Mydia server.
///
/// This service handles the complete pairing flow using the Noise_NK protocol
/// over Phoenix Channels. It integrates with [NoiseService] for cryptographic
/// operations and [AuthStorage] for credential persistence.
///
/// ## Pairing Flow
///
/// 1. User obtains server URL and claim code (from QR code or manual entry)
/// 2. [pairDevice] connects to server WebSocket
/// 3. Joins the `device:pair` channel
/// 4. Performs Noise_NK handshake with server
/// 5. Submits claim code and device info
/// 6. Receives device credentials (keypair and tokens)
/// 7. Stores credentials securely
///
/// ## Usage
///
/// ```dart
/// final pairingService = PairingService();
/// final result = await pairingService.pairDevice(
///   serverUrl: 'https://mydia.example.com',
///   claimCode: 'ABCD-1234',
///   deviceName: 'My Phone',
/// );
///
/// if (result.success) {
///   print('Paired successfully!');
/// } else {
///   print('Pairing failed: ${result.error}');
/// }
/// ```
class PairingService {
  PairingService({
    ChannelService? channelService,
    NoiseService? noiseService,
    AuthStorage? authStorage,
    RelayService? relayService,
    ConnectionManager? connectionManager,
  })  : _channelService = channelService ?? ChannelService(),
        _noiseService = noiseService ?? NoiseService(),
        _authStorage = authStorage ?? getAuthStorage(),
        _relayService = relayService ?? RelayService(),
        _connectionManager = connectionManager;

  final ChannelService _channelService;
  final NoiseService _noiseService;
  final AuthStorage _authStorage;
  final RelayService _relayService;
  final ConnectionManager? _connectionManager;

  /// Pairs this device using only a claim code.
  ///
  /// This is the primary pairing method. It:
  /// 1. Looks up the claim code via the relay service
  /// 2. Gets the instance's direct URLs and public key
  /// 3. Connects to the first available direct URL
  /// 4. Submits the claim code to complete pairing
  /// 5. Marks the claim as consumed on the relay
  ///
  /// ## Parameters
  ///
  /// - [claimCode]: The pairing claim code (e.g., 'ABC123')
  /// - [deviceName]: A friendly name for this device (e.g., 'My iPhone')
  /// - [platform]: The device platform (defaults to detected platform)
  /// - [onStatusUpdate]: Optional callback for status updates
  ///
  /// Returns a [PairingResult] indicating success or failure.
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();

      // Step 1: Look up claim code via relay
      onStatusUpdate?.call('Looking up claim code...');
      final lookupResult = await _relayService.lookupClaimCode(claimCode);

      if (!lookupResult.success) {
        return PairingResult.error(
            lookupResult.error ?? 'Failed to lookup claim code');
      }

      final claimInfo = lookupResult.data!;

      if (claimInfo.directUrls.isEmpty) {
        return PairingResult.error(
            'Server has no direct URLs configured. Please contact your administrator.');
      }

      // Decode the server's public key
      final serverPublicKey = _base64ToBytes(claimInfo.publicKey);

      // Step 2: Try each direct URL until one works
      onStatusUpdate?.call('Connecting to server...');
      String? connectedUrl;

      for (final url in claimInfo.directUrls) {
        final connectResult = await _channelService.connect(url);
        if (connectResult.success) {
          connectedUrl = url;
          break;
        }
      }

      if (connectedUrl == null) {
        return PairingResult.error(
            'Could not connect to server. Please check your network connection.');
      }

      // Step 3: Join pairing channel
      onStatusUpdate?.call('Joining pairing channel...');
      final joinResult = await _channelService.joinPairingChannel();
      if (!joinResult.success) {
        await _channelService.disconnect();
        return PairingResult.error(
            joinResult.error ?? 'Failed to join pairing channel');
      }
      final channel = joinResult.data!;

      // Step 4: Perform Noise_NK handshake
      onStatusUpdate?.call('Establishing secure connection...');
      final noiseSession =
          await _noiseService.startPairingHandshake(serverPublicKey);

      // Send handshake message to server
      final handshakeMessage = await noiseSession.writeHandshakeMessage();
      final handshakeResult = await _channelService.sendPairingHandshake(
        channel,
        handshakeMessage,
      );

      if (!handshakeResult.success) {
        await _channelService.disconnect();
        return PairingResult.error(
            handshakeResult.error ?? 'Handshake failed');
      }

      // Process server's handshake response
      await noiseSession.readHandshakeMessage(handshakeResult.data!);

      if (!noiseSession.isComplete) {
        await _channelService.disconnect();
        return PairingResult.error('Handshake incomplete');
      }

      // Step 5: Submit claim code
      onStatusUpdate?.call('Submitting claim code...');
      final claimResult = await _channelService.submitClaimCode(
        channel,
        claimCode: claimCode,
        deviceName: deviceName,
        platform: devicePlatform,
      );

      await _channelService.disconnect();

      if (!claimResult.success) {
        return PairingResult.error(
            claimResult.error ?? 'Failed to submit claim code');
      }

      final response = claimResult.data!;

      // Step 6: Store credentials
      final credentials = PairingCredentials(
        serverUrl: connectedUrl,
        deviceId: response.deviceId,
        mediaToken: response.mediaToken,
        devicePublicKey: response.devicePublicKey,
        devicePrivateKey: response.devicePrivateKey,
        serverPublicKey: serverPublicKey,
        directUrls: claimInfo.directUrls,
        certFingerprint: null, // TODO: Add cert_fingerprint to relay response
        instanceName: null, // TODO: Add instance_name to relay response
        instanceId: claimInfo.instanceId,
      );

      await _storeCredentials(credentials);

      // Step 7: Mark claim as consumed on relay
      onStatusUpdate?.call('Finalizing...');
      await _relayService.consumeClaim(claimInfo.claimId, response.deviceId);

      // Step 8: Attempt to switch to direct connection
      if (_connectionManager != null && credentials.directUrls.isNotEmpty) {
        onStatusUpdate?.call('Testing direct connection...');
        await _attemptDirectConnection(credentials);
      }

      return PairingResult.success(credentials);
    } catch (e) {
      await _channelService.disconnect();
      return PairingResult.error('Pairing error: $e');
    }
  }

  /// Pairs this device with a Mydia server.
  ///
  /// ## Parameters
  ///
  /// - [serverUrl]: The base URL of the Mydia server (e.g., 'https://mydia.example.com')
  /// - [serverPublicKey]: The server's static public key (32 bytes) obtained from QR code
  /// - [claimCode]: The pairing claim code entered by the user
  /// - [deviceName]: A friendly name for this device (e.g., 'My iPhone')
  /// - [platform]: The device platform (defaults to detected platform)
  ///
  /// Returns a [PairingResult] indicating success or failure.
  Future<PairingResult> pairDevice({
    required String serverUrl,
    required Uint8List serverPublicKey,
    required String claimCode,
    required String deviceName,
    String? platform,
  }) async {
    try {
      // Detect platform if not provided
      final devicePlatform = platform ?? _detectPlatform();

      // Step 1: Connect to server WebSocket
      final connectResult = await _channelService.connect(serverUrl);
      if (!connectResult.success) {
        return PairingResult.error(
            connectResult.error ?? 'Failed to connect to server');
      }

      // Step 2: Join pairing channel
      final joinResult = await _channelService.joinPairingChannel();
      if (!joinResult.success) {
        await _channelService.disconnect();
        return PairingResult.error(
            joinResult.error ?? 'Failed to join pairing channel');
      }
      final channel = joinResult.data!;

      // Step 3: Perform Noise_NK handshake
      final noiseSession =
          await _noiseService.startPairingHandshake(serverPublicKey);

      // Generate and send handshake message
      final firstMessage = await noiseSession.writeHandshakeMessage();
      final handshakeResult =
          await _channelService.sendPairingHandshake(channel, firstMessage);
      if (!handshakeResult.success) {
        await _channelService.disconnect();
        return PairingResult.error(
            handshakeResult.error ?? 'Handshake failed');
      }

      // Process server's handshake response
      await noiseSession.readHandshakeMessage(handshakeResult.data!);

      if (!noiseSession.isComplete) {
        await _channelService.disconnect();
        return PairingResult.error('Handshake incomplete');
      }

      // Step 4: Submit claim code
      final claimResult = await _channelService.submitClaimCode(
        channel,
        claimCode: claimCode,
        deviceName: deviceName,
        platform: devicePlatform,
      );

      await _channelService.disconnect();

      if (!claimResult.success) {
        return PairingResult.error(
            claimResult.error ?? 'Failed to submit claim code');
      }

      final response = claimResult.data!;

      // Step 5: Store credentials
      final credentials = PairingCredentials(
        serverUrl: serverUrl,
        deviceId: response.deviceId,
        mediaToken: response.mediaToken,
        devicePublicKey: response.devicePublicKey,
        devicePrivateKey: response.devicePrivateKey,
        serverPublicKey: serverPublicKey,
        directUrls: [serverUrl], // Use serverUrl as the only direct URL
        certFingerprint: null, // Not available in direct pairing
        instanceName: null, // Not available in direct pairing
        instanceId: null, // Not available in direct pairing
      );

      await _storeCredentials(credentials);

      return PairingResult.success(credentials);
    } catch (e) {
      await _channelService.disconnect();
      return PairingResult.error('Pairing error: $e');
    }
  }

  /// Retrieves stored pairing credentials.
  ///
  /// Returns null if no credentials are stored (device not paired).
  Future<PairingCredentials?> getStoredCredentials() async {
    final serverUrl = await _authStorage.read(_StorageKeys.serverUrl);
    final deviceId = await _authStorage.read(_StorageKeys.deviceId);
    final mediaToken = await _authStorage.read(_StorageKeys.mediaToken);
    final publicKeyB64 = await _authStorage.read(_StorageKeys.devicePublicKey);
    final privateKeyB64 =
        await _authStorage.read(_StorageKeys.devicePrivateKey);
    final serverPublicKeyB64 =
        await _authStorage.read(_StorageKeys.serverPublicKey);
    final directUrlsJson = await _authStorage.read(_StorageKeys.directUrls);
    final certFingerprint =
        await _authStorage.read(_StorageKeys.certFingerprint);
    final instanceName = await _authStorage.read(_StorageKeys.instanceName);
    final instanceId = await _authStorage.read(_StorageKeys.instanceId);

    if (serverUrl == null ||
        deviceId == null ||
        mediaToken == null ||
        publicKeyB64 == null ||
        privateKeyB64 == null ||
        serverPublicKeyB64 == null) {
      return null;
    }

    // Parse direct URLs from JSON, fallback to serverUrl if not available
    List<String> directUrls = [serverUrl];
    if (directUrlsJson != null) {
      try {
        final decoded = jsonDecode(directUrlsJson);
        if (decoded is List) {
          directUrls = decoded.cast<String>();
        }
      } catch (e) {
        // If parsing fails, use fallback
      }
    }

    return PairingCredentials(
      serverUrl: serverUrl,
      deviceId: deviceId,
      mediaToken: mediaToken,
      devicePublicKey: _base64ToBytes(publicKeyB64),
      devicePrivateKey: _base64ToBytes(privateKeyB64),
      serverPublicKey: _base64ToBytes(serverPublicKeyB64),
      directUrls: directUrls,
      certFingerprint: certFingerprint,
      instanceName: instanceName,
      instanceId: instanceId,
    );
  }

  /// Clears stored pairing credentials.
  ///
  /// This effectively unpairs the device.
  Future<void> clearCredentials() async {
    await _authStorage.delete(_StorageKeys.serverUrl);
    await _authStorage.delete(_StorageKeys.deviceId);
    await _authStorage.delete(_StorageKeys.mediaToken);
    await _authStorage.delete(_StorageKeys.devicePublicKey);
    await _authStorage.delete(_StorageKeys.devicePrivateKey);
    await _authStorage.delete(_StorageKeys.serverPublicKey);
    await _authStorage.delete(_StorageKeys.directUrls);
    await _authStorage.delete(_StorageKeys.certFingerprint);
    await _authStorage.delete(_StorageKeys.instanceName);
    await _authStorage.delete(_StorageKeys.instanceId);
  }

  /// Checks if this device is currently paired.
  Future<bool> isPaired() async {
    final credentials = await getStoredCredentials();
    return credentials != null;
  }

  /// Gets the stored connection type preference.
  ///
  /// Returns 'direct', 'relay', or null if no preference is stored.
  /// This can be used by the UI to show the user how they're connected.
  Future<String?> getConnectionType() async {
    return await _authStorage.read('connection_last_type');
  }

  /// Gets the last successful direct URL.
  ///
  /// Returns the URL if a direct connection was previously successful,
  /// or null if relay was used or no connection has been made.
  Future<String?> getLastDirectUrl() async {
    return await _authStorage.read('connection_last_url');
  }

  // Private helpers

  /// Attempts to establish a direct connection after pairing.
  ///
  /// This validates that the direct URLs work and stores the connection
  /// preference for future sessions. If direct connection fails, we silently
  /// fall back to relay on the next connection attempt.
  Future<void> _attemptDirectConnection(PairingCredentials credentials) async {
    final connectionManager = _connectionManager;
    if (connectionManager == null) return;

    try {
      // Try to connect directly using ConnectionManager
      final result = await connectionManager.connect(
        directUrls: credentials.directUrls,
        instanceId: credentials.instanceId ?? '',
        certFingerprint: credentials.certFingerprint,
        relayUrl: null, // Don't fall back to relay during this test
      );

      if (result.success && result.isDirect) {
        // Direct connection successful!
        // ConnectionManager has already stored the preference
        // Close the ChannelService connection if still open
        await _channelService.disconnect();
      }
      // If failed, silently continue - we'll use relay fallback on next connection
    } catch (e) {
      // Ignore errors - this is just a test connection
      // The user can still connect via relay on next app launch
    }
  }

  Future<void> _storeCredentials(PairingCredentials credentials) async {
    await _authStorage.write(_StorageKeys.serverUrl, credentials.serverUrl);
    await _authStorage.write(_StorageKeys.deviceId, credentials.deviceId);
    await _authStorage.write(_StorageKeys.mediaToken, credentials.mediaToken);
    await _authStorage.write(
      _StorageKeys.devicePublicKey,
      _bytesToBase64(credentials.devicePublicKey),
    );
    await _authStorage.write(
      _StorageKeys.devicePrivateKey,
      _bytesToBase64(credentials.devicePrivateKey),
    );
    await _authStorage.write(
      _StorageKeys.serverPublicKey,
      _bytesToBase64(credentials.serverPublicKey),
    );
    await _authStorage.write(
      _StorageKeys.directUrls,
      jsonEncode(credentials.directUrls),
    );
    if (credentials.certFingerprint != null) {
      await _authStorage.write(
        _StorageKeys.certFingerprint,
        credentials.certFingerprint!,
      );
    }
    if (credentials.instanceName != null) {
      await _authStorage.write(
        _StorageKeys.instanceName,
        credentials.instanceName!,
      );
    }
    if (credentials.instanceId != null) {
      await _authStorage.write(
        _StorageKeys.instanceId,
        credentials.instanceId!,
      );
    }
  }

  String _detectPlatform() {
    if (kIsWeb) {
      return 'web';
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      return 'android';
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'ios';
    } else if (defaultTargetPlatform == TargetPlatform.macOS) {
      return 'macos';
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      return 'windows';
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      return 'linux';
    } else {
      return 'unknown';
    }
  }

  // Helper functions for base64 encoding/decoding
  String _bytesToBase64(Uint8List bytes) {
    return base64Encode(bytes);
  }

  Uint8List _base64ToBytes(String str) {
    return Uint8List.fromList(base64Decode(str));
  }
}
