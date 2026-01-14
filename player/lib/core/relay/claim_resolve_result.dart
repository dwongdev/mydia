class ClaimResolveResult {
  final String namespace;
  final DateTime expiresAt;
  final List<String> rendezvousPoints;

  ClaimResolveResult({
    required this.namespace,
    required this.expiresAt,
    required this.rendezvousPoints,
  });

  factory ClaimResolveResult.fromJson(Map<String, dynamic> json) {
    return ClaimResolveResult(
      namespace: json['namespace'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
      rendezvousPoints: (json['rendezvous_points'] as List)
          .map((e) => e as String)
          .toList(),
    );
  }
}
