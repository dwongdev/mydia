import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/p2p_service.dart';

final localProxyServiceProvider = Provider<LocalProxyService>((ref) {
  final p2p = ref.watch(p2pServiceProvider);
  final service = LocalProxyService(p2p);
  ref.onDispose(() => service.stop());
  return service;
});

/// Local HTTP proxy for streaming HLS media over P2P.
///
/// This service creates a local HTTP server that proxies HLS requests
/// to the P2P network. The video player connects to this local server,
/// and requests are forwarded to the remote server via P2P.
///
/// URL Format: /hls/{session_id}/{path}
/// Example: /hls/abc123/index.m3u8
/// Example: /hls/abc123/segment_001.ts
class LocalProxyService {
  final P2pService _p2p;
  HttpServer? _server;

  /// The peer ID to send HLS requests to
  String? _targetPeer;

  /// Auth token for HLS requests
  String? _authToken;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  LocalProxyService(this._p2p);

  /// Start the local proxy server.
  ///
  /// [targetPeer] - The peer ID or EndpointAddr JSON to send HLS requests to.
  /// [authToken] - Optional auth token for HLS requests.
  Future<void> start({
    required String targetPeer,
    String? authToken,
  }) async {
    if (_server != null) {
      // Update config if already running
      _targetPeer = targetPeer;
      _authToken = authToken;
      return;
    }

    _targetPeer = targetPeer;
    _authToken = authToken;

    // Bind to loopback on ephemeral port
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    debugPrint('[LocalProxy] Started on http://127.0.0.1:${_server!.port}');

    _server!.listen((HttpRequest request) {
      _handleRequest(request);
    });
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _targetPeer = null;
    _authToken = null;
    debugPrint('[LocalProxy] Stopped');
  }

  /// Build the HLS URL for a session.
  ///
  /// Returns the local proxy URL for the HLS playlist.
  /// The video player should use this URL to start playback.
  String buildHlsUrl(String sessionId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/hls/$sessionId/index.m3u8';
  }

  /// Build the base URL for HLS content.
  ///
  /// HLS manifests will use relative URLs for segments,
  /// so they will resolve against this base URL.
  String buildBaseUrl(String sessionId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/hls/$sessionId/';
  }

  // Handle incoming HTTP requests
  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    debugPrint('[LocalProxy] ${request.method} $path');

    // Parse HLS request: /hls/{session_id}/{path...}
    if (path.startsWith('/hls/')) {
      await _handleHlsRequest(request);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not Found');
      await request.response.close();
    }
  }

  Future<void> _handleHlsRequest(HttpRequest request) async {
    try {
      // Parse path: /hls/{session_id}/{path...}
      final pathParts = request.uri.path.substring('/hls/'.length).split('/');
      if (pathParts.length < 2) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Invalid HLS path format. Expected: /hls/{session_id}/{path}');
        await request.response.close();
        return;
      }

      final sessionId = pathParts[0];
      final hlsPath = pathParts.sublist(1).join('/');

      if (sessionId.isEmpty || hlsPath.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Session ID and path are required');
        await request.response.close();
        return;
      }

      if (_targetPeer == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.write('No target peer configured');
        await request.response.close();
        return;
      }

      // Parse Range header for seeking support
      int? rangeStart;
      int? rangeEnd;
      final rangeHeader = request.headers.value('Range');
      if (rangeHeader != null) {
        final range = _parseRangeHeader(rangeHeader);
        rangeStart = range.$1;
        rangeEnd = range.$2;
      }

      debugPrint('[LocalProxy] HLS request: session=$sessionId, path=$hlsPath, range=$rangeStart-$rangeEnd');

      // Forward to P2P
      final response = await _p2p.sendHlsRequest(
        peer: _targetPeer!,
        sessionId: sessionId,
        path: hlsPath,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        authToken: _authToken,
      );

      // Set response status
      request.response.statusCode = response.header.status;

      // Set response headers
      request.response.headers.contentType = ContentType.parse(response.header.contentType);
      request.response.headers.contentLength = response.header.contentLength.toInt();

      if (response.header.contentRange != null) {
        request.response.headers.set('Content-Range', response.header.contentRange!);
      }
      if (response.header.cacheControl != null) {
        request.response.headers.set('Cache-Control', response.header.cacheControl!);
      }

      // Allow CORS for local playback
      request.response.headers.set('Access-Control-Allow-Origin', '*');

      // Write response body
      request.response.add(response.data);
      await request.response.close();

      debugPrint('[LocalProxy] Served ${response.data.length} bytes for $hlsPath');

    } catch (e, stack) {
      debugPrint('[LocalProxy] Error handling HLS request: $e');
      debugPrint('[LocalProxy] Stack: $stack');

      if (!request.response.headers.persistentConnection) {
        // Response already started, can't change status
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Error: $e');
      await request.response.close();
    }
  }

  /// Parse HTTP Range header.
  /// Returns (start, end) tuple. End may be null for open-ended ranges.
  (int?, int?) _parseRangeHeader(String header) {
    // Format: "bytes=start-end" or "bytes=start-"
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
    if (match == null) return (null, null);

    final start = int.tryParse(match.group(1) ?? '');
    final endStr = match.group(2);
    final end = endStr != null && endStr.isNotEmpty ? int.tryParse(endStr) : null;

    return (start, end);
  }
}
