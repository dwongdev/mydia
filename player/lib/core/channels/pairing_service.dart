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
import '../relay/relay_api_client.dart';

/// Data parsed from a QR code for device pairing.
///
/// The QR code contains JSON with the following fields:
/// - instance_id: The server's unique instance ID
/// - peer_id: The server's libp2p peer ID (e.g., "12D3KooW...")
/// - claim_code: The pairing claim code (rotates every 5 minutes)
///
/// With libp2p, we don't need relay URLs or public keys in the QR code.
/// The peer_id is sufficient for establishing a secure connection via
/// DHT discovery or direct dialing.
class QrPairingData {
  /// The server's unique instance ID.
  final String instanceId;

  /// The server's libp2p peer ID.
  final String peerId;

  /// The pairing claim code.
  final String claimCode;

  const QrPairingData({
    required this.instanceId,
    required this.peerId,
    required this.claimCode,
  });

  /// Parses QR code content into [QrPairingData].
  ///
  /// Returns null if the content is not valid JSON or is missing required fields.
  static QrPairingData? tryParse(String content) {
    try {
      final json = jsonDecode(content) as Map<String, dynamic>;

      final instanceId = json['instance_id'] as String?;
      final peerId = json['peer_id'] as String?;
      final claimCode = json['claim_code'] as String?;

      if (instanceId == null || peerId == null || claimCode == null) {
        return null;
      }

      return QrPairingData(
        instanceId: instanceId,
        peerId: peerId,
        claimCode: claimCode,
      );
    } catch (e) {
      return null;
    }
  }
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
/// This service handles the complete pairing flow using libp2p:
/// - QR code pairing: Uses peer_id from QR to connect directly
/// - Claim code pairing: Uses DHT to discover the server
class PairingService {
  PairingService({
    AuthStorage? authStorage,
    Libp2pService? libp2pService,
  })  : _authStorage = authStorage ?? getAuthStorage(),
        _libp2pService = libp2pService;

  final AuthStorage _authStorage;
  final Libp2pService? _libp2pService;

  /// Pairs this device using a claim code via libp2p rendezvous discovery.
  ///
  /// This method:
  /// 1. Resolves the claim code to a namespace and rendezvous points via Relay API
  /// 2. Initializes the libp2p host
  /// 3. Connects to the rendezvous points
  /// 4. Discovers the server in the namespace
  /// 5. Dials the server and sends a pairing request
  /// 6. Stores credentials on success
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === PAIRING VIA LIBP2P RENDEZVOUS ===');
      debugPrint('[PairingService] claimCode=$claimCode, deviceName=$deviceName, platform=$devicePlatform');

      // Use the injected libp2p service - it must be provided and initialized
      final libp2pService = _libp2pService;
      if (libp2pService == null) {
        return PairingResult.error('Libp2p service not available. Please try again.');
      }
      
      // 1. Resolve claim code via HTTP
      onStatusUpdate?.call('Resolving pairing code...');
      final relayClient = RelayApiClient(); // TODO: Inject in constructor for testing
      final resolveResult = await relayClient.resolveClaimCode(claimCode);
      debugPrint('[PairingService] Resolved namespace: ${resolveResult.namespace}');
      
      // 2. Initialize the host if needed
      onStatusUpdate?.call('Initializing secure connection...');
      await libp2pService.initialize();
      
      // 3. Connect to the rendezvous points
      onStatusUpdate?.call('Connecting to discovery network...');
      if (resolveResult.rendezvousPoints.isNotEmpty) {
        for (final addr in resolveResult.rendezvousPoints) {
          try {
            await libp2pService.connectRelay(addr);
            debugPrint('[PairingService] Connected to rendezvous point: $addr');
          } catch (e) {
            debugPrint('[PairingService] Failed to connect to rendezvous point $addr: $e');
          }
        }
      } else {
        // Fallback to default relay
        try {
          await libp2pService.connectToDefaultRelay(waitForReservation: false);
        } catch (e) {
          debugPrint('[PairingService] Default relay connection failed: $e');
        }
      }
      
      // 4. Discover server via rendezvous
      onStatusUpdate?.call('Finding server...');
      final discoveredPeers = await libp2pService.discoverNamespace(resolveResult.namespace).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException('Server discovery timed out');
        },
      );
      
      if (discoveredPeers.isEmpty) {
        return PairingResult.error('Server not found. Please check if pairing mode is active.');
      }
      
      final serverPeer = discoveredPeers.first;
      debugPrint('[PairingService] Found server: peerId=${serverPeer.peerId}, addresses=${serverPeer.addresses}');
      
      // 5. Dial the server if we have addresses
      if (serverPeer.addresses.isNotEmpty) {
        onStatusUpdate?.call('Connecting to server...');
        for (final addr in serverPeer.addresses) {
          try {
            await libp2pService.dial(addr);
            debugPrint('[PairingService] Dialed: $addr');
            break;
          } catch (e) {
            debugPrint('[PairingService] Failed to dial $addr: $e');
          }
        }
      }
      
      // 6. Send pairing request
      onStatusUpdate?.call('Submitting pairing request...');
      final result = await libp2pService.sendPairingRequest(
        peerId: serverPeer.peerId,
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
      
      // In P2P mode, serverUrl is a p2p:// URI with the peer ID
      final credentials = PairingCredentials(
        serverUrl: 'p2p://${serverPeer.peerId}',
        deviceId: 'paired-device', 
        mediaToken: mediaToken,
        accessToken: accessToken,
        deviceToken: deviceToken,
        serverPublicKey: Uint8List(0), 
        directUrls: [], 
      );
      
      onStatusUpdate?.call('Pairing successful!');
      return PairingResult.success(credentials, isP2PMode: true);
    } on InvalidClaimCodeException {
      return PairingResult.error('Invalid or expired claim code');
    } on RateLimitedException {
      return PairingResult.error('Too many attempts. Please wait a moment.');
    } on TimeoutException catch (e) {
      debugPrint('[PairingService] Timeout: $e');
      return PairingResult.error('Connection timed out. Please try again.');
    } catch (e) {
      debugPrint('[PairingService] Error: $e');
      return PairingResult.error('Pairing failed: $e');
    }
  }

  /// Pairs this device using QR code data.
  ///
  /// With libp2p, the QR code contains the server's peer_id and claim_code.
  /// We use the claim code to find the server's addresses via DHT lookup,
  /// then send the pairing request.
  Future<PairingResult> pairWithQrData({
    required QrPairingData qrData,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === PAIRING VIA QR CODE (LIBP2P) ===');
      debugPrint('[PairingService] peerId=${qrData.peerId}, instanceId=${qrData.instanceId}');
      debugPrint('[PairingService] claimCode=${qrData.claimCode}, deviceName=$deviceName');

      final libp2pService = _libp2pService;
      if (libp2pService == null) {
        return PairingResult.error('Libp2p service not available. Please try again.');
      }

      // Initialize the host if needed
      onStatusUpdate?.call('Initializing secure connection...');
      await libp2pService.initialize();
      
      // Connect to the relay server for NAT traversal
      onStatusUpdate?.call('Connecting to relay server...');
      try {
        await libp2pService.connectToDefaultRelay();
        debugPrint('[PairingService] Connected to relay');
      } catch (e) {
        debugPrint('[PairingService] Relay connection failed (continuing anyway): $e');
      }
      
      // Wait for DHT bootstrap to complete
      onStatusUpdate?.call('Connecting to discovery network...');
      try {
        await libp2pService.onBootstrapComplete.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            debugPrint('[PairingService] Bootstrap timeout, proceeding anyway...');
          },
        );
        debugPrint('[PairingService] DHT bootstrap completed');
      } catch (e) {
        debugPrint('[PairingService] Bootstrap wait error: $e');
      }
      
      // Lookup the claim code on the DHT to find the server's addresses
      // Even with QR code, we need addresses to dial the peer
      onStatusUpdate?.call('Looking up server address...');
      bool connectedToServer = false;
      try {
        final lookupResult = await libp2pService.lookupClaimCode(qrData.claimCode).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw TimeoutException('Server lookup timed out');
          },
        );
        
        debugPrint('[PairingService] Found server via DHT: addresses=${lookupResult.addresses}');
        
        // Dial the server if we have addresses
        if (lookupResult.addresses.isNotEmpty) {
          onStatusUpdate?.call('Connecting to server...');
          for (final addr in lookupResult.addresses) {
            try {
              await libp2pService.dial(addr);
              debugPrint('[PairingService] Dialed: $addr');
              connectedToServer = true;
              break;
            } catch (e) {
              debugPrint('[PairingService] Failed to dial $addr: $e');
            }
          }
        }
      } catch (e) {
        debugPrint('[PairingService] DHT lookup failed (will try relay circuit): $e');
      }
      
      // If DHT lookup failed or returned no addresses, try connecting via relay circuit
      if (!connectedToServer) {
        final circuitAddr = libp2pService.buildCircuitAddress(qrData.peerId);
        if (circuitAddr != null) {
          onStatusUpdate?.call('Connecting via relay...');
          debugPrint('[PairingService] Trying relay circuit: $circuitAddr');
          try {
            await libp2pService.dial(circuitAddr);
            debugPrint('[PairingService] Dialed relay circuit address');
            // Give the circuit connection time to establish
            // The dial command is async - connection happens in background
            await Future.delayed(const Duration(seconds: 2));
            debugPrint('[PairingService] Proceeding after relay circuit dial');
            connectedToServer = true;
          } catch (e) {
            debugPrint('[PairingService] Failed to dial via relay circuit: $e');
          }
        } else {
          debugPrint('[PairingService] No relay connection available for circuit');
        }
      }

      // Send pairing request to the server
      onStatusUpdate?.call('Submitting pairing request...');
      debugPrint('[PairingService] Sending pairing request to ${qrData.peerId}');
      final result = await libp2pService.sendPairingRequest(
        peerId: qrData.peerId,
        claimCode: qrData.claimCode,
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
      await _authStorage.write(_StorageKeys.instanceId, qrData.instanceId);
      if (deviceToken != null) {
        await _authStorage.write(_StorageKeys.deviceToken, deviceToken);
      }

      // In P2P mode, serverUrl is a p2p:// URI with the peer ID
      // serverPublicKey and directUrls are not needed - libp2p handles encryption and addressing
      final credentials = PairingCredentials(
        serverUrl: 'p2p://${qrData.peerId}',
        deviceId: 'paired-device', // Extracted from access_token claims if needed
        mediaToken: mediaToken,
        accessToken: accessToken,
        deviceToken: deviceToken,
        serverPublicKey: Uint8List(0), // Not used in P2P mode
        directUrls: [], // Not used in P2P mode
        instanceId: qrData.instanceId,
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
