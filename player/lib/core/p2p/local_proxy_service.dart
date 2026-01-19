import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/libp2p_service.dart';

final localProxyServiceProvider = Provider<LocalProxyService>((ref) {
  final libp2p = ref.watch(libp2pServiceProvider);
  final service = LocalProxyService(libp2p);
  ref.onDispose(() => service.stop());
  return service;
});

/// Local HTTP proxy for streaming media over libp2p.
/// 
/// TODO: Media streaming over libp2p is not yet implemented.
/// This service will proxy HTTP requests to libp2p ReadMedia requests
/// once the media streaming protocol is complete.
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
    
    if (path == '/stream') {
      // TODO: Implement media streaming over libp2p
      // This requires ReadMedia request/response protocol in the p2p core
      debugPrint('[LocalProxy] Media streaming not yet implemented');
      request.response.statusCode = HttpStatus.notImplemented;
      request.response.write('Media streaming over libp2p not yet implemented');
      await request.response.close();
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }
}
