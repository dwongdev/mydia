/// Exception thrown when the server for a claim code is not online.
class ServerNotOnlineException implements Exception {
  final String message;
  ServerNotOnlineException(this.message);

  @override
  String toString() => message;
}

/// Result of resolving a claim code via the relay API.
///
/// The /pairing/claim/:code endpoint returns the server's EndpointAddr directly,
/// which can be used to dial the server.
class ClaimResolveResult {
  /// The server's EndpointAddr as JSON string.
  /// This can be passed directly to P2pService.dial().
  final String nodeAddr;

  ClaimResolveResult({
    required this.nodeAddr,
  });

  factory ClaimResolveResult.fromJson(Map<String, dynamic> json) {
    final nodeAddr = json['node_addr'] as String?;
    if (nodeAddr == null) {
      throw FormatException(
        'Invalid response from relay: missing node_addr. Response: $json',
      );
    }
    return ClaimResolveResult(nodeAddr: nodeAddr);
  }
}
