/// Relay-first connection manager with hot swap support.
///
/// This service implements the relay-first connection strategy:
/// 1. Initial connection via relay (guaranteed fast connection)
/// 2. Background probing for direct URLs
/// 3. Hot swap to direct when probe succeeds
/// 4. Auto-fallback to relay if direct drops
///
/// ## State Machine
///
/// ```
/// ┌─────────────┐
/// │   Initial   │
/// └──────┬──────┘
///        │ connect via relay
///        v
/// ┌─────────────┐
/// │  RelayOnly  │◄──────────────────────┐
/// └──────┬──────┘                       │
///        │ probe succeeds               │ direct drops
///        v                              │
/// ┌─────────────┐                       │
/// │    Dual     │───────────────────────┤
/// └──────┬──────┘                       │
///        │ relay requests drained       │
///        v                              │
/// ┌─────────────┐                       │
/// │ DirectOnly  │───────────────────────┘
/// └─────────────┘
/// ```
///
/// ## Usage
///
/// ```dart
/// final manager = RelayFirstConnectionManager(
///   directUrls: credentials.directUrls,
///   instanceId: credentials.instanceId!,
///   relayUrl: 'https://relay.mydia.dev',
/// );
///
/// // Start with relay tunnel from pairing
/// manager.initializeWithRelayTunnel(relayTunnel);
///
/// // Listen for state changes
/// manager.stateChanges.listen((state) {
///   print('Connection mode: ${state.mode}');
/// });
///
/// // Use the current connection for requests
/// await manager.executeRequest((tunnel, directUrl) {
///   // This will use the appropriate connection based on current state
/// });
/// ```
library;

import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;

import 'connection_result.dart';
import 'direct_prober.dart';
import '../channels/channel_service.dart';
import '../relay/relay_tunnel_service.dart';

/// Manages relay-first connections with hot swap to direct.
///
/// This class orchestrates the full connection lifecycle:
/// - Maintains connection state (relay, dual, direct)
/// - Runs background probing for direct URLs
/// - Handles hot swap when probe succeeds
/// - Tracks pending requests for graceful transitions
class RelayFirstConnectionManager {
  RelayFirstConnectionManager({
    required List<String> directUrls,
    required String instanceId,
    required String relayUrl,
    String? certFingerprint,
    ChannelService? channelService,
  })  : _directUrls = List.unmodifiable(directUrls),
        _instanceId = instanceId,
        _relayUrl = relayUrl,
        _certFingerprint = certFingerprint,
        _channelService = channelService ?? ChannelService();

  final List<String> _directUrls;
  final String _instanceId;
  final String _relayUrl;
  final String? _certFingerprint;
  final ChannelService _channelService;

  /// Current connection state.
  ConnectionState? _state;

  /// Background direct URL prober.
  DirectProber? _prober;

  /// Stream controller for state changes.
  final _stateController = StreamController<ConnectionState>.broadcast();

  /// Subscription to prober results.
  StreamSubscription<ProbeResult>? _proberSubscription;

  /// Timer for checking if relay requests are drained.
  Timer? _drainCheckTimer;

  /// Whether currently reconnecting to relay after direct drop.
  bool _isReconnecting = false;

  /// Completer that resolves when reconnection completes.
  Completer<bool>? _reconnectCompleter;

  /// Queue of requests waiting for reconnection.
  final _requestQueue = <_QueuedRequest>[];

  /// Reconnection retry count for exponential backoff.
  int _reconnectRetryCount = 0;

  /// Maximum reconnection retries before giving up.
  static const _maxReconnectRetries = 5;

  /// Reconnection backoff delays.
  static const _reconnectBackoffDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  /// Current connection state.
  ConnectionState? get state => _state;

  /// Whether currently reconnecting to relay.
  bool get isReconnecting => _isReconnecting;

  /// Stream of connection state changes.
  Stream<ConnectionState> get stateChanges => _stateController.stream;

  /// Current connection mode.
  ConnectionMode? get mode => _state?.mode;

  /// Whether currently connected.
  bool get isConnected => _state != null;

  /// Whether currently connected via relay.
  bool get isRelayOnly => _state?.mode == ConnectionMode.relayOnly;

  /// Whether currently in dual mode (hot swap in progress).
  bool get isDual => _state?.mode == ConnectionMode.dual;

  /// Whether currently connected directly.
  bool get isDirectOnly => _state?.mode == ConnectionMode.directOnly;

  /// Initializes the manager with an existing relay tunnel.
  ///
  /// Call this after pairing/reconnection succeeds with a relay tunnel.
  /// This sets the initial state to [ConnectionMode.relayOnly] and starts
  /// background probing for direct URLs.
  void initializeWithRelayTunnel(RelayTunnel tunnel) {
    debugPrint('[RelayFirstConnMgr] Initializing with relay tunnel');

    // Set initial state
    _state = ConnectionState.relayOnly(tunnel: tunnel);
    _emitState();

    // Start background probing if we have direct URLs
    if (_directUrls.isNotEmpty) {
      _startProbing();
    } else {
      debugPrint('[RelayFirstConnMgr] No direct URLs to probe');
    }
  }

  /// Initializes the manager with a direct connection.
  ///
  /// Call this if direct connection was established without relay.
  void initializeWithDirectConnection(String url) {
    debugPrint('[RelayFirstConnMgr] Initializing with direct connection: $url');

    _state = ConnectionState.directOnly(url: url);
    _emitState();
  }

  /// Increments the pending relay request count.
  ///
  /// Call this when starting a request over relay.
  void incrementRelayRequests() {
    if (_state == null) return;
    _state = _state!.copyWith(
      pendingRelayRequests: _state!.pendingRelayRequests + 1,
    );
    _emitState();
  }

  /// Decrements the pending relay request count.
  ///
  /// Call this when a relay request completes.
  void decrementRelayRequests() {
    if (_state == null) return;
    _state = _state!.copyWith(
      pendingRelayRequests: (_state!.pendingRelayRequests - 1).clamp(0, 999999),
    );
    _emitState();

    // Check if we can complete hot swap
    _checkHotSwapCompletion();
  }

  /// Increments the pending direct request count.
  ///
  /// Call this when starting a request over direct connection.
  void incrementDirectRequests() {
    if (_state == null) return;
    _state = _state!.copyWith(
      pendingDirectRequests: _state!.pendingDirectRequests + 1,
    );
    _emitState();
  }

  /// Decrements the pending direct request count.
  ///
  /// Call this when a direct request completes.
  void decrementDirectRequests() {
    if (_state == null) return;
    _state = _state!.copyWith(
      pendingDirectRequests: (_state!.pendingDirectRequests - 1).clamp(0, 999999),
    );
    _emitState();
  }

  /// Executes a request using the appropriate connection.
  ///
  /// This method routes the request based on current connection state:
  /// - [ConnectionMode.relayOnly]: Uses relay tunnel
  /// - [ConnectionMode.dual]: Routes new requests to direct
  /// - [ConnectionMode.directOnly]: Uses direct connection
  ///
  /// If the connection is currently reconnecting (after direct drop),
  /// the request will be queued and executed once reconnection completes.
  ///
  /// The [execute] callback receives either the relay tunnel or direct URL
  /// (one will be non-null based on routing decision).
  Future<T> executeRequest<T>(
    Future<T> Function(RelayTunnel? tunnel, String? directUrl) execute,
  ) async {
    // If reconnecting, queue the request
    if (_isReconnecting) {
      debugPrint('[RelayFirstConnMgr] Request queued during reconnection');
      return _queueRequest(execute);
    }

    if (_state == null) {
      throw StateError('Connection not initialized');
    }

    switch (_state!.mode) {
      case ConnectionMode.relayOnly:
        incrementRelayRequests();
        try {
          return await execute(_state!.relayTunnel, null);
        } finally {
          decrementRelayRequests();
        }

      case ConnectionMode.dual:
        // In dual mode, route new requests to direct
        incrementDirectRequests();
        try {
          return await execute(null, _state!.directUrl);
        } finally {
          decrementDirectRequests();
        }

      case ConnectionMode.directOnly:
        incrementDirectRequests();
        try {
          return await execute(null, _state!.directUrl);
        } finally {
          decrementDirectRequests();
        }
    }
  }

  /// Queues a request to be executed after reconnection.
  Future<T> _queueRequest<T>(
    Future<T> Function(RelayTunnel? tunnel, String? directUrl) execute,
  ) async {
    final completer = Completer<T>();
    _requestQueue.add(_QueuedRequest<T>(execute, completer));

    // Wait for reconnection and request execution
    return completer.future;
  }

  /// Processes queued requests after reconnection completes.
  Future<void> _processRequestQueue() async {
    debugPrint('[RelayFirstConnMgr] Processing ${_requestQueue.length} queued requests');

    final queue = List<_QueuedRequest>.from(_requestQueue);
    _requestQueue.clear();

    for (final request in queue) {
      try {
        // Re-execute through normal routing
        final result = await executeRequest(request.execute);
        request.complete(result);
      } catch (e) {
        request.completeError(e);
      }
    }
  }

  /// Fails all queued requests with an error.
  void _failRequestQueue(Object error) {
    debugPrint('[RelayFirstConnMgr] Failing ${_requestQueue.length} queued requests');

    for (final request in _requestQueue) {
      request.completeError(error);
    }
    _requestQueue.clear();
  }

  /// Gets the current relay tunnel (if available).
  RelayTunnel? get relayTunnel => _state?.relayTunnel;

  /// Gets the current direct URL (if available).
  String? get directUrl => _state?.directUrl;

  /// Starts background probing for direct URLs.
  void _startProbing() {
    if (_prober != null) {
      debugPrint('[RelayFirstConnMgr] Prober already running');
      return;
    }

    debugPrint('[RelayFirstConnMgr] Starting background probing');

    _prober = DirectProber(
      directUrls: _directUrls,
      certFingerprint: _certFingerprint,
      channelService: _channelService,
    );

    _proberSubscription = _prober!.results.listen(_onProbeResult);
    _prober!.startProbing();
  }

  /// Stops background probing.
  void _stopProbing() {
    debugPrint('[RelayFirstConnMgr] Stopping background probing');
    _proberSubscription?.cancel();
    _proberSubscription = null;
    _prober?.dispose();
    _prober = null;
  }

  /// Handles probe results.
  void _onProbeResult(ProbeResult result) {
    if (result.success && result.successfulUrl != null) {
      debugPrint('[RelayFirstConnMgr] Probe succeeded: ${result.successfulUrl}');
      _startHotSwap(result.successfulUrl!);
    } else {
      debugPrint('[RelayFirstConnMgr] Probe failed: ${result.error}');
      // Update probe state for backoff tracking
      _state = _state?.copyWith(
        lastDirectProbe: DateTime.now(),
        probeFailureCount: result.failureCount,
      );
      _emitState();
    }
  }

  /// Starts the hot swap from relay to direct.
  ///
  /// This enters DUAL mode where both connections are active.
  void _startHotSwap(String directUrl) {
    if (_state == null || _state!.mode != ConnectionMode.relayOnly) {
      debugPrint('[RelayFirstConnMgr] Cannot hot swap - not in relay mode');
      return;
    }

    final tunnel = _state!.relayTunnel;
    if (tunnel == null) {
      debugPrint('[RelayFirstConnMgr] Cannot hot swap - no relay tunnel');
      return;
    }

    debugPrint('[RelayFirstConnMgr] Starting hot swap to $directUrl');
    debugPrint('[RelayFirstConnMgr] Pending relay requests: ${_state!.pendingRelayRequests}');

    // Stop probing - we found a working direct URL
    _stopProbing();

    // Enter dual mode
    _state = ConnectionState.dual(
      tunnel: tunnel,
      directUrl: directUrl,
      pendingRelayRequests: _state!.pendingRelayRequests,
    );
    _emitState();

    // Check if we can immediately complete (no pending relay requests)
    _checkHotSwapCompletion();
  }

  /// Checks if hot swap can be completed (all relay requests drained).
  void _checkHotSwapCompletion() {
    if (_state == null || _state!.mode != ConnectionMode.dual) {
      return;
    }

    if (_state!.canCloseRelay) {
      debugPrint('[RelayFirstConnMgr] Relay requests drained, completing hot swap');
      _completeHotSwap();
    } else {
      debugPrint('[RelayFirstConnMgr] Waiting for ${_state!.pendingRelayRequests} relay requests to complete');

      // Start a timer to periodically check if we missed any decrements
      _drainCheckTimer?.cancel();
      _drainCheckTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _checkHotSwapCompletion(),
      );
    }
  }

  /// Completes the hot swap by closing the relay tunnel.
  void _completeHotSwap() {
    if (_state == null || _state!.mode != ConnectionMode.dual) {
      return;
    }

    _drainCheckTimer?.cancel();
    _drainCheckTimer = null;

    final directUrl = _state!.directUrl;
    final relay = _state!.relayTunnel;

    if (directUrl == null) {
      debugPrint('[RelayFirstConnMgr] ERROR: No direct URL in dual mode');
      return;
    }

    debugPrint('[RelayFirstConnMgr] Hot swap complete, closing relay');

    // Close relay tunnel
    relay?.close();

    // Enter direct-only mode
    _state = ConnectionState.directOnly(url: directUrl);
    _emitState();
  }

  /// Called when the direct connection drops.
  ///
  /// This triggers auto-fallback to relay.
  Future<void> onDirectConnectionDropped() async {
    if (_state == null) return;

    debugPrint('[RelayFirstConnMgr] Direct connection dropped, falling back to relay');

    // If we're in direct-only mode, we need to reconnect via relay
    if (_state!.mode == ConnectionMode.directOnly) {
      await _reconnectViaRelay();
    }
  }

  /// Reconnects via relay after direct connection drops.
  ///
  /// This method implements retry logic with exponential backoff.
  /// While reconnecting, incoming requests are queued and processed
  /// once reconnection succeeds.
  Future<void> _reconnectViaRelay() async {
    if (_isReconnecting) {
      debugPrint('[RelayFirstConnMgr] Already reconnecting, waiting...');
      await _reconnectCompleter?.future;
      return;
    }

    _isReconnecting = true;
    _reconnectCompleter = Completer<bool>();
    _reconnectRetryCount = 0;

    debugPrint('[RelayFirstConnMgr] Starting relay reconnection');

    try {
      while (_reconnectRetryCount < _maxReconnectRetries) {
        debugPrint('[RelayFirstConnMgr] Reconnection attempt ${_reconnectRetryCount + 1}/$_maxReconnectRetries');

        try {
          final tunnelService = RelayTunnelService(relayUrl: _relayUrl);
          final result = await tunnelService.connectViaRelay(_instanceId);

          if (result.success && result.data != null) {
            final tunnel = result.data!;
            debugPrint('[RelayFirstConnMgr] Relay reconnection successful');

            // Reset to relay-only mode
            _state = ConnectionState.relayOnly(tunnel: tunnel);
            _emitState();

            // Restart probing
            _startProbing();

            // Process queued requests
            _isReconnecting = false;
            _reconnectCompleter?.complete(true);
            _reconnectCompleter = null;
            _reconnectRetryCount = 0;

            await _processRequestQueue();
            return;
          } else {
            debugPrint('[RelayFirstConnMgr] Relay reconnection failed: ${result.error}');
          }
        } catch (e) {
          debugPrint('[RelayFirstConnMgr] Relay reconnection error: $e');
        }

        // Increment retry count and wait before next attempt
        _reconnectRetryCount++;
        if (_reconnectRetryCount < _maxReconnectRetries) {
          final delayIndex = (_reconnectRetryCount - 1).clamp(0, _reconnectBackoffDelays.length - 1);
          final delay = _reconnectBackoffDelays[delayIndex];
          debugPrint('[RelayFirstConnMgr] Waiting ${delay.inSeconds}s before retry');
          await Future.delayed(delay);
        }
      }

      // All retries exhausted
      debugPrint('[RelayFirstConnMgr] Relay reconnection failed after $_maxReconnectRetries attempts');
      _failRequestQueue(StateError('Relay reconnection failed after $_maxReconnectRetries attempts'));

      _isReconnecting = false;
      _reconnectCompleter?.complete(false);
      _reconnectCompleter = null;
    } catch (e) {
      debugPrint('[RelayFirstConnMgr] Unexpected error during reconnection: $e');
      _failRequestQueue(e);

      _isReconnecting = false;
      _reconnectCompleter?.complete(false);
      _reconnectCompleter = null;
    }
  }

  /// Emits the current state to listeners.
  void _emitState() {
    if (_state != null && !_stateController.isClosed) {
      _stateController.add(_state!);
    }
  }

  /// Triggers an immediate probe attempt.
  ///
  /// Use this when network conditions change.
  void probeNow() {
    _prober?.probeNow();
  }

  /// Disposes of resources.
  void dispose() {
    _stopProbing();
    _drainCheckTimer?.cancel();
    _drainCheckTimer = null;
    _failRequestQueue(StateError('Connection manager disposed'));
    _state?.relayTunnel?.close();
    _stateController.close();
  }
}

/// Helper class for queued requests during reconnection.
class _QueuedRequest<T> {
  final Future<T> Function(RelayTunnel? tunnel, String? directUrl) execute;
  final Completer<T> _completer;

  _QueuedRequest(this.execute, this._completer);

  /// Completes the request with a successful result.
  void complete(dynamic result) {
    if (!_completer.isCompleted) {
      _completer.complete(result as T);
    }
  }

  /// Completes the request with an error.
  void completeError(Object error) {
    if (!_completer.isCompleted) {
      _completer.completeError(error);
    }
  }
}
