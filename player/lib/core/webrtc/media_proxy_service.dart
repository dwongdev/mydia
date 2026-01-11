import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'webrtc_connection_manager.dart';

/// A local HTTP proxy that tunnels requests over WebRTC Data Channel.
///
/// This service binds to localhost on a random port and forwards incoming
/// HTTP requests to the WebRTC connection. It handles converting HTTP Range
/// requests into the JSON protocol expected by the server.
class MediaProxyService {
  final WebRTCConnectionManager _manager;
  HttpServer? _server;
  int _port = 0;

  MediaProxyService(this._manager);

  /// Starts the proxy server.
  /// Returns the base URL (e.g. "http://127.0.0.1:45321").
  Future<String> start() async {
    if (_server != null) {
      return 'http://127.0.0.1:$_port';
    }

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    
    _server!.listen(_handleRequest);
    
    debugPrint('[MediaProxy] Started on port $_port');
    return 'http://127.0.0.1:$_port';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _handleRequest(HttpRequest request) async {
    // URL format: /stream/file_id
    // We assume the path segment after /stream/ is the file ID.
    final pathSegments = request.uri.pathSegments;
    if (pathSegments.isEmpty || pathSegments[0] != 'stream' || pathSegments.length < 2) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }

    final fileId = pathSegments[1];
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    
    int start = 0;
    int? end;

    if (rangeHeader != null) {
      // Parse "bytes=0-100" or "bytes=0-"
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        start = int.parse(match.group(1)!);
        if (match.group(2)!.isNotEmpty) {
          end = int.parse(match.group(2)!);
        }
      }
    }

    debugPrint('[MediaProxy] Requesting $fileId range: $start-$end');

    try {
      final streamResponse = await _manager.requestMedia(fileId, start, end);
      
      request.response.statusCode = streamResponse.statusCode;
      
      streamResponse.headers.forEach((key, value) {
        request.response.headers.set(key, value);
      });
      
      // Pipe data
      await request.response.addStream(streamResponse.stream);
      await request.response.close();
      
    } catch (e) {
      debugPrint('[MediaProxy] Error serving request: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.close();
      } catch (_) {}
    }
  }
}

/// Result of a media request containing headers and data stream.
class MediaStreamResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> stream;

  MediaStreamResponse(this.statusCode, this.headers, this.stream);
}
