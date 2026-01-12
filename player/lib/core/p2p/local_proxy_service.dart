import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/libp2p_service.dart';

final localProxyServiceProvider = Provider<LocalProxyService>((ref) {
  final libp2p = ref.watch(libp2pServiceProvider);
  final service = LocalProxyService(libp2p);
  ref.onDispose(() => service.stop());
  return service;
});

class LocalProxyService {
  final Libp2pService _libp2p;
  HttpServer? _server;
  int get port => _server?.port ?? 0;

  LocalProxyService(this._libp2p);

  Future<void> start() async {
    if (_server != null) return;

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
  }

  // URL Format: /stream?peer=PEER_ID&path=FILE_PATH_ENCODED
  void _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    
    if (path == '/stream') {
      final peerId = query['peer'];
      final filePathEncoded = query['path'];
      
      if (peerId == null || filePathEncoded == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Missing peer or path');
        await request.response.close();
        return;
      }

      final filePath = Uri.decodeComponent(filePathEncoded);
      debugPrint('[LocalProxy] Requesting media: $filePath from $peerId');

      try {
        // Open P2P stream
        final streamId = await _libp2p.requestMedia(peerId, filePath);
        debugPrint('[LocalProxy] Stream opened: $streamId');

        request.response.headers.contentType = ContentType.binary;
        // We don't know content-length usually, so chunked transfer encoding is used by default

        // Pipe data
        final chunkSize = 64 * 1024; // 64KB chunks
        while (true) {
          try {
            final chunk = await _libp2p.readStreamChunk(streamId, chunkSize);
            if (chunk.isEmpty) break; // EOF check if rust returns empty list on EOF?
            // Wait, my Rust impl returns Err("EOF") on EOF. 
            // Dart bindings throw AnyhowException on Err.
            
            request.response.add(chunk);
            await request.response.flush();
          } catch (e) {
            if (e.toString().contains("EOF")) {
              debugPrint('[LocalProxy] Stream EOF');
              break;
            }
            debugPrint('[LocalProxy] Stream error: $e');
            // If connection closed by client, stop
            break;
          }
        }
      } catch (e) {
        debugPrint('[LocalProxy] Failed to proxy media: $e');
        request.response.statusCode = HttpStatus.internalServerError;
      } finally {
        await request.response.close();
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }
}
