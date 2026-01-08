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
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'channel_service.dart';
import '../crypto/crypto_manager.dart';
import '../auth/auth_storage.dart';
import '../relay/relay_service.dart';
import '../relay/relay_tunnel_service.dart';
import '../connection/connection_manager.dart';

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

  /// Active relay tunnel (if pairing was via relay and direct connection failed).
  /// The caller should use this tunnel for ongoing communication.
  final RelayTunnel? relayTunnel;

  const PairingResult._({
    required this.success,
    this.error,
    this.credentials,
    this.relayTunnel,
  });

  factory PairingResult.success(PairingCredentials credentials, {RelayTunnel? relayTunnel}) {
    return PairingResult._(success: true, credentials: credentials, relayTunnel: relayTunnel);
  }

  factory PairingResult.error(String error) {
    return PairingResult._(success: false, error: error);
  }

  /// Whether the pairing used relay mode (no direct connection available).
  bool get isRelayMode => relayTunnel != null;
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
    ChannelService? channelService,
    AuthStorage? authStorage,
    RelayService? relayService,
    ConnectionManager? connectionManager,
    String? relayUrl,
  })  : _channelService = channelService ?? ChannelService(),
        _authStorage = authStorage ?? getAuthStorage(),
        _relayService = relayService ?? RelayService(),
        _connectionManager = connectionManager,
        _relayUrl = relayUrl ?? const String.fromEnvironment(
          'RELAY_URL',
          defaultValue: 'https://relay.mydia.dev',
        );

  final ChannelService _channelService;
  final AuthStorage _authStorage;
  final RelayService _relayService;
  final ConnectionManager? _connectionManager;
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
      await _channelService.disconnect();
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
    CryptoManager? cryptoManager;
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

      // Step 3: Perform X25519 key exchange
      cryptoManager = CryptoManager();
      final clientPublicKeyB64 = await cryptoManager.generateKeyPair();

      // Generate and send handshake message
      final firstMessage = Uint8List.fromList(base64Decode(clientPublicKeyB64));
      final handshakeResult =
          await _channelService.sendPairingHandshake(channel, firstMessage);
      if (!handshakeResult.success) {
        cryptoManager.dispose();
        await _channelService.disconnect();
        return PairingResult.error(
            handshakeResult.error ?? 'Key exchange failed');
      }

      // Derive session key from server's public key response
      await cryptoManager.deriveSessionKey(base64Encode(handshakeResult.data!));
      cryptoManager.dispose();
      cryptoManager = null;

      // Step 4: Generate static device keypair (client-side key generation)
      final staticCrypto = CryptoManager();
      final staticPublicKeyB64 = await staticCrypto.generateStaticKeyPair();
      final devicePublicKey = await staticCrypto.getStaticPublicKeyBytes();
      final devicePrivateKey = await staticCrypto.getStaticPrivateKeyBytes();

      // Step 5: Submit claim code with our public key
      final claimResult = await _channelService.submitClaimCode(
        channel,
        claimCode: claimCode,
        deviceName: deviceName,
        platform: devicePlatform,
        staticPublicKey: staticPublicKeyB64,
      );

      await _channelService.disconnect();

      if (!claimResult.success) {
        return PairingResult.error(
            claimResult.error ?? 'Failed to submit claim code');
      }

      final response = claimResult.data!;

      // Step 6: Store credentials with our locally-generated keypair
      final credentials = PairingCredentials(
        serverUrl: serverUrl,
        deviceId: response.deviceId,
        mediaToken: response.mediaToken,
        devicePublicKey: devicePublicKey,
        devicePrivateKey: devicePrivateKey,
        serverPublicKey: serverPublicKey,
        directUrls: [serverUrl], // Use serverUrl as the only direct URL
        certFingerprint: null, // Not available in direct pairing
        instanceName: null, // Not available in direct pairing
        instanceId: null, // Not available in direct pairing
      );

      await _storeCredentials(credentials);

      return PairingResult.success(credentials);
    } catch (e) {
      cryptoManager?.dispose();
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

  /// Pairs the device via relay tunnel (relay-first strategy).
  ///
  /// This method:
  /// 1. Connects to relay tunnel using the instance ID
  /// 2. Performs X25519 key exchange over the tunnel
  /// 3. Sends claim code request
  /// 4. Receives pairing response and returns active tunnel
  ///
  /// The returned [PairingResult] includes the active relay tunnel for
  /// ongoing communication. Background probing (handled by ConnectionManager)
  /// will attempt to upgrade to direct connection later.
  Future<PairingResult> _pairViaRelayTunnel({
    required String claimCode,
    required ClaimCodeInfo claimInfo,
    required Uint8List serverPublicKey,
    required String deviceName,
    required String devicePlatform,
    void Function(String status)? onStatusUpdate,
    String? relayUrl,
  }) async {
    RelayTunnel? tunnel;
    CryptoManager? cryptoManager;

    // Use provided relay URL or default
    final effectiveRelayUrl = relayUrl ?? _relayUrl;

    try {
      // Step 1: Connect to relay tunnel
      onStatusUpdate?.call('Connecting via relay...');
      final tunnelService = RelayTunnelService(relayUrl: effectiveRelayUrl);
      final tunnelResult =
          await tunnelService.connectViaRelay(claimInfo.instanceId);

      if (!tunnelResult.success) {
        return PairingResult.error(
            tunnelResult.error ?? 'Failed to connect via relay');
      }

      tunnel = tunnelResult.data!;
      debugPrint('[RelayPairing] Tunnel connected: session=${tunnel.info.sessionId}');

      // Listen for tunnel errors/closure for debugging
      tunnel.errors.listen(
        (error) {
          debugPrint('[RelayPairing] Tunnel error: $error');
        },
        onError: (e, stackTrace) {
          debugPrint('[RelayPairing] Error stream error: $e');
          debugPrint('[RelayPairing] Error stream stack trace: $stackTrace');
        },
      );

      // Check if tunnel is still active
      debugPrint('[RelayPairing] Tunnel active: ${tunnel.isActive}');

      // Step 2: Perform X25519 key exchange over tunnel
      onStatusUpdate?.call('Establishing secure connection...');

      // Validate server public key
      debugPrint('[RelayPairing] Server public key length: ${serverPublicKey.length}');
      if (serverPublicKey.length != 32) {
        await tunnel.close();
        return PairingResult.error(
            'Invalid server public key: expected 32 bytes, got ${serverPublicKey.length}');
      }

      debugPrint('[RelayPairing] About to create CryptoManager, tunnel active: ${tunnel.isActive}');
      try {
        cryptoManager = CryptoManager();
        debugPrint('[RelayPairing] CryptoManager created successfully');
      } catch (e, stackTrace) {
        debugPrint('[RelayPairing] CryptoManager creation failed: $e');
        debugPrint('[RelayPairing] Stack trace: $stackTrace');
        await tunnel.close();
        return PairingResult.error('Failed to create crypto manager: $e');
      }
      debugPrint('[RelayPairing] CryptoManager created, tunnel active: ${tunnel.isActive}');
      String clientPublicKeyB64;
      try {
        debugPrint('[RelayPairing] Starting keypair generation...');
        clientPublicKeyB64 = await cryptoManager.generateKeyPair();
        debugPrint('[RelayPairing] Client keypair generated, tunnel active: ${tunnel.isActive}');
      } catch (e, stackTrace) {
        debugPrint('[RelayPairing] Failed to generate keypair: $e');
        debugPrint('[RelayPairing] Stack trace: $stackTrace');
        cryptoManager.dispose();
        await tunnel.close();
        return PairingResult.error('Failed to initialize secure connection: $e');
      }

      // Generate and send handshake message
      final handshakeMessage = Uint8List.fromList(base64Decode(clientPublicKeyB64));
      debugPrint('[RelayPairing] Handshake message generated: ${handshakeMessage.length} bytes');

      // Send handshake message through tunnel (wrapped in JSON for server)
      try {
        final handshakeRequest = jsonEncode({
          'type': 'pairing_handshake',
          'data': {'message': base64Encode(handshakeMessage)},
        });
        debugPrint('[RelayPairing] Sending handshake request...');
        tunnel.sendMessage(Uint8List.fromList(utf8.encode(handshakeRequest)));
        debugPrint('[RelayPairing] Handshake request sent');
      } catch (e) {
        debugPrint('[RelayPairing] Failed to send handshake: $e');
        cryptoManager.dispose();
        await tunnel.close();
        return PairingResult.error('Failed to send handshake: $e');
      }

      // Wait for server's handshake response
      final handshakeResponseBytes = await tunnel.messages.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Handshake response timeout'),
      );

      // Parse handshake response
      final handshakeResponseJson =
          jsonDecode(utf8.decode(handshakeResponseBytes)) as Map<String, dynamic>;

      if (handshakeResponseJson['type'] == 'error') {
        cryptoManager.dispose();
        await tunnel.close();
        return PairingResult.error(
            handshakeResponseJson['message'] as String? ?? 'Handshake failed');
      }

      final serverHandshakeB64 = handshakeResponseJson['message'] as String?;
      if (serverHandshakeB64 == null) {
        cryptoManager.dispose();
        await tunnel.close();
        return PairingResult.error('Invalid handshake response');
      }

      // Derive session key from server's public key
      try {
        await cryptoManager.deriveSessionKey(serverHandshakeB64);
        debugPrint('[RelayPairing] Session key derived');
      } catch (e) {
        debugPrint('[RelayPairing] Failed to derive session key: $e');
        cryptoManager.dispose();
        await tunnel.close();
        return PairingResult.error('Failed to derive session key: $e');
      }

      // Enable encryption on the tunnel with the derived session key
      final sessionKeyBytes = await cryptoManager.getSessionKeyBytes();
      if (sessionKeyBytes == null) {
        cryptoManager.dispose();
        await tunnel.close();
        return PairingResult.error('Failed to get session key');
      }
      tunnel.enableEncryption(sessionKeyBytes);
      debugPrint('[RelayPairing] Encryption enabled on tunnel');

      // Dispose session crypto manager - tunnel now handles encryption
      cryptoManager.dispose();
      cryptoManager = null;

      // Step 3: Generate static device keypair (client-side key generation)
      // The private key never leaves the device
      onStatusUpdate?.call('Generating device keys...');
      final staticCrypto = CryptoManager();
      final staticPublicKeyB64 = await staticCrypto.generateStaticKeyPair();
      final devicePublicKey = await staticCrypto.getStaticPublicKeyBytes();
      final devicePrivateKey = await staticCrypto.getStaticPrivateKeyBytes();

      // Step 4: Send claim code request with static public key (encrypted)
      onStatusUpdate?.call('Submitting claim code...');
      final claimRequest = jsonEncode({
        'type': 'claim_code',
        'data': {
          'code': claimCode,
          'device_name': deviceName,
          'platform': devicePlatform,
          'static_public_key': staticPublicKeyB64,
        },
      });
      await tunnel.sendJsonMessage(claimRequest);

      // Step 5: Wait for response
      final responseBytes = await tunnel.messages.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Claim code response timeout'),
      );

      // Parse response
      final responseJson =
          jsonDecode(utf8.decode(responseBytes)) as Map<String, dynamic>;

      // Check for error (server sends 'message' field for errors)
      if (responseJson['type'] == 'error') {
        final errorMsg = responseJson['message'] as String? ??
            responseJson['reason'] as String? ??
            'Unknown error';
        await tunnel.close();
        return PairingResult.error(_formatTunnelError(errorMsg));
      }

      // Parse pairing response (pairing_complete type)
      final deviceId = responseJson['device_id'] as String?;
      final mediaToken = responseJson['media_token'] as String?;

      if (deviceId == null || mediaToken == null) {
        await tunnel.close();
        return PairingResult.error('Incomplete pairing response from relay');
      }

      // Step 6: Build credentials with locally-generated keypair
      // Use first direct URL as server URL, or relay URL if no direct URLs
      final serverUrl = claimInfo.directUrls.isNotEmpty
          ? claimInfo.directUrls.first
          : effectiveRelayUrl;

      final credentials = PairingCredentials(
        serverUrl: serverUrl,
        deviceId: deviceId,
        mediaToken: mediaToken,
        devicePublicKey: devicePublicKey,
        devicePrivateKey: devicePrivateKey,
        serverPublicKey: serverPublicKey,
        directUrls: claimInfo.directUrls,
        certFingerprint: null,
        instanceName: null,
        instanceId: claimInfo.instanceId,
      );

      await _storeCredentials(credentials);

      // Step 7: Mark claim as consumed on relay
      onStatusUpdate?.call('Finalizing...');
      await _relayService.consumeClaim(claimInfo.claimId, deviceId);

      // Relay-first strategy: Always return with relay tunnel active.
      // Background probing (handled by ConnectionManager) will attempt to
      // upgrade to direct connection later.
      debugPrint('[RelayPairing] Pairing complete, returning relay tunnel for ongoing communication');
      await _authStorage.write('connection_last_type', 'relay');
      return PairingResult.success(credentials, relayTunnel: tunnel);
    } catch (e, stackTrace) {
      debugPrint('[RelayPairing] UNCAUGHT ERROR: $e');
      debugPrint('[RelayPairing] Stack trace: $stackTrace');
      cryptoManager?.dispose();
      if (tunnel != null) {
        await tunnel.close();
      }
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
