/// Result of resolving a claim code via the relay API.
///
/// In iroh mode, the relay returns the server's EndpointAddr JSON directly,
/// which can be used to dial the server.
class ClaimResolveResult {
  /// The server's EndpointAddr as JSON string.
  /// This can be passed directly to P2pService.dial().
  final String nodeAddr;

  /// When this claim code expires.
  final DateTime? expiresAt;

  ClaimResolveResult({
    required this.nodeAddr,
    this.expiresAt,
  });

  factory ClaimResolveResult.fromJson(Map<String, dynamic> json) {
    return ClaimResolveResult(
      nodeAddr: json['node_addr'] as String,
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
    );
  }
}
