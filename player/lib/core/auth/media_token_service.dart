import 'package:graphql_flutter/graphql_flutter.dart';
import 'auth_storage.dart';
import '../../graphql/mutations/refresh_media_token.graphql.dart';

/// Service for managing media access tokens for authenticated direct media requests.
///
/// In claim code mode, media requests use a separate JWT token (media_token) that's:
/// - Shorter-lived (24 hours default from backend)
/// - Has specific permissions (stream, download, thumbnails)
/// - Refreshed via GraphQL before expiry
///
/// Media tokens are used for direct media access without requiring session-based auth.
class MediaTokenService {
  final AuthStorage _storage;
  final GraphQLClient _graphqlClient;

  static const _mediaTokenKey = 'media_token';
  static const _mediaTokenExpiryKey = 'media_token_expiry';

  /// Threshold for proactive token refresh (1 hour before expiry).
  static const _refreshThresholdSeconds = 3600;

  MediaTokenService(this._graphqlClient, {AuthStorage? storage})
      : _storage = storage ?? getAuthStorage();

  /// Get the stored media token.
  Future<String?> getToken() async {
    return await _storage.read(_mediaTokenKey);
  }

  /// Store a media token and its expiration timestamp.
  Future<void> setToken(String token, DateTime expiresAt) async {
    await Future.wait([
      _storage.write(_mediaTokenKey, token),
      _storage.write(_mediaTokenExpiryKey, expiresAt.toIso8601String()),
    ]);
  }

  /// Clear the stored media token.
  Future<void> clearToken() async {
    await Future.wait([
      _storage.delete(_mediaTokenKey),
      _storage.delete(_mediaTokenExpiryKey),
    ]);
  }

  /// Get the stored token expiration timestamp.
  Future<DateTime?> getExpiryTime() async {
    final expiryStr = await _storage.read(_mediaTokenExpiryKey);
    if (expiryStr == null) return null;

    try {
      return DateTime.parse(expiryStr);
    } catch (e) {
      return null;
    }
  }

  /// Check if the token needs to be refreshed.
  ///
  /// Returns true if:
  /// - Token doesn't exist
  /// - Token expiry time is not stored
  /// - Token will expire within the refresh threshold (1 hour)
  Future<bool> needsRefresh() async {
    final token = await getToken();
    if (token == null) return false; // No token to refresh

    final expiryTime = await getExpiryTime();
    if (expiryTime == null) return true; // Unknown expiry, should refresh

    final now = DateTime.now();
    final timeUntilExpiry = expiryTime.difference(now);

    return timeUntilExpiry.inSeconds <= _refreshThresholdSeconds;
  }

  /// Refresh the media token by calling the GraphQL mutation.
  ///
  /// Returns true if refresh was successful, false otherwise.
  Future<bool> refreshToken() async {
    final currentToken = await getToken();
    if (currentToken == null) {
      return false; // No token to refresh
    }

    try {
      final result = await _graphqlClient.mutate(
        MutationOptions(
          document: documentNodeMutationRefreshMediaToken,
          variables: Variables$Mutation$RefreshMediaToken(
            token: currentToken,
          ).toJson(),
        ),
      );

      if (result.hasException) {
        return false;
      }

      final mutation = result.data != null
          ? Mutation$RefreshMediaToken.fromJson(result.data!)
          : null;

      if (mutation?.refreshMediaToken == null) {
        return false;
      }

      final refreshData = mutation!.refreshMediaToken!;
      final newToken = refreshData.token;
      final expiresAt = DateTime.parse(refreshData.expiresAt);

      await setToken(newToken, expiresAt);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Build a media URL with authentication.
  ///
  /// For claim code mode: appends token as query parameter
  /// For direct mode: token is in Authorization header (handled by HTTP client)
  Future<String> buildMediaUrl(String baseUrl, String path) async {
    final token = await getToken();

    if (token == null) {
      // No media token, return URL as-is (will use Authorization header)
      return '$baseUrl$path';
    }

    // Append token as query parameter for claim code mode
    final separator = path.contains('?') ? '&' : '?';
    return '$baseUrl$path${separator}media_token=$token';
  }

  /// Check if token is expired.
  Future<bool> isExpired() async {
    final expiryTime = await getExpiryTime();
    if (expiryTime == null) return true;

    return DateTime.now().isAfter(expiryTime);
  }

  /// Ensure token is valid and refreshed if needed.
  ///
  /// Call this before making media requests to ensure the token is fresh.
  /// Returns true if token is ready to use, false if unavailable.
  Future<bool> ensureValidToken() async {
    final token = await getToken();
    if (token == null) {
      return false; // No token available
    }

    if (await isExpired()) {
      // Token is expired, try to refresh
      return await refreshToken();
    }

    if (await needsRefresh()) {
      // Token is close to expiry, refresh proactively
      await refreshToken();
    }

    return true;
  }
}
