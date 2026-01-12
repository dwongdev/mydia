import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/native/lib.dart';

/// Provider for the Libp2pService
final libp2pServiceProvider = Provider<Libp2pService>((ref) {
  final service = Libp2pService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Result of a DHT claim code lookup
class ClaimCodeLookupResult {
  final String peerId;
  final List<String> addresses;
  
  const ClaimCodeLookupResult({
    required this.peerId,
    required this.addresses,
  });
}

/// Service to handle Libp2p networking and discovery via Rust Native Core
class Libp2pService {
  P2PHost? _host;
  bool _isInitialized = false;
  bool _isBootstrapped = false;
  final Completer<void> _bootstrapCompleter = Completer<void>();
  
  // Stream of discovered peers
  final _peerController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get onPeersFound => _peerController.stream;
  
  /// Returns true if the DHT bootstrap has completed
  bool get isBootstrapped => _isBootstrapped;
  
  /// Future that completes when DHT bootstrap is done
  Future<void> get onBootstrapComplete => _bootstrapCompleter.future;
  
  final List<String> _discoveredPeers = [];

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('[Libp2p] Initializing Rust Core Host...');
      
      // Initialize Host via FRB
      // Returns a Record (P2PHost, String)
      final (host, peerId) = P2PHost.init();
      _host = host;
      
      debugPrint('[Libp2p] Host started with PeerID: $peerId');
      
      // Listen on random TCP port
      await _host!.listen(addr: '/ip4/0.0.0.0/tcp/0');
      
      // Start Event Stream
      _host!.eventStream().listen((event) {
        debugPrint('[Libp2p] Event: $event');
        if (event.startsWith('peer_discovered:')) {
          final pid = event.split(':')[1];
          if (!_discoveredPeers.contains(pid)) {
            _discoveredPeers.add(pid);
            _peerController.add(List.unmodifiable(_discoveredPeers));
          }
        } else if (event == 'bootstrap_completed') {
          debugPrint('[Libp2p] DHT Bootstrap completed');
          _isBootstrapped = true;
          if (!_bootstrapCompleter.isCompleted) {
            _bootstrapCompleter.complete();
          }
        }
      });

      _isInitialized = true;
    } catch (e) {
      debugPrint('[Libp2p] Failed to initialize: $e');
      rethrow;
    }
  }

  /// Add a bootstrap peer and initiate DHT bootstrap.
  /// The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
  Future<void> bootstrap(String addr) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    debugPrint('[Libp2p] Bootstrapping to: $addr');
    await _host!.bootstrap(addr: addr);
  }

  /// Lookup a claim code on the DHT to find the provider peer.
  /// Returns the peer ID and addresses of the server that provided this claim code.
  Future<ClaimCodeLookupResult> lookupClaimCode(String claimCode) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    debugPrint('[Libp2p] Looking up claim code on DHT...');
    final result = await _host!.lookupClaimCode(claimCode: claimCode);
    return ClaimCodeLookupResult(
      peerId: result.peerId,
      addresses: result.addresses,
    );
  }

  /// Send a pairing request to a specific peer.
  Future<Map<String, dynamic>> sendPairingRequest({
    required String peerId,
    required String claimCode,
    required String deviceName,
    required String deviceType,
  }) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    
    debugPrint('[Libp2p] Sending pairing request to $peerId');
    
    final req = FlutterPairingRequest(
        claimCode: claimCode,
        deviceName: deviceName,
        deviceType: deviceType,
        deviceOs: kIsWeb ? 'web' : Platform.operatingSystem,
    );
    
    final res = await _host!.sendPairingRequest(peer: peerId, req: req);
    
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

  /// Pair with the first discovered peer (legacy mDNS-based discovery)
  Future<Map<String, dynamic>> pair({
    required String claimCode,
    required String deviceName,
    required String deviceType,
  }) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    
    // Check discovered peers
    if (_discoveredPeers.isEmpty) {
        throw Exception("No peers discovered yet");
    }
    
    // Naive selection: try the first one. 
    // In production we would identify the server peer more robustly.
    final serverPeerId = _discoveredPeers.first; 
    
    return sendPairingRequest(
      peerId: serverPeerId,
      claimCode: claimCode,
      deviceName: deviceName,
      deviceType: deviceType,
    );
  }

  /// Dial a peer by address
  Future<void> dial(String addr) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    await _host!.dial(addr: addr);
  }

  Future<void> dispose() async {
    // Rust host is dropped when P2PHost is garbage collected or via dispose logic if added
    await _peerController.close();
    _isInitialized = false;
  }
}
