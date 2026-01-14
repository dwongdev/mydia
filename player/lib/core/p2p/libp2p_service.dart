import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:player/native/lib.dart';

/// Default relay URL - the official Mydia relay server
const String kDefaultRelayUrl = 'https://relay.mydia.dev';

/// Provider for the Libp2pService
final libp2pServiceProvider = Provider<Libp2pService>((ref) {
  final service = Libp2pService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Result of a peer discovery
class DiscoveredPeer {
  final String peerId;
  final List<String> addresses;
  
  const DiscoveredPeer({
    required this.peerId,
    required this.addresses,
  });
}

/// DHT status information for UI display
class DhtStatus {
  final bool isBootstrapped;
  final int discoveredPeersCount;
  final bool isInitialized;
  final bool isRelayConnected;
  final String? relayedAddress;
  
  const DhtStatus({
    required this.isBootstrapped,
    required this.discoveredPeersCount,
    required this.isInitialized,
    this.isRelayConnected = false,
    this.relayedAddress,
  });
  
  const DhtStatus.initial()
      : isBootstrapped = false,
        discoveredPeersCount = 0,
        isInitialized = false,
        isRelayConnected = false,
        relayedAddress = null;
  
  DhtStatus copyWith({
    bool? isBootstrapped,
    int? discoveredPeersCount,
    bool? isInitialized,
    bool? isRelayConnected,
    String? relayedAddress,
  }) {
    return DhtStatus(
      isBootstrapped: isBootstrapped ?? this.isBootstrapped,
      discoveredPeersCount: discoveredPeersCount ?? this.discoveredPeersCount,
      isInitialized: isInitialized ?? this.isInitialized,
      isRelayConnected: isRelayConnected ?? this.isRelayConnected,
      relayedAddress: relayedAddress ?? this.relayedAddress,
    );
  }
}

/// Information about a relay server
class RelayInfo {
  final String peerId;
  final List<String> multiaddrs;
  final String? primaryMultiaddr;
  
  const RelayInfo({
    required this.peerId,
    required this.multiaddrs,
    this.primaryMultiaddr,
  });
  
  factory RelayInfo.fromJson(Map<String, dynamic> json) {
    return RelayInfo(
      peerId: json['peer_id'] as String,
      multiaddrs: (json['multiaddrs'] as List<dynamic>).cast<String>(),
      primaryMultiaddr: json['primary_multiaddr'] as String?,
    );
  }
}

/// Service to handle Libp2p networking and discovery via Rust Native Core
class Libp2pService {
  P2PHost? _host;
  bool _isInitialized = false;
  bool _isBootstrapped = false;
  bool _isRelayConnected = false;
  String? _relayedAddress;
  String? _connectedRelayAddr; // The relay multiaddr we connected to
  final Completer<void> _bootstrapCompleter = Completer<void>();
  final Completer<void> _relayCompleter = Completer<void>();
  
  // Stream of discovered peers
  final _peerController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get onPeersFound => _peerController.stream;
  
  // Stream of DHT status updates
  final _dhtStatusController = StreamController<DhtStatus>.broadcast();
  Stream<DhtStatus> get onDhtStatusChanged => _dhtStatusController.stream;
  
  /// Returns true if the DHT bootstrap has completed
  bool get isBootstrapped => _isBootstrapped;
  
  /// Returns true if connected to a relay with a relayed address
  bool get isRelayConnected => _isRelayConnected;
  
  /// Our address through the relay (for other peers to connect to us)
  String? get relayedAddress => _relayedAddress;
  
  /// The relay multiaddr we connected to (for constructing circuit addresses)
  String? get connectedRelayAddr => _connectedRelayAddr;
  
  /// Future that completes when DHT bootstrap is done
  Future<void> get onBootstrapComplete => _bootstrapCompleter.future;
  
  /// Future that completes when relay reservation is ready
  Future<void> get onRelayReady => _relayCompleter.future;
  
  /// Current DHT status
  DhtStatus get dhtStatus => DhtStatus(
    isBootstrapped: _isBootstrapped,
    discoveredPeersCount: _discoveredPeers.length,
    isInitialized: _isInitialized,
    isRelayConnected: _isRelayConnected,
    relayedAddress: _relayedAddress,
  );
  
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
            _emitDhtStatus();
          }
        } else if (event == 'bootstrap_completed') {
          debugPrint('[Libp2p] DHT Bootstrap completed');
          _isBootstrapped = true;
          if (!_bootstrapCompleter.isCompleted) {
            _bootstrapCompleter.complete();
          }
          _emitDhtStatus();
        } else if (event.startsWith('relay_ready:')) {
          // Format: relay_ready:<relay_peer_id>:<relayed_addr>
          final parts = event.split(':');
          if (parts.length >= 3) {
            final relayedAddr = parts.sublist(2).join(':'); // Address may contain colons
            debugPrint('[Libp2p] Relay reservation ready: $relayedAddr');
            _isRelayConnected = true;
            _relayedAddress = relayedAddr;
            if (!_relayCompleter.isCompleted) {
              _relayCompleter.complete();
            }
            _emitDhtStatus();
          }
        } else if (event.startsWith('relay_failed:')) {
          debugPrint('[Libp2p] Relay reservation failed: $event');
        } else if (event.startsWith('new_listen_addr:')) {
          final addr = event.substring('new_listen_addr:'.length);
          debugPrint('[Libp2p] New listen address: $addr');
        }
      });

      _isInitialized = true;
      _emitDhtStatus();
    } catch (e) {
      debugPrint('[Libp2p] Failed to initialize: $e');
      rethrow;
    }
  }
  
  void _emitDhtStatus() {
    _dhtStatusController.add(dhtStatus);
  }

  /// Add a bootstrap peer and initiate DHT bootstrap.
  /// The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
  Future<void> bootstrap(String addr) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    debugPrint('[Libp2p] Bootstrapping to: $addr');
    await _host!.bootstrap(addr: addr);
  }

  /// Discover peers in a rendezvous namespace.
  /// Returns the list of discovered peers and their addresses.
  Future<List<DiscoveredPeer>> discoverNamespace(String namespace) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    debugPrint('[Libp2p] Discovering peers in namespace: $namespace');
    
    final result = await _host!.discoverNamespace(namespace: namespace);
    
    return result.peers.map((p) => DiscoveredPeer(
      peerId: p.peerId,
      addresses: p.addresses,
    )).toList();
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

  /// Fetch relay server information from the relay HTTP endpoint
  static Future<RelayInfo> fetchRelayInfo({String relayUrl = kDefaultRelayUrl}) async {
    debugPrint('[Libp2p] Fetching relay info from $relayUrl/p2p/info');
    final response = await http.get(Uri.parse('$relayUrl/p2p/info'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch relay info: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return RelayInfo.fromJson(json);
  }

  /// Connect to a relay server and request a reservation.
  /// This allows other peers to connect to us through the relay.
  /// 
  /// [relayAddr] should be a multiaddr including the relay's peer ID,
  /// e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..." or "/dns4/p2p.mydia.dev/tcp/4001/p2p/..."
  Future<void> connectRelay(String relayAddr) async {
    if (_host == null) throw Exception("Libp2p host not initialized");
    debugPrint('[Libp2p] Connecting to relay: $relayAddr');
    await _host!.connectRelay(relayAddr: relayAddr);
    _connectedRelayAddr = relayAddr;
  }
  
  /// Construct a relay circuit address to reach a peer through our connected relay.
  /// Returns null if we're not connected to a relay.
  /// 
  /// The format is: <relay-multiaddr>/p2p-circuit/p2p/<target-peer-id>
  String? buildCircuitAddress(String targetPeerId) {
    if (_connectedRelayAddr == null) return null;
    return '$_connectedRelayAddr/p2p-circuit/p2p/$targetPeerId';
  }

  /// Convenience method to fetch relay info and connect to it.
  /// Uses the default relay URL unless overridden.
  /// 
  /// This method initiates the relay connection and optionally waits for the
  /// relay reservation to be ready. If [waitForReservation] is true (default),
  /// it will wait up to [timeout] for the relay_ready event.
  Future<void> connectToDefaultRelay({
    String relayUrl = kDefaultRelayUrl,
    bool waitForReservation = true,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final relayInfo = await fetchRelayInfo(relayUrl: relayUrl);
      debugPrint('[Libp2p] Got relay info: peerId=${relayInfo.peerId}, addrs=${relayInfo.multiaddrs}');
      
      // Try to connect using the primary multiaddr first, then fallback to others
      var addrs = relayInfo.primaryMultiaddr != null 
          ? [relayInfo.primaryMultiaddr!, ...relayInfo.multiaddrs.where((a) => a != relayInfo.primaryMultiaddr)]
          : relayInfo.multiaddrs;
      
      // Resolve DNS-based multiaddrs to IP-based (Android can't use DNS transport)
      addrs = await Future.wait(addrs.map(_resolveDnsMultiaddr));
      
      String? connectedAddr;
      for (final addr in addrs) {
        try {
          debugPrint('[Libp2p] Trying relay address: $addr');
          await connectRelay(addr);
          debugPrint('[Libp2p] Initiated relay connection via: $addr');
          connectedAddr = addr;
          break;
        } catch (e) {
          debugPrint('[Libp2p] Failed to connect to relay via $addr: $e');
          continue;
        }
      }
      
      if (connectedAddr == null) {
        throw Exception('Failed to connect to any relay address');
      }
      
      // Optionally wait for the relay reservation to be ready
      if (waitForReservation) {
        debugPrint('[Libp2p] Waiting for relay reservation (timeout: ${timeout.inSeconds}s)...');
        try {
          await onRelayReady.timeout(timeout);
          debugPrint('[Libp2p] Relay reservation ready: $_relayedAddress');
        } catch (e) {
          debugPrint('[Libp2p] Relay reservation timeout - proceeding anyway');
          // Don't throw - the connection may still work for outbound circuits
        }
      }
    } catch (e) {
      debugPrint('[Libp2p] Failed to connect to relay: $e');
      rethrow;
    }
  }
  
  /// Resolve DNS-based multiaddr to IP-based for Android compatibility.
  /// Android's libp2p build doesn't include DNS transport, so we need to
  /// resolve DNS hostnames to IPs in Dart.
  static Future<String> _resolveDnsMultiaddr(String addr) async {
    // Only resolve DNS on Android - other platforms may have DNS transport
    if (!Platform.isAndroid) {
      return addr;
    }
    
    // Check if this is a DNS-based address
    final dnsMatch = RegExp(r'^/dns4/([^/]+)/(.+)$').firstMatch(addr);
    if (dnsMatch == null) {
      // Not a DNS address, return as-is
      return addr;
    }
    
    final hostname = dnsMatch.group(1)!;
    final rest = dnsMatch.group(2)!;
    
    try {
      // Resolve the hostname to IP addresses
      final addresses = await InternetAddress.lookup(hostname);
      if (addresses.isNotEmpty) {
        final ip = addresses.first.address;
        final resolved = '/ip4/$ip/$rest';
        debugPrint('[Libp2p] Resolved DNS $hostname -> $ip');
        return resolved;
      }
    } catch (e) {
      debugPrint('[Libp2p] Failed to resolve $hostname: $e');
    }
    
    // Fallback to original address
    return addr;
  }

  Future<void> dispose() async {
    // Rust host is dropped when P2PHost is garbage collected or via dispose logic if added
    await _peerController.close();
    await _dhtStatusController.close();
    _isInitialized = false;
  }
}
