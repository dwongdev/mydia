import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/native/frb_generated.dart';

/// Provider for the Libp2pService
final libp2pServiceProvider = Provider<Libp2pService>((ref) {
  final service = Libp2pService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Service to handle Libp2p networking and discovery via Rust Native Core
class Libp2pService {
  P2pHost? _host;
  bool _isInitialized = false;
  
  // Stream of discovered peers
  final _peerController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get onPeersFound => _peerController.stream;
  
  final List<String> _discoveredPeers = [];

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('[Libp2p] Initializing Rust Core Host...');
      
      // Initialize Host via FRB
      // Assuming new() returns (P2pHost, String)
      final (host, peerId) = await P2pHost.new_();
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
        }
      });

      _isInitialized = true;
    } catch (e) {
      debugPrint('[Libp2p] Failed to initialize: $e');
      rethrow;
    }
  }

  Future<void> dispose() async {
    // Rust host is dropped when P2pHost is garbage collected or via dispose logic if added
    await _peerController.close();
    _isInitialized = false;
  }
}
