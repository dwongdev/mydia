/// Relay service for claim code lookup and instance discovery.
///
/// This service communicates with the metadata-relay to:
/// - Look up claim codes and get instance connection info
/// - Consume claims after successful pairing
library;

import 'dart:convert';
import 'package:http/http.dart' as http;

/// Response from looking up a claim code.
class ClaimCodeInfo {
  /// The claim ID (for consuming after pairing).
  final String claimId;

  /// The instance ID.
  final String instanceId;

  /// The instance's public key (base64 encoded).
  final String publicKey;

  /// Direct URLs to connect to the instance.
  final List<String> directUrls;

  /// Whether the instance is currently online.
  final bool online;

  /// The user ID associated with the claim.
  final String userId;

  const ClaimCodeInfo({
    required this.claimId,
    required this.instanceId,
    required this.publicKey,
    required this.directUrls,
    required this.online,
    required this.userId,
  });

  factory ClaimCodeInfo.fromJson(Map<String, dynamic> json) {
    return ClaimCodeInfo(
      claimId: json['claim_id'] as String,
      instanceId: json['instance_id'] as String,
      publicKey: json['public_key'] as String,
      directUrls: (json['direct_urls'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      online: json['online'] as bool? ?? false,
      userId: json['user_id'] as String,
    );
  }
}

/// Result of a relay operation.
class RelayResult<T> {
  final bool success;
  final T? data;
  final String? error;

  const RelayResult._({
    required this.success,
    this.data,
    this.error,
  });

  factory RelayResult.success(T data) {
    return RelayResult._(success: true, data: data);
  }

  factory RelayResult.error(String error) {
    return RelayResult._(success: false, error: error);
  }
}

/// Service for communicating with the metadata-relay.
///
/// The relay service handles claim code lookups and provides instance
/// connection information for device pairing.
class RelayService {
  RelayService({String? relayUrl, http.Client? httpClient})
      : _relayUrl = relayUrl ?? _defaultRelayUrl,
        _httpClient = httpClient ?? http.Client();

  final String _relayUrl;
  final http.Client _httpClient;

  // Default relay URL - in dev environment, the relay is at metadata-relay:4001
  // In production, this should be configurable
  static const _defaultRelayUrl = 'http://metadata-relay:4001';

  /// Looks up a claim code and returns instance connection info.
  ///
  /// This calls `POST /relay/claim/:code` on the relay service.
  ///
  /// Returns [ClaimCodeInfo] on success, or an error message on failure.
  Future<RelayResult<ClaimCodeInfo>> lookupClaimCode(String code) async {
    final normalizedCode = code.toUpperCase().trim();

    if (normalizedCode.isEmpty) {
      return RelayResult.error('Claim code cannot be empty');
    }

    try {
      final url = Uri.parse('$_relayUrl/relay/claim/$normalizedCode');

      final response = await _httpClient.post(
        url,
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final info = ClaimCodeInfo.fromJson(json);

        if (!info.online) {
          return RelayResult.error(
              'Server is currently offline. Please try again later.');
        }

        return RelayResult.success(info);
      } else if (response.statusCode == 404) {
        return RelayResult.error('Invalid claim code');
      } else if (response.statusCode == 400) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final message = json['message'] as String? ?? 'Invalid claim code';
        return RelayResult.error(message);
      } else {
        return RelayResult.error(
            'Failed to lookup claim code (${response.statusCode})');
      }
    } catch (e) {
      if (e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused')) {
        return RelayResult.error(
            'Cannot reach relay service. Check your network connection.');
      }
      return RelayResult.error('Network error: $e');
    }
  }

  /// Marks a claim as consumed after successful pairing.
  ///
  /// This should be called after the device has been successfully paired
  /// with the instance.
  Future<RelayResult<void>> consumeClaim(
      String claimId, String deviceId) async {
    try {
      final url = Uri.parse('$_relayUrl/relay/claim/consume');

      final response = await _httpClient.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'claim_id': claimId,
          'device_id': deviceId,
        }),
      );

      if (response.statusCode == 200) {
        return RelayResult.success(null);
      } else {
        return RelayResult.error(
            'Failed to consume claim (${response.statusCode})');
      }
    } catch (e) {
      return RelayResult.error('Network error: $e');
    }
  }

  /// Closes the HTTP client.
  void dispose() {
    _httpClient.close();
  }
}
