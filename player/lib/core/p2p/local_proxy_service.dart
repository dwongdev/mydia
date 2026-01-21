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

/// Local HTTP proxy for streaming media over P2P.
///
/// TODO: Media streaming over P2P is not yet implemented.
/// This service will proxy HTTP requests to P2P ReadMedia requests
/// once the media streaming protocol is complete.
class LocalProxyService {
  final P2pService _p2p;
  HttpServer? _server;
  int get port => _server?.port ?? 0;

  LocalProxyService(this._p2p);

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
    
    if (path == '/stream') {
      // TODO: Implement media streaming over P2P
      // This requires ReadMedia request/response protocol in the P2P core
      debugPrint('[LocalProxy] Media streaming not yet implemented');
      request.response.statusCode = HttpStatus.notImplemented;
      request.response.write('Media streaming over P2P not yet implemented');
      await request.response.close();
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }
}
