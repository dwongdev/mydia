import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/native/lib.dart';

/// Custom iroh relay URL from dart-define (optional).
/// If empty, iroh uses its built-in default public relays.
const _customIrohRelayUrl = String.fromEnvironment('IROH_RELAY_URL');

/// Display placeholder for when using iroh's default relays
const defaultRelayUrl = '(iroh default relays)';

/// Provider for the P2pService
final p2pServiceProvider = Provider<P2pService>((ref) {
  final service = P2pService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Notifier for P2P status updates
class P2pStatusNotifier extends Notifier<P2pStatus> {
  StreamSubscription<P2pStatus>? _subscription;

  @override
  P2pStatus build() {
    final service = ref.watch(p2pServiceProvider);

    // Clean up on dispose
    ref.onDispose(() {
      _subscription?.cancel();
    });

    // Listen to status changes
    _subscription = service.onStatusChanged.listen((status) {
      state = status;
    });

    // Return initial state from service
    return service.status;
  }

  /// Reinitialize P2P with a new relay URL.
  /// Note: This requires resetting and recreating the P2P host.
  Future<void> reinitializeWithRelayUrl(String? relayUrl) async {
    try {
      final p2pService = ref.read(p2pServiceProvider);

      // Reset old host (allows re-initialization)
      p2pService.reset();

      // Reinitialize with new relay URL
      await p2pService.initialize(relayUrl: relayUrl);

      state = p2pService.status;
    } catch (e) {
      debugPrint('[P2pStatusNotifier] Failed to reinitialize: $e');
    }
  }
}

/// Provider for P2P status that auto-updates when P2P service emits changes
final p2pStatusNotifierProvider =
    NotifierProvider<P2pStatusNotifier, P2pStatus>(P2pStatusNotifier.new);

/// P2P status information for UI display
class P2pStatus {
  final bool isInitialized;
  final bool isRelayConnected;
  final int connectedPeersCount;
  final String? nodeAddr;

  const P2pStatus({
    required this.isInitialized,
    required this.isRelayConnected,
    required this.connectedPeersCount,
    this.nodeAddr,
  });

  const P2pStatus.initial()
      : isInitialized = false,
        isRelayConnected = false,
        connectedPeersCount = 0,
        nodeAddr = null;

  P2pStatus copyWith({
    bool? isInitialized,
    bool? isRelayConnected,
    int? connectedPeersCount,
    String? nodeAddr,
  }) {
    return P2pStatus(
      isInitialized: isInitialized ?? this.isInitialized,
      isRelayConnected: isRelayConnected ?? this.isRelayConnected,
      connectedPeersCount: connectedPeersCount ?? this.connectedPeersCount,
      nodeAddr: nodeAddr ?? this.nodeAddr,
    );
  }
}

/// Service to handle P2P networking via iroh-based Rust Native Core
class P2pService {
  P2PHost? _host;
  bool _isInitialized = false;
  bool _isRelayConnected = false;
  String? _nodeAddr;
  String? _nodeId;
  final Set<String> _connectedPeers = {};

  // Stream of P2P status updates
  final _statusController = StreamController<P2pStatus>.broadcast();
  Stream<P2pStatus> get onStatusChanged => _statusController.stream;

  // Stream of peer connection events
  final _peerConnectedController = StreamController<String>.broadcast();
  Stream<String> get onPeerConnected => _peerConnectedController.stream;

  /// Returns true if the P2P host is initialized
  bool get isInitialized => _isInitialized;

  /// Returns true if connected to a relay
  bool get isRelayConnected => _isRelayConnected;

  /// This node's EndpointAddr JSON (for sharing with peers)
  String? get nodeAddr => _nodeAddr;

  /// This node's ID (PublicKey string)
  String? get nodeId => _nodeId;

  /// Current P2P status
  P2pStatus get status => P2pStatus(
        isInitialized: _isInitialized,
        isRelayConnected: _isRelayConnected,
        connectedPeersCount: _connectedPeers.length,
        nodeAddr: _nodeAddr,
      );

  /// The relay URL currently in use
  String? _activeRelayUrl;

  /// Get the active relay URL (null before initialization)
  String? get activeRelayUrl => _activeRelayUrl;

  /// Initialize the P2P host.
  ///
  /// [relayUrl] - Optional custom iroh relay URL. If not provided and no
  /// IROH_RELAY_URL env is set, iroh uses its built-in default public relays.
  Future<void> initialize({String? relayUrl}) async {
    if (_isInitialized) return;

    // Use provided URL, or custom from env, or null (iroh defaults)
    final effectiveRelayUrl = relayUrl ??
        (_customIrohRelayUrl.isNotEmpty ? _customIrohRelayUrl : null);
    _activeRelayUrl = effectiveRelayUrl;

    try {
      debugPrint('[P2P] Initializing iroh-based P2P Host with relay: ${effectiveRelayUrl ?? "(iroh defaults)"}');

      // Initialize Host via FRB - returns (P2PHost, String)
      final (host, nodeId) = P2PHost.init(relayUrl: effectiveRelayUrl);
      _host = host;
      _nodeId = nodeId;

      debugPrint('[P2P] Host started with NodeID: $nodeId');

      // Start Event Stream
      _host!.eventStream().listen((event) {
        debugPrint('[P2P] Event: $event');

        if (event.startsWith('connected:')) {
          final peerId = event.substring('connected:'.length);
          _connectedPeers.add(peerId);
          _peerConnectedController.add(peerId);
          _emitStatus();
        } else if (event.startsWith('disconnected:')) {
          final peerId = event.substring('disconnected:'.length);
          _connectedPeers.remove(peerId);
          _emitStatus();
        } else if (event == 'relay_connected') {
          debugPrint('[P2P] Connected to relay');
          _isRelayConnected = true;
          _emitStatus();
        } else if (event.startsWith('ready:')) {
          final nodeAddrJson = event.substring('ready:'.length);
          debugPrint('[P2P] Node ready with addr: $nodeAddrJson');
          _nodeAddr = nodeAddrJson;
          _emitStatus();
        }
      });

      _isInitialized = true;
      _emitStatus();

      // Get initial node address
      _nodeAddr = _host!.getNodeAddr();
      debugPrint('[P2P] Initial node addr: $_nodeAddr');
    } catch (e) {
      debugPrint('[P2P] Failed to initialize: $e');
      rethrow;
    }
  }

  void _emitStatus() {
    _statusController.add(status);
  }

  /// Dial a peer using their EndpointAddr JSON.
  /// This is the primary way to connect to a peer in iroh.
  Future<void> dial(String endpointAddrJson) async {
    if (_host == null) throw Exception("P2P host not initialized");
    debugPrint('[P2P] Dialing endpoint: $endpointAddrJson');
    await _host!.dial(endpointAddrJson: endpointAddrJson);
  }

  /// Get this node's EndpointAddr as JSON for sharing.
  String? getNodeAddr() {
    if (_host == null) return null;
    return _host!.getNodeAddr();
  }

  /// Send a pairing request to a specific peer.
  /// The peer can be either a node_id string or an EndpointAddr JSON.
  Future<Map<String, dynamic>> sendPairingRequest({
    required String peer,
    required String claimCode,
    required String deviceName,
    required String deviceType,
  }) async {
    if (_host == null) throw Exception("P2P host not initialized");

    debugPrint('[P2P] Sending pairing request to $peer');

    final req = FlutterPairingRequest(
      claimCode: claimCode,
      deviceName: deviceName,
      deviceType: deviceType,
      deviceOs: kIsWeb ? 'web' : Platform.operatingSystem,
    );

    final res = await _host!.sendPairingRequest(peer: peer, req: req);

    if (res.success) {
      return {
        'mediaToken': res.mediaToken,
        'accessToken': res.accessToken,
        'deviceToken': res.deviceToken,
      };
    } else {
      throw Exception(res.error ?? "Pairing failed");
    }
  }

  /// Get network statistics
  FlutterNetworkStats? getNetworkStats() {
    if (_host == null) return null;
    return _host!.getNetworkStats();
  }

  /// Send a GraphQL request to the server over P2P.
  /// Returns the parsed JSON response data or throws on error.
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
  }) async {
    if (_host == null) throw Exception("P2P host not initialized");

    debugPrint('[P2P] Sending GraphQL request to $peer');

    // Convert variables to JSON string if provided
    String? variablesJson;
    if (variables != null) {
      variablesJson = _encodeJson(variables);
    }

    final req = FlutterGraphQLRequest(
      query: query,
      variables: variablesJson,
      operationName: operationName,
      authToken: authToken,
    );

    final res = await _host!.sendGraphqlRequest(peer: peer, req: req);

    // Parse the response
    if (res.errors != null) {
      final errors = _decodeJson(res.errors!);
      if (errors is List && errors.isNotEmpty) {
        final firstError = errors.first;
        throw Exception(firstError['message'] ?? 'GraphQL error');
      }
    }

    if (res.data != null) {
      final data = _decodeJson(res.data!);
      if (data is Map<String, dynamic>) {
        return data;
      }
    }

    return {};
  }

  String? _encodeJson(Object? value) {
    if (value == null) return null;
    try {
      return const JsonEncoder().convert(value);
    } catch (e) {
      debugPrint('[P2P] Failed to encode JSON: $e');
      return null;
    }
  }

  dynamic _decodeJson(String json) {
    try {
      return const JsonDecoder().convert(json);
    } catch (e) {
      debugPrint('[P2P] Failed to decode JSON: $e');
      return null;
    }
  }

  /// Reset the P2P host for re-initialization.
  /// This allows changing the relay URL by calling initialize() again.
  void reset() {
    _host = null;
    _isInitialized = false;
    _isRelayConnected = false;
    _nodeAddr = null;
    _nodeId = null;
    _activeRelayUrl = null;
    _connectedPeers.clear();
    _emitStatus();
  }

  Future<void> dispose() async {
    // Rust host is dropped when P2PHost is garbage collected
    _host = null;
    _isInitialized = false;
    await _statusController.close();
    await _peerConnectedController.close();
  }
}
