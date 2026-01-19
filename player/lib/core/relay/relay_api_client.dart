import 'dart:convert';
import 'package:http/http.dart' as http;
import 'claim_resolve_result.dart';

class RelayApiClient {
  final String baseUrl;
  final http.Client _client;

  RelayApiClient({
    this.baseUrl = 'https://relay.mydia.dev',
    http.Client? client,
  }) : _client = client ?? http.Client();

  Future<ClaimResolveResult> resolveClaimCode(String code) async {
    final url = Uri.parse('$baseUrl/relay/claim/$code/resolve');
    
    try {
      final response = await _client.post(url);

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
      if (e is InvalidClaimCodeException || e is RateLimitedException) {
        rethrow;
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
