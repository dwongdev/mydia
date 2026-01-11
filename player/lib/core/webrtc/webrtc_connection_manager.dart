library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../crypto/noise_transport.dart';
import '../relay/relay_tunnel_service.dart';

import 'media_proxy_service.dart';

class WebRTCConnectionManager {
  final RelayTunnelService _relayTunnelService;
  
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  RTCDataChannel? _mediaChannel; // Dedicated channel for media
  RelayTunnel? _signalingTunnel;
  
  // E2EE support
  NoiseTransport? _noise;
  bool _e2eeEnabled = false;
  Completer<void>? _handshakeCompleter;
  
  // Pending requests map
  final Map<String, Completer<TunnelResponse>> _pendingRequests = {};
  
  // Active media streams: map requestId -> StreamController
  final Map<String, StreamController<List<int>>> _mediaStreams = {};
  final Map<String, Completer<Map<String, dynamic>>> _mediaHeadersCompleters = {};
  
  int _requestCounter = 0;
  
  // Specific completer for pairing
  Completer<Map<String, dynamic>>? _pairingCompleter;

  WebRTCConnectionManager(this._relayTunnelService);
  
  /// Whether E2EE is currently active.
  bool get isE2EEEnabled => _e2eeEnabled && (_noise?.isHandshakeComplete ?? false);

  Future<void> connect(String instanceId) async {
    debugPrint('[WebRTC] Connecting to $instanceId...');
    
    // 1. Connect to Relay for Signaling
    final relayResult = await _relayTunnelService.connectViaRelay(instanceId);
    if (!relayResult.success) {
      throw Exception("Failed to connect to relay: ${relayResult.error}");
    }
    _signalingTunnel = relayResult.data!;
    
    await _establishConnection();
  }

  Future<void> connectViaClaimCode(String claimCode) async {
    debugPrint('[WebRTC] Connecting via claim code...');
    
    // 1. Connect to Relay for Signaling
    final relayResult = await _relayTunnelService.connectViaClaimCode(claimCode);
    if (!relayResult.success) {
      throw Exception("Failed to connect to relay: ${relayResult.error}");
    }
    _signalingTunnel = relayResult.data!;
    
    await _establishConnection();
  }

  Future<void> _establishConnection() async {
    debugPrint('[WebRTC] Relay signaling established');

    // 2. Create PeerConnection
    // Use ICE servers from relay info if available, otherwise fallback to default
    debugPrint('[WebRTC] ICE servers from tunnel info: ${_signalingTunnel!.info.iceServers}');
    debugPrint('[WebRTC] ICE servers count: ${_signalingTunnel!.info.iceServers.length}');
    
    final rawIceServers = _signalingTunnel!.info.iceServers.isNotEmpty
        ? _signalingTunnel!.info.iceServers
        : [
            {'urls': 'stun:stun.l.google.com:19302'},
          ];
    
    // Convert to the format expected by flutter_webrtc
    // Each server needs: urls (String or List<String>), username (optional), credential (optional)
    final iceServers = rawIceServers.map((server) {
      final Map<String, dynamic> converted = {};
      
      // Handle 'urls' - can be string or list
      if (server['urls'] != null) {
        converted['urls'] = server['urls'];
      } else if (server['url'] != null) {
        // Some servers use 'url' instead of 'urls'
        converted['urls'] = server['url'];
      }
      
      // Copy credentials if present
      if (server['username'] != null) {
        converted['username'] = server['username'];
      }
      if (server['credential'] != null) {
        converted['credential'] = server['credential'];
      }
      
      return converted;
    }).toList();
    
    debugPrint('[WebRTC] Using ${iceServers.length} ICE servers:');
    for (final server in iceServers) {
      debugPrint('[WebRTC]   - ${server['urls']}${server.containsKey('username') ? ' (with credentials: ${server['username']})' : ''}');
    }

    final config = {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
    
    debugPrint('[WebRTC] Creating PeerConnection with config: $config');
    _pc = await createPeerConnection(config);

    // 3. Create Data Channels
    // Set up completer BEFORE creating channels to avoid race conditions
    final dataChannelCompleter = Completer<bool>();
    
    // Use negotiated: false so the channel is created via in-band signaling
    // and the server will receive the data channel via {:data_channel, ...} message
    final dataChannelInit = RTCDataChannelInit();
    _dataChannel = await _pc!.createDataChannel('mydia-api', dataChannelInit);
    
    // Set up state handler immediately after creation, before any other async work
    _dataChannel!.onDataChannelState = (state) {
      debugPrint('[WebRTC] API Channel State: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (!dataChannelCompleter.isCompleted) dataChannelCompleter.complete(true);
      }
    };
    
    // Check if already open (unlikely but possible)
    if (_dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      if (!dataChannelCompleter.isCompleted) dataChannelCompleter.complete(true);
    }
    
    // Set up message handler for API channel
    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      _handleApiChannelMessage(message);
    };
    
    final mediaChannelInit = RTCDataChannelInit();
    _mediaChannel = await _pc!.createDataChannel('mydia-media', mediaChannelInit);
    
    // Setup media channel handlers
    _setupMediaChannel(_mediaChannel!);

    // 4. Setup Signaling Handlers
    _signalingTunnel!.signalingMessages.listen((msg) async {
      final type = msg['type'];
      final payload = msg['payload'];
      
      debugPrint('[WebRTC] Received signaling: $type');

      try {
        if (type == 'webrtc_answer') {
          // Parse SDP
          final sdpMap = payload is String ? jsonDecode(payload) : payload;
          debugPrint('[WebRTC] Received answer SDP type: ${sdpMap['type']}');
          final answer = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
          await _pc!.setRemoteDescription(answer);
          debugPrint('[WebRTC] Remote description set successfully');
        } else if (type == 'webrtc_candidate') {
          // Parse Candidate
          final candMap = payload is String ? jsonDecode(payload) : payload;
          debugPrint('[WebRTC] Received ICE candidate: ${candMap['candidate']}');
          // sdpMid can come as int or String from different sources, convert to String
          final sdpMid = candMap['sdpMid']?.toString();
          final candidate = RTCIceCandidate(
            candMap['candidate'],
            sdpMid,
            candMap['sdpMLineIndex'],
          );
          await _pc!.addCandidate(candidate);
          debugPrint('[WebRTC] ICE candidate added successfully');
        }
      } catch (e, stack) {
        debugPrint('[WebRTC] Signaling error: $e');
        debugPrint('[WebRTC] Stack: $stack');
      }
    });

    _pc!.onIceCandidate = (candidate) {
      debugPrint('[WebRTC] Sending ICE candidate: ${candidate.candidate}');
      _signalingTunnel!.sendSignalingMessage('webrtc_candidate', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    
    _pc!.onIceConnectionState = (state) {
      debugPrint('[WebRTC] ICE Connection State: $state');
    };
    
    _pc!.onIceGatheringState = (state) {
      debugPrint('[WebRTC] ICE Gathering State: $state');
    };
    
    _pc!.onConnectionState = (state) {
      debugPrint('[WebRTC] Connection State: $state');
    };

    // 5. Create Offer & Start Negotiation
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    
    _signalingTunnel!.sendSignalingMessage('webrtc_offer', {
      'sdp': offer.sdp,
      'type': offer.type,
    });

    // 6. Wait for Data Channel to open
    debugPrint('[WebRTC] Waiting for Data Channel...');
    try {
      await dataChannelCompleter.future.timeout(const Duration(seconds: 30));
      debugPrint('[WebRTC] Data channel open');
    } catch (e) {
      debugPrint('[WebRTC] Data Channel timeout: $e');
      throw Exception("WebRTC Data Channel failed to open: $e");
    }
    
    // 7. Perform Noise handshake if server supports E2EE
    await _performNoiseHandshake();
    
    debugPrint('[WebRTC] Connected! E2EE: $_e2eeEnabled');
  }
  
  /// Performs the Noise IK handshake over the data channel.
  /// 
  /// E2EE is mandatory - throws an exception if:
  /// - Server public key is not available
  /// - Server public key is invalid
  /// - Handshake fails for any reason
  Future<void> _performNoiseHandshake() async {
    final publicKeyBase64 = _signalingTunnel?.info.publicKey;
    if (publicKeyBase64 == null || publicKeyBase64.isEmpty) {
      throw Exception('E2EE required but server did not provide public key');
    }
    
    final serverPublicKey = base64Decode(publicKeyBase64);
    if (serverPublicKey.length != 32) {
      throw Exception('E2EE required but server public key is invalid (length: ${serverPublicKey.length})');
    }
    
    final sessionId = _signalingTunnel!.info.sessionId;
    final instanceId = _signalingTunnel!.info.instanceId;
    
    debugPrint('[WebRTC] Initializing Noise handshake...');
    
    _noise = await NoiseTransport.initiator(
      serverPublicKey: Uint8List.fromList(serverPublicKey),
      sessionId: sessionId,
      instanceId: instanceId,
    );
    
    // Set up handshake completer
    _handshakeCompleter = Completer<void>();
    
    // Send handshake message 1
    final msg1 = await _noise!.writeHandshake();
    debugPrint('[WebRTC] Sending Noise handshake message 1 (${msg1.length} bytes)');
    await _dataChannel!.send(RTCDataChannelMessage.fromBinary(msg1));
    
    // Wait for handshake response (handled in _handleDataMessage)
    try {
      await _handshakeCompleter!.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _noise = null;
      throw Exception('E2EE handshake failed: $e');
    }
    
    _e2eeEnabled = true;
    debugPrint('[WebRTC] Noise handshake complete - E2EE active');
  }
  
  // Setup handlers for the media channel
  void _setupMediaChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (state) {
      debugPrint('[WebRTC] Channel ${channel.label} State: $state');
    };
    
    channel.onMessage = (RTCDataChannelMessage message) {
      _handleMediaChannelMessage(message);
    };
  }
  
  void _handleMediaChannelMessage(RTCDataChannelMessage message) {
    if (!_e2eeEnabled || _noise == null) {
      debugPrint('[WebRTC] Ignoring media message: E2EE not active');
      return;
    }
    
    if (!message.isBinary || !NoiseTransport.isTransportMessage(message.binary)) {
      debugPrint('[WebRTC] Ignoring non-encrypted media message');
      return;
    }
    
    try {
      final (channel, plaintext) = _noise!.decrypt(message.binary);
      if (channel == NoiseChannel.media) {
        // Check if it's JSON or binary data
        if (plaintext.isNotEmpty && plaintext[0] == 0x7B) { // '{' character
          // JSON message
          _handleMediaMessage(RTCDataChannelMessage(utf8.decode(plaintext)));
        } else {
          // Binary data
          _handleMediaMessage(RTCDataChannelMessage.fromBinary(plaintext));
        }
      }
    } catch (e) {
      debugPrint('[WebRTC] E2EE media decryption failed: $e');
    }
  }

  Future<MediaStreamResponse> requestMedia(String fileId, int start, int? end) async {
    if (_mediaChannel == null || _mediaChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception("WebRTC Media Channel not open");
    }
    
    final requestId = 'media-${++_requestCounter}';
    final completer = Completer<Map<String, dynamic>>();
    _mediaHeadersCompleters[requestId] = completer;
    
    final controller = StreamController<List<int>>();
    _mediaStreams[requestId] = controller;
    
    final req = {
      'type': 'stream_request',
      'request_id': requestId,
      'file_id': fileId,
      'range_start': start,
      'range_end': end,
    };
    
    try {
      await _sendMediaMessage(jsonEncode(req));
      
      // Wait for headers
      final headersMsg = await completer.future.timeout(const Duration(seconds: 10));
      
      final status = headersMsg['status'] as int;
      final headers = Map<String, String>.from(headersMsg['headers'] ?? {});
      
      return MediaStreamResponse(status, headers, controller.stream);
      
    } catch (e) {
      _mediaHeadersCompleters.remove(requestId);
      _mediaStreams.remove(requestId);
      controller.close();
      rethrow;
    }
  }

  void _handleMediaMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      // Binary Format: [0x01][req_id_len][req_id][payload]
      final data = message.binary;
      if (data.length < 2) return;
      
      final type = data[0];
      if (type == 0x01) {
        final idLen = data[1];
        if (data.length < 2 + idLen) return;
        
        final reqIdBytes = data.sublist(2, 2 + idLen);
        final payload = data.sublist(2 + idLen);
        
        final requestId = utf8.decode(reqIdBytes);
        
        if (_mediaStreams.containsKey(requestId)) {
          _mediaStreams[requestId]!.add(payload);
        }
      }
    } else {
      // JSON Control Message
      try {
        final json = jsonDecode(message.text);
        final requestId = json['request_id'];
        
        if (json['type'] == 'response_header') {
          if (_mediaHeadersCompleters.containsKey(requestId)) {
            _mediaHeadersCompleters.remove(requestId)!.complete(json);
          }
        } else if (json['type'] == 'end' || json['type'] == 'error') {
           if (_mediaStreams.containsKey(requestId)) {
             _mediaStreams.remove(requestId)!.close();
           }
        }
      } catch (e) {
        debugPrint('Media message error: $e');
      }
    }
  }
  
  // ... (rest of class)

  
  Future<Map<String, dynamic>> sendPairingRequest(String code, String deviceName, String platform) async {
     if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception("WebRTC Data Channel not open");
    }
    
    _pairingCompleter = Completer<Map<String, dynamic>>();
    
    final req = {
      'type': 'claim_code',
      'code': code,
      'device_name': deviceName,
      'platform': platform,
    };
    
    await _sendApiMessage(jsonEncode(req));
    
    return _pairingCompleter!.future.timeout(const Duration(seconds: 30));
  }

  Future<void> authenticate(String deviceToken) async {
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception("WebRTC Data Channel not open");
    }

    final completer = Completer<void>();
    // We can reuse a general purpose completer mechanism or specific one.
    // For simplicity, let's assume _handleDataMessage resolves it if we track it.
    // But auth response is special type 'auth_response'.
    
    // Let's use a temporary one-off listener or add a specific completer
    _authCompleter = completer;

    final req = {
      'type': 'auth',
      'device_token': deviceToken,
    };

    await _sendApiMessage(jsonEncode(req));
    
    return completer.future.timeout(const Duration(seconds: 10));
  }
  
  Completer<void>? _authCompleter;

  Future<TunnelResponse> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    String? body,
  }) async {
    debugPrint('[WebRTC] request() called: method=$method, path=$path');
    debugPrint('[WebRTC] Data channel state: ${_dataChannel?.state}');
    
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      debugPrint('[WebRTC] ERROR: Data channel not open!');
      throw Exception("WebRTC Data Channel not open");
    }

    final requestId = 'req-${++_requestCounter}';
    final completer = Completer<TunnelResponse>();
    _pendingRequests[requestId] = completer;
    
    final req = {
      'type': 'request',
      'id': requestId,
      'method': method,
      'path': path,
      'headers': headers ?? {},
      'body': body,
    };
    
    try {
      final jsonStr = jsonEncode(req);
      debugPrint('[WebRTC] Sending request: $requestId (E2EE: $_e2eeEnabled)');
      await _sendApiMessage(jsonStr);
      debugPrint('[WebRTC] Request sent successfully: $requestId');
    } catch (e) {
      debugPrint('[WebRTC] Error sending request: $e');
      _pendingRequests.remove(requestId);
      rethrow;
    }
    
    debugPrint('[WebRTC] Waiting for response: $requestId');
    return completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
      debugPrint('[WebRTC] Request timed out: $requestId');
      _pendingRequests.remove(requestId);
      throw TimeoutException("Request timed out");
    });
  }
  
  /// Handles incoming messages on the API channel.
  /// 
  /// During handshake: processes binary handshake messages.
  /// After handshake: decrypts and processes JSON messages.
  /// Sends a message on the API channel with E2EE encryption.
  /// Throws if E2EE is not active.
  Future<void> _sendApiMessage(String jsonStr) async {
    if (!_e2eeEnabled || _noise == null || !_noise!.isHandshakeComplete) {
      throw Exception('Cannot send message: E2EE not active');
    }
    final plaintext = Uint8List.fromList(utf8.encode(jsonStr));
    final ciphertext = _noise!.encrypt(NoiseChannel.api, plaintext);
    await _dataChannel!.send(RTCDataChannelMessage.fromBinary(ciphertext));
  }
  
  /// Sends a message on the media channel with E2EE encryption.
  /// Throws if E2EE is not active.
  Future<void> _sendMediaMessage(String jsonStr) async {
    if (!_e2eeEnabled || _noise == null || !_noise!.isHandshakeComplete) {
      throw Exception('Cannot send message: E2EE not active');
    }
    final plaintext = Uint8List.fromList(utf8.encode(jsonStr));
    final ciphertext = _noise!.encrypt(NoiseChannel.media, plaintext);
    await _mediaChannel!.send(RTCDataChannelMessage.fromBinary(ciphertext));
  }
  
  /// Handles incoming messages on the API channel.
  /// 
  /// During handshake: processes binary handshake messages.
  /// After handshake: decrypts encrypted messages (E2EE required).
  void _handleApiChannelMessage(RTCDataChannelMessage message) {
    // During handshake phase, expect binary handshake response
    if (_noise != null && !_noise!.isHandshakeComplete && message.isBinary) {
      _handleHandshakeMessage(message.binary);
      return;
    }
    
    // After handshake, all messages must be encrypted
    if (!_e2eeEnabled || _noise == null) {
      debugPrint('[WebRTC] Ignoring API message: E2EE not active');
      return;
    }
    
    if (!message.isBinary || !NoiseTransport.isTransportMessage(message.binary)) {
      debugPrint('[WebRTC] Ignoring non-encrypted API message');
      return;
    }
    
    try {
      final (channel, plaintext) = _noise!.decrypt(message.binary);
      if (channel == NoiseChannel.api) {
        _handleDataMessage(utf8.decode(plaintext));
      }
    } catch (e) {
      debugPrint('[WebRTC] E2EE decryption failed: $e');
    }
  }
  
  void _handleHandshakeMessage(Uint8List data) {
    debugPrint('[WebRTC] Received handshake response (${data.length} bytes)');
    try {
      _noise!.readHandshake(data).then((_) {
        debugPrint('[WebRTC] Handshake message processed');
        if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
          _handshakeCompleter!.complete();
        }
      }).catchError((e) {
        debugPrint('[WebRTC] Handshake read error: $e');
        if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
          _handshakeCompleter!.completeError(e);
        }
      });
    } catch (e) {
      debugPrint('[WebRTC] Handshake processing error: $e');
      if (_handshakeCompleter != null && !_handshakeCompleter!.isCompleted) {
        _handshakeCompleter!.completeError(e);
      }
    }
  }
  
  void _handleDataMessage(String data) {
    debugPrint('[WebRTC] Received data message: ${data.length > 200 ? '${data.substring(0, 200)}...' : data}');
    try {
      final json = jsonDecode(data);
      debugPrint('[WebRTC] Message type: ${json['type']}');
      if (json['type'] == 'response') {
        final id = json['id'];
        debugPrint('[WebRTC] Response for request: $id, status: ${json['status']}');
        final completer = _pendingRequests.remove(id);
        if (completer != null && !completer.isCompleted) {
          debugPrint('[WebRTC] Completing request $id');
          
          // Safely convert headers to Map<String, String>
          final rawHeaders = json['headers'];
          final Map<String, String> headers = {};
          if (rawHeaders is Map) {
            rawHeaders.forEach((key, value) {
              headers[key.toString()] = value.toString();
            });
          }
          
          completer.complete(TunnelResponse(
            status: json['status'] ?? 500,
            headers: headers,
            body: json['body'],
          ));
        } else {
          debugPrint('[WebRTC] No pending request found for $id');
        }
      } else if (json['type'] == 'auth_response') {
        debugPrint('[WebRTC] Auth Response: ${json['status']}');
        if (_authCompleter != null && !_authCompleter!.isCompleted) {
          if (json['status'] == 'ok') {
            _authCompleter!.complete();
          } else {
            _authCompleter!.completeError(json['message'] ?? 'Authentication failed');
          }
        }
      } else if (json['type'] == 'pairing_complete') {
        if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
          _pairingCompleter!.complete(json);
        }
      } else if (json['type'] == 'error') {
         if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
          _pairingCompleter!.completeError(json['message']);
        }
      }
    } catch (e) {
      debugPrint('[WebRTC] Error handling message: $e');
    }
  }
  
  void dispose() {
    _dataChannel?.close();
    _pc?.close();
    _signalingTunnel?.close();
  }
}
