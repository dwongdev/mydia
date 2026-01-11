/// Device pairing service using X25519 key exchange and Phoenix Channels.
///
/// This service orchestrates the complete device pairing flow:
/// 1. Look up claim code via relay to get instance info
/// 2. Connect to server WebSocket (using direct URLs from relay)
/// 3. Join pairing channel
/// 4. Perform X25519 key exchange
/// 5. Submit claim code
/// 6. Receive and store device credentials
/// 7. Consume claim on relay to mark it as used
library pairing_service;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import '../webrtc/webrtc_connection_manager.dart';
import '../auth/auth_storage.dart';
import '../protocol/protocol_version.dart';
import '../relay/relay_service.dart';
import '../relay/relay_tunnel_service.dart';

/// Data parsed from a QR code for device pairing.
///
/// The QR code contains JSON with the following fields:
/// - instance_id: The server's unique instance ID
/// - public_key: The server's static public key (Base64 encoded)
/// - relay_url: The relay service URL
/// - claim_code: The pairing claim code (rotates every 5 minutes)
class QrPairingData {
  /// The server's unique instance ID.
  final String instanceId;

  /// The server's static public key (Base64 encoded).
  final String publicKey;

  /// The relay service URL.
  final String relayUrl;

  /// The pairing claim code.
  final String claimCode;

  const QrPairingData({
    required this.instanceId,
    required this.publicKey,
    required this.relayUrl,
    required this.claimCode,
  });

  /// Parses QR code content into [QrPairingData].
  ///
  /// Returns null if the content is not valid JSON or is missing required fields.
  static QrPairingData? tryParse(String content) {
    try {
      final json = jsonDecode(content) as Map<String, dynamic>;

      final instanceId = json['instance_id'] as String?;
      final publicKey = json['public_key'] as String?;
      final relayUrl = json['relay_url'] as String?;
      final claimCode = json['claim_code'] as String?;

      if (instanceId == null ||
          publicKey == null ||
          relayUrl == null ||
          claimCode == null) {
        return null;
      }

      return QrPairingData(
        instanceId: instanceId,
        publicKey: publicKey,
        relayUrl: relayUrl,
        claimCode: claimCode,
      );
    } catch (e) {
      return null;
    }
  }

  /// Returns the public key as bytes.
  Uint8List get publicKeyBytes => Uint8List.fromList(base64Decode(publicKey));
}

/// Storage keys for pairing credentials.
abstract class _StorageKeys {
  static const serverUrl = 'pairing_server_url';
  static const deviceId = 'pairing_device_id';
  static const mediaToken = 'pairing_media_token';
  static const accessToken = 'pairing_access_token';
  static const deviceToken = 'pairing_device_token';
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

  /// Active WebRTC manager (if pairing was via relay and direct connection failed).
  /// The caller should use this manager for ongoing communication.
  final WebRTCConnectionManager? webrtcManager;

  const PairingResult._({
    required this.success,
    this.error,
    this.credentials,
    this.webrtcManager,
  });

  factory PairingResult.success(PairingCredentials credentials, {WebRTCConnectionManager? webrtcManager}) {
    return PairingResult._(success: true, credentials: credentials, webrtcManager: webrtcManager);
  }

  factory PairingResult.error(String error) {
    return PairingResult._(success: false, error: error);
  }

  /// Whether the pairing used relay mode (no direct connection available).
  bool get isRelayMode => webrtcManager != null;
}

/// Credentials obtained from successful pairing.
class PairingCredentials {
  /// The server URL.
  final String serverUrl;

  /// The device ID assigned by the server.
  final String deviceId;

  /// The media access token for streaming (typ: media_access).
  final String mediaToken;

  /// The access token for GraphQL/API requests (typ: access).
  final String accessToken;

  /// The device token for reconnection authentication.
  ///
  /// This token is used during key exchange to prove device identity
  /// without requiring the claim code again.
  final String? deviceToken;

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
    required this.accessToken,
    this.deviceToken,
    required this.serverPublicKey,
    required this.directUrls,
    this.certFingerprint,
    this.instanceName,
    this.instanceId,
  });
}


/// Service for pairing new devices with a Mydia server.
///
/// This service handles the complete pairing flow using X25519 key exchange
/// over Phoenix Channels. It integrates with [CryptoManager] for cryptographic
/// operations and [AuthStorage] for credential persistence.
///
/// ## Pairing Flow
///
/// 1. User obtains server URL and claim code (from QR code or manual entry)
/// 2. [pairDevice] connects to server WebSocket
/// 3. Joins the `device:pair` channel
/// 4. Performs X25519 key exchange with server
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
    AuthStorage? authStorage,
    RelayService? relayService,
    String? relayUrl,
  })  : _authStorage = authStorage ?? getAuthStorage(),
        _relayService = relayService ?? RelayService(),
        _relayUrl = relayUrl ?? const String.fromEnvironment(
          'RELAY_URL',
          defaultValue: 'https://relay.mydia.dev',
        );

  final AuthStorage _authStorage;
  final RelayService _relayService;
  final String _relayUrl;

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
  /// Pairs this device using only a claim code with relay-first strategy.
  ///
  /// This method always connects via relay tunnel first for guaranteed fast
  /// connection. Direct URL probing happens in the background after pairing
  /// completes (handled by ConnectionManager).
  ///
  /// ## Relay-First Flow
  ///
  /// 1. Looks up the claim code via the relay service
  /// 2. Connects via relay tunnel (guaranteed to work if relay is reachable)
  /// 3. Completes pairing handshake via relay
  /// 4. Returns credentials and active relay tunnel
  /// 5. Background probing will attempt direct connection upgrade later
  ///
  /// ## Parameters
  ///
  /// - [claimCode]: The pairing claim code (e.g., 'ABC123')
  /// - [deviceName]: A friendly name for this device (e.g., 'My iPhone')
  /// - [platform]: The device platform (defaults to detected platform)
  /// - [onStatusUpdate]: Optional callback for status updates
  ///
  /// Returns a [PairingResult] indicating success or failure.
  /// On success, the result includes the active relay tunnel for ongoing
  /// communication until direct connection is established.
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === RELAY-FIRST PAIRING ===');
      debugPrint('[PairingService] claimCode=$claimCode, deviceName=$deviceName, platform=$devicePlatform');

      // Step 1: Look up claim code via relay
      onStatusUpdate?.call('Looking up claim code...');
      final lookupResult = await _relayService.lookupClaimCode(claimCode);
      debugPrint('[PairingService] Lookup result: success=${lookupResult.success}, error=${lookupResult.error}');

      if (!lookupResult.success) {
        return PairingResult.error(
            lookupResult.error ?? 'Failed to lookup claim code');
      }

      final claimInfo = lookupResult.data!;
      debugPrint('[PairingService] ClaimInfo: instanceId=${claimInfo.instanceId}');
      debugPrint('[PairingService] ClaimInfo: directUrls=${claimInfo.directUrls}');
      debugPrint('[PairingService] ClaimInfo: publicKey length=${claimInfo.publicKey.length}');

      // Decode the server's public key
      final serverPublicKey = _base64ToBytes(claimInfo.publicKey);
      debugPrint('[PairingService] Server public key: ${serverPublicKey.length} bytes');

      // Step 2: Always connect via relay tunnel (relay-first strategy)
      // Direct URL probing will happen in the background after pairing completes
      onStatusUpdate?.call('Connecting via relay...');
      return await _pairViaRelayTunnel(
        claimCode: claimCode,
        claimInfo: claimInfo,
        serverPublicKey: serverPublicKey,
        deviceName: deviceName,
        devicePlatform: devicePlatform,
        onStatusUpdate: onStatusUpdate,
      );
    } catch (e, st) {
      debugPrint('[PairingService] === EXCEPTION in pairWithClaimCodeOnly ===');
      debugPrint('[PairingService] Error: $e');
      debugPrint('[PairingService] Stack trace: $st');
      return PairingResult.error('Pairing error: $e');
    }
  }

  /// Pairs this device using QR code data with relay-first strategy.
  ///
  /// This method uses the data scanned from a QR code, which includes:
  /// - The server's instance ID
  /// - The server's public key
  /// - The relay URL (for self-hosted relays)
  /// - The claim code (rotates every 5 minutes)
  ///
  /// ## Relay-First Flow
  ///
  /// 1. Looks up the claim code via the relay service (using QR relay URL)
  /// 2. Validates the instance ID matches
  /// 3. Connects via relay tunnel (guaranteed to work if relay is reachable)
  /// 4. Completes pairing handshake via relay
  /// 5. Returns credentials and active relay tunnel
  /// 6. Background probing will attempt direct connection upgrade later
  ///
  /// ## Parameters
  ///
  /// - [qrData]: The parsed QR code data
  /// - [deviceName]: A friendly name for this device (e.g., 'My iPhone')
  /// - [platform]: The device platform (defaults to detected platform)
  /// - [onStatusUpdate]: Optional callback for status updates
  ///
  /// Returns a [PairingResult] indicating success or failure.
  /// On success, the result includes the active relay tunnel for ongoing
  /// communication until direct connection is established.
  Future<PairingResult> pairWithQrData({
    required QrPairingData qrData,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === RELAY-FIRST QR PAIRING ===');

      // Step 1: Look up claim code via relay (using relay URL from QR)
      // This validates the claim and gets direct URLs
      onStatusUpdate?.call('Validating pairing code...');
      final relayService = RelayService(relayUrl: qrData.relayUrl);
      final lookupResult = await relayService.lookupClaimCode(qrData.claimCode);

      if (!lookupResult.success) {
        return PairingResult.error(
            lookupResult.error ?? 'Failed to validate pairing code');
      }

      final claimInfo = lookupResult.data!;

      // Validate that the instance ID matches
      if (claimInfo.instanceId != qrData.instanceId) {
        return PairingResult.error(
            'QR code does not match server. Please scan a fresh QR code.');
      }

      // Use the public key from the QR code (already validated by matching instance ID)
      final serverPublicKey = qrData.publicKeyBytes;

      // Step 2: Always connect via relay tunnel (relay-first strategy)
      // Direct URL probing will happen in the background after pairing completes
      onStatusUpdate?.call('Connecting via relay...');
      return await _pairViaRelayTunnel(
        claimCode: qrData.claimCode,
        claimInfo: claimInfo,
        serverPublicKey: serverPublicKey,
        deviceName: deviceName,
        devicePlatform: devicePlatform,
        onStatusUpdate: onStatusUpdate,
        relayUrl: qrData.relayUrl, // Use custom relay URL from QR
      );
    } catch (e) {
      return PairingResult.error('Pairing error: $e');
    }
  }

  // pairDevice method removed - direct pairing not supported in WebRTC-only mode.
  // Use pairWithClaimCodeOnly or pairWithQrData.

  /// Retrieves stored pairing credentials.
  ///
  /// Returns null if no credentials are stored (device not paired).
  Future<PairingCredentials?> getStoredCredentials() async {
    final serverUrl = await _authStorage.read(_StorageKeys.serverUrl);
    final deviceId = await _authStorage.read(_StorageKeys.deviceId);
    final mediaToken = await _authStorage.read(_StorageKeys.mediaToken);
    final accessToken = await _authStorage.read(_StorageKeys.accessToken);
    final deviceToken = await _authStorage.read(_StorageKeys.deviceToken);
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
        accessToken == null ||
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
      accessToken: accessToken,
      deviceToken: deviceToken,
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
    await _authStorage.delete(_StorageKeys.accessToken);
    await _authStorage.delete(_StorageKeys.deviceToken);
    // Keys removed
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

  /// Pairs the device via relay tunnel (relay-first strategy).
  ///
  /// This method:
  /// 1. Connects to relay tunnel using the instance ID
  /// 2. Performs WebRTC handshake over the tunnel
  /// 3. Sends claim code request
  /// 4. Receives pairing response and returns active connection
  Future<PairingResult> _pairViaRelayTunnel({
    required String claimCode,
    required ClaimCodeInfo claimInfo,
    required Uint8List serverPublicKey,
    required String deviceName,
    required String devicePlatform,
    void Function(String status)? onStatusUpdate,
    String? relayUrl,
  }) async {
    WebRTCConnectionManager? webrtcManager;

    // Use provided relay URL or default
    final effectiveRelayUrl = relayUrl ?? _relayUrl;

    try {
      // Step 1: Connect to relay tunnel
      onStatusUpdate?.call('Connecting via WebRTC...');
      final tunnelService = RelayTunnelService(relayUrl: effectiveRelayUrl);
      
      webrtcManager = WebRTCConnectionManager(tunnelService);
      
      // Connect via claim code
      await webrtcManager.connectViaClaimCode(claimCode);
      
      // Step 2: Send claim code request (pairing)
      onStatusUpdate?.call('Submitting claim code...');
      
      final responseJson = await webrtcManager.sendPairingRequest(claimCode, deviceName, devicePlatform);

      // Check for error (server sends 'message' field for errors)
      if (responseJson['type'] == 'error') {
        final errorMsg = responseJson['message'] as String? ??
            responseJson['reason'] as String? ??
            'Unknown error';
        webrtcManager.dispose();
        return PairingResult.error(_formatTunnelError(errorMsg));
      }

      // Parse pairing response (pairing_complete type)
      final deviceId = responseJson['device_id'] as String?;
      final mediaToken = responseJson['media_token'] as String?;
      final accessToken = responseJson['access_token'] as String?;
      final deviceToken = responseJson['device_token'] as String?;

      debugPrint('[RelayPairing] Response: deviceId=$deviceId, mediaToken=${mediaToken != null ? "present" : "null"}, accessToken=${accessToken != null ? "present" : "null"}, deviceToken=${deviceToken != null ? "present" : "null"}');

      if (deviceId == null || mediaToken == null || accessToken == null) {
        webrtcManager.dispose();
        return PairingResult.error('Incomplete pairing response from relay');
      }

      if (deviceToken == null) {
        debugPrint('[RelayPairing] WARNING: device_token not returned by server - reconnection may fail');
      }

      // Step 3: Build credentials
      // Use first direct URL as server URL, or relay URL if no direct URLs
      final serverUrl = claimInfo.directUrls.isNotEmpty
          ? claimInfo.directUrls.first
          : effectiveRelayUrl;

      final credentials = PairingCredentials(
        serverUrl: serverUrl,
        deviceId: deviceId,
        mediaToken: mediaToken,
        accessToken: accessToken,
        deviceToken: deviceToken,
        serverPublicKey: serverPublicKey,
        directUrls: claimInfo.directUrls,
        certFingerprint: null,
        instanceName: null,
        instanceId: claimInfo.instanceId,
      );

      await _storeCredentials(credentials);

      // Relay-first strategy: Always return with relay tunnel (WebRTC) active.
      debugPrint('[RelayPairing] Pairing complete, returning WebRTC connection');
      await _authStorage.write('connection_last_type', 'webrtc');
      return PairingResult.success(credentials, webrtcManager: webrtcManager);
    } catch (e, stackTrace) {
      debugPrint('[RelayPairing] UNCAUGHT ERROR: $e');
      debugPrint('[RelayPairing] Stack trace: $stackTrace');
      webrtcManager?.dispose();
      return PairingResult.error('Relay pairing error: $e');
    }
  }

  /// Formats tunnel error messages to be user-friendly.
  String _formatTunnelError(String reason) {
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
      default:
        return reason;
    }
  }

  String _bytesToBase64(Uint8List bytes) {
    return base64Encode(bytes);
  }

  Future<void> _storeCredentials(PairingCredentials credentials) async {
    await _authStorage.write(_StorageKeys.serverUrl, credentials.serverUrl);
    await _authStorage.write(_StorageKeys.deviceId, credentials.deviceId);
    await _authStorage.write(_StorageKeys.mediaToken, credentials.mediaToken);
    await _authStorage.write(_StorageKeys.accessToken, credentials.accessToken);
    if (credentials.deviceToken != null) {
      await _authStorage.write(
        _StorageKeys.deviceToken,
        credentials.deviceToken!,
      );
    }
    // Removed key storage as WebRTC doesn't need them
    // Keeping serverPublicKey for identity verification if needed
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

  Uint8List _base64ToBytes(String str) {
    return Uint8List.fromList(base64Decode(str));
  }
}
