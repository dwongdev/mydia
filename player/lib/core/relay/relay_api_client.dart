import 'dart:convert';
import 'package:http/http.dart' as http;
import 'claim_resolve_result.dart';

export 'claim_resolve_result.dart' show ServerNotOnlineException;

const _defaultRelayUrl = String.fromEnvironment(
  'RELAY_URL',
  defaultValue: 'https://relay.mydia.dev',
);

class RelayApiClient {
  final String baseUrl;
  final http.Client _client;

  RelayApiClient({
    this.baseUrl = _defaultRelayUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Future<ClaimResolveResult> resolveClaimCode(String code) async {
    // Use the new /pairing/claim/:code endpoint which directly returns node_addr
    final url = Uri.parse('$baseUrl/pairing/claim/$code');

    try {
      final response = await _client.get(url);

      if (response.statusCode == 200) {
        return ClaimResolveResult.fromJson(jsonDecode(response.body));
      } else if (response.statusCode == 404) {
        throw InvalidClaimCodeException();
      } else if (response.statusCode == 429) {
        throw RateLimitedException();
      } else {
        throw Exception('Relay API error: ${response.statusCode}');
      }
    } catch (e) {
      if (e is InvalidClaimCodeException ||
          e is RateLimitedException ||
          e is ServerNotOnlineException) {
        rethrow;
      }
      if (e is FormatException) {
        throw Exception('Invalid response from relay server: $e');
      }
      throw Exception('Network error connecting to relay: $e');
    }
  }
}

class InvalidClaimCodeException implements Exception {
  @override
  String toString() => 'Invalid or expired claim code';
}

class RateLimitedException implements Exception {
  @override
  String toString() => 'Too many attempts. Please try again later.';
}
