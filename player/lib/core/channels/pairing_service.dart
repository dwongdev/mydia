/// Device pairing service using libp2p.
///
/// This service orchestrates the complete device pairing flow using
/// the libp2p-based P2P networking with DHT discovery.
library pairing_service;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../auth/auth_storage.dart';
import '../p2p/libp2p_service.dart';

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

  /// Whether the connection is via P2P.
  final bool isP2PMode;

  const PairingResult._({
    required this.success,
    this.error,
    this.credentials,
    this.isP2PMode = false,
  });

  factory PairingResult.success(PairingCredentials credentials, {bool isP2PMode = false}) {
    return PairingResult._(success: true, credentials: credentials, isP2PMode: isP2PMode);
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

  /// The media access token for streaming (typ: media_access).
  final String mediaToken;

  /// The access token for GraphQL/API requests (typ: access).
  final String accessToken;

  /// The device token for reconnection authentication.
  final String? deviceToken;

  /// The server's static public key (32 bytes).
  final Uint8List serverPublicKey;

  /// Direct URLs for connecting to the instance.
  final List<String> directUrls;

  /// Certificate fingerprint for TLS validation.
  final String? certFingerprint;

  /// Instance name (friendly identifier).
  final String? instanceName;

  /// Instance ID for P2P connections.
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
/// This service handles the complete pairing flow. It supports:
/// - Direct HTTP pairing via server URLs
/// - P2P pairing via libp2p (in development)
class PairingService {
  PairingService({
    AuthStorage? authStorage,
    Libp2pService? libp2pService,
    String? relayUrl,
  })  : _authStorage = authStorage ?? getAuthStorage(),
        _libp2pService = libp2pService,
        _relayUrl = relayUrl ?? const String.fromEnvironment(
          'RELAY_URL',
          defaultValue: 'https://relay.mydia.dev',
        );

  final AuthStorage _authStorage;
  final Libp2pService? _libp2pService;
  final String _relayUrl;

  /// Pairs this device using a claim code via libp2p DHT discovery.
  ///
  /// This method:
  /// 1. Initializes the libp2p host
  /// 2. Bootstraps to the relay's DHT
  /// 3. Looks up the claim code on the DHT to find the server
  /// 4. Dials the server and sends a pairing request
  /// 5. Stores credentials on success
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === PAIRING VIA LIBP2P ===');
      debugPrint('[PairingService] claimCode=$claimCode, deviceName=$deviceName, platform=$devicePlatform');
      debugPrint('[PairingService] relayUrl=$_relayUrl');

      // Use the injected libp2p service - it must be provided and initialized
      final libp2pService = _libp2pService;
      if (libp2pService == null) {
        return PairingResult.error('Libp2p service not available. Please try again.');
      }
      
      // Initialize the host if needed
      onStatusUpdate?.call('Initializing secure connection...');
      await libp2pService.initialize();
      
      // Determine the bootstrap address from relay URL
      // The relay should expose its libp2p peer ID and address
      // For now, we use a well-known port (4001) and construct the address
      final bootstrapAddr = _getBootstrapAddress();
      if (bootstrapAddr == null) {
        return PairingResult.error('Could not determine bootstrap address from relay URL');
      }
      
      onStatusUpdate?.call('Connecting to discovery network...');
      await libp2pService.bootstrap(bootstrapAddr);
      
      // Wait for bootstrap to complete with timeout
      try {
        await libp2pService.onBootstrapComplete.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('[PairingService] Bootstrap timeout, proceeding anyway...');
          },
        );
      } catch (e) {
        debugPrint('[PairingService] Bootstrap wait error: $e');
      }
      
      // Lookup the claim code on the DHT
      onStatusUpdate?.call('Looking up pairing code...');
      final lookupResult = await libp2pService.lookupClaimCode(claimCode).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('Claim code lookup timed out');
        },
      );
      
      debugPrint('[PairingService] Found server: peerId=${lookupResult.peerId}, addresses=${lookupResult.addresses}');
      
      // Dial the server if we have addresses
      if (lookupResult.addresses.isNotEmpty) {
        onStatusUpdate?.call('Connecting to server...');
        for (final addr in lookupResult.addresses) {
          try {
            await libp2pService.dial(addr);
            debugPrint('[PairingService] Dialed: $addr');
            break;
          } catch (e) {
            debugPrint('[PairingService] Failed to dial $addr: $e');
          }
        }
      }
      
      // Send pairing request
      onStatusUpdate?.call('Submitting pairing request...');
      final result = await libp2pService.sendPairingRequest(
        peerId: lookupResult.peerId,
        claimCode: claimCode,
        deviceName: deviceName,
        deviceType: devicePlatform,
      );
      
      final mediaToken = result['mediaToken'] as String?;
      final accessToken = result['accessToken'] as String?;
      final deviceToken = result['deviceToken'] as String?;
      
      if (accessToken == null || mediaToken == null) {
        return PairingResult.error('Server did not return required tokens');
      }
      
      // Store credentials
      await _authStorage.write(_StorageKeys.accessToken, accessToken);
      await _authStorage.write(_StorageKeys.mediaToken, mediaToken);
      if (deviceToken != null) {
        await _authStorage.write(_StorageKeys.deviceToken, deviceToken);
      }
      
      // TODO: Get server URL, device ID, and public key from pairing response
      // For now, use placeholder values
      final serverUrl = _relayUrl; // This should come from the server
      const deviceId = 'paired-device'; // This should come from the server
      
      final credentials = PairingCredentials(
        serverUrl: serverUrl,
        deviceId: deviceId,
        mediaToken: mediaToken,
        accessToken: accessToken,
        deviceToken: deviceToken,
        serverPublicKey: Uint8List(0), // TODO: Get from server
        directUrls: [], // TODO: Get from server
      );
      
      onStatusUpdate?.call('Pairing successful!');
      return PairingResult.success(credentials, isP2PMode: true);
    } on TimeoutException catch (e) {
      debugPrint('[PairingService] Timeout: $e');
      return PairingResult.error('Connection timed out. Please try again.');
    } catch (e) {
      debugPrint('[PairingService] Error: $e');
      return PairingResult.error('Pairing failed: $e');
    }
  }

  /// Get the bootstrap multiaddr from the relay URL.
  /// This constructs a libp2p multiaddr from the relay's HTTP URL.
  String? _getBootstrapAddress() {
    try {
      final uri = Uri.parse(_relayUrl);
      final host = uri.host;
      const port = 4001; // Standard libp2p port
      
      // TODO: The relay should advertise its peer ID
      // For now, this is a placeholder - the relay needs to expose its peer ID
      // via an API endpoint or config
      const relayPeerId = ''; // This needs to be configured
      
      if (relayPeerId.isEmpty) {
        debugPrint('[PairingService] Warning: Relay peer ID not configured');
        // Return just the address without peer ID for now
        // This won't work for DHT bootstrap but allows testing
        return '/dns4/$host/tcp/$port';
      }
      
      return '/dns4/$host/tcp/$port/p2p/$relayPeerId';
    } catch (e) {
      debugPrint('[PairingService] Failed to parse relay URL: $e');
      return null;
    }
  }

  /// Pairs this device using QR code data.
  Future<PairingResult> pairWithQrData({
    required QrPairingData qrData,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    return pairWithClaimCodeOnly(
      claimCode: qrData.claimCode,
      deviceName: deviceName,
      platform: platform,
      onStatusUpdate: onStatusUpdate,
    );
  }

  /// Detects the current platform.
  String _detectPlatform() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name.toLowerCase();
  }

  /// Clears stored pairing credentials.
  Future<void> clearCredentials() async {
    await _authStorage.delete(_StorageKeys.serverUrl);
    await _authStorage.delete(_StorageKeys.deviceId);
    await _authStorage.delete(_StorageKeys.mediaToken);
    await _authStorage.delete(_StorageKeys.accessToken);
    await _authStorage.delete(_StorageKeys.deviceToken);
    await _authStorage.delete(_StorageKeys.directUrls);
    await _authStorage.delete(_StorageKeys.certFingerprint);
    await _authStorage.delete(_StorageKeys.instanceName);
    await _authStorage.delete(_StorageKeys.serverPublicKey);
    await _authStorage.delete(_StorageKeys.instanceId);
  }
}
