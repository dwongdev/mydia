import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../auth/auth_service.dart';
import '../auth/media_token_service.dart';
import '../config/web_config.dart';
import '../connection/reconnection_service.dart';
import 'client.dart';

/// Provider for the auth service instance.
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});

/// Provider for the reconnection service instance.
///
/// Used on native platforms to reconnect to a paired instance after app restart.
final reconnectionServiceProvider = Provider<ReconnectionService>((ref) {
  return ReconnectionService();
});

/// Provider for the server URL.
///
/// On web platform, always uses window.location.origin to ensure correct
/// browser-accessible URL (not internal Docker hostnames like 'storage:4000').
/// On native platforms, uses the stored server URL from secure storage.
final serverUrlProvider = FutureProvider<String?>((ref) async {
  // On web, always use the current origin to avoid CORS issues
  // and ensure we use the browser-accessible URL (not Docker internal names)
  if (kIsWeb) {
    final origin = getOriginUrl();
    debugPrint('[serverUrlProvider] kIsWeb=true, origin=$origin');
    if (origin != null) {
      return origin;
    }
  } else {
    debugPrint('[serverUrlProvider] kIsWeb=false, using stored URL');
  }

  // Fall back to stored URL (for native platforms or if origin detection fails)
  final authService = ref.watch(authServiceProvider);
  final storedUrl = await authService.getServerUrl();
  debugPrint('[serverUrlProvider] storedUrl=$storedUrl');
  return storedUrl;
});

/// Provider for the auth token from secure storage.
///
/// This is an async provider that loads the auth token when the app starts.
final authTokenProvider = FutureProvider<String?>((ref) async {
  final authService = ref.watch(authServiceProvider);
  return await authService.getToken();
});

/// Provider for checking if user is authenticated.
final isAuthenticatedProvider = FutureProvider<bool>((ref) async {
  final authService = ref.watch(authServiceProvider);
  return await authService.isAuthenticated();
});

/// Provider for the GraphQL client.
///
/// Returns null if either the server URL or auth token is not available.
/// This provider automatically updates when the server URL or token changes.
/// Includes 401 error handling with logout on auth failure.
final graphqlClientProvider = Provider<GraphQLClient?>((ref) {
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final authTokenAsync = ref.watch(authTokenProvider);
  final authService = ref.watch(authServiceProvider);

  // Wait for both async providers to complete
  return serverUrlAsync.when(
    data: (serverUrl) {
      if (serverUrl == null) return null;

      return authTokenAsync.when(
        data: (authToken) {
          // Create client with 401 error handling
          return createGraphQLClient(
            serverUrl,
            authToken,
            onAuthError: () async {
              // Try to refresh token (currently not supported, returns null)
              final newToken = await authService.refreshToken();
              if (newToken == null) {
                // Token refresh not supported or failed, logout
                await authService.clearSession();
                // Invalidate the auth state to trigger UI update
                ref.invalidate(authStateProvider);
              }
              return newToken;
            },
          );
        },
        loading: () => null,
        error: (_, __) => null,
      );
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Provider for the GraphQL client with WebSocket support for subscriptions.
///
/// Returns null if either the server URL or auth token is not available.
/// Includes 401 error handling with logout on auth failure.
final graphqlClientWithSubscriptionsProvider = Provider<GraphQLClient?>((ref) {
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final authTokenAsync = ref.watch(authTokenProvider);
  final authService = ref.watch(authServiceProvider);

  return serverUrlAsync.when(
    data: (serverUrl) {
      if (serverUrl == null) return null;

      return authTokenAsync.when(
        data: (authToken) {
          return createGraphQLClientWithSubscriptions(
            serverUrl,
            authToken,
            onAuthError: () async {
              // Try to refresh token (currently not supported, returns null)
              final newToken = await authService.refreshToken();
              if (newToken == null) {
                // Token refresh not supported or failed, logout
                await authService.clearSession();
                // Invalidate the auth state to trigger UI update
                ref.invalidate(authStateProvider);
              }
              return newToken;
            },
          );
        },
        loading: () => null,
        error: (_, __) => null,
      );
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Notifier for managing authentication state.
///
/// Use this to update the auth token and server URL, which will automatically
/// refresh the GraphQL client provider.
///
/// On web platform, automatically reads injected auth config from Phoenix.
class AuthStateNotifier extends Notifier<AsyncValue<bool>> {
  /// Whether web config has been initialized (to avoid re-processing).
  bool _webConfigProcessed = false;

  @override
  AsyncValue<bool> build() {
    _initAuth();
    return const AsyncValue.loading();
  }

  AuthService get authService => ref.watch(authServiceProvider);

  /// Initialize authentication, checking for injected web config first.
  ///
  /// On native platforms, attempts to reconnect to the paired instance using
  /// the ReconnectionService. This handles:
  /// - Trying direct URLs first
  /// - Falling back to relay tunnel if direct fails
  /// - Refreshing the auth token on successful reconnection
  Future<void> _initAuth() async {
    state = const AsyncValue.loading();
    try {
      // On web, check for injected auth config from Phoenix
      if (isWebPlatform && !_webConfigProcessed) {
        await _processWebConfig();
        _webConfigProcessed = true;
      }

      // Check if we have stored credentials
      final isAuth = await authService.isAuthenticated();

      // On native platforms with stored credentials, try to reconnect
      if (!isWebPlatform && isAuth) {
        debugPrint('[AuthStateNotifier] Native platform with stored auth, attempting reconnection...');
        final reconnectionResult = await _attemptReconnection();
        state = AsyncValue.data(reconnectionResult);
        return;
      }

      state = AsyncValue.data(isAuth);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Attempt to reconnect to the paired instance using ReconnectionService.
  ///
  /// Returns true if reconnection succeeded and auth was updated,
  /// false if reconnection failed (caller should show login).
  Future<bool> _attemptReconnection() async {
    final reconnectionService = ref.read(reconnectionServiceProvider);

    try {
      final result = await reconnectionService.reconnect();

      if (result.success && result.session != null) {
        final session = result.session!;
        debugPrint('[AuthStateNotifier] Reconnection successful, updating auth session');

        // Update auth service with the refreshed token
        await authService.setSession(
          token: session.mediaToken,
          serverUrl: session.serverUrl,
          userId: session.deviceId,
          username: 'Device ${session.deviceId.substring(0, 8)}',
        );

        return true;
      } else {
        debugPrint('[AuthStateNotifier] Reconnection failed: ${result.error}');
        // Clear invalid session so user is redirected to login
        await authService.clearSession();
        return false;
      }
    } catch (e) {
      debugPrint('[AuthStateNotifier] Reconnection error: $e');
      // Clear session on error to show login
      await authService.clearSession();
      return false;
    }
  }

  /// Process injected web configuration from Phoenix.
  ///
  /// If the web page has auth config injected (window.mydiaConfig),
  /// store it in secure storage for use by the GraphQL client.
  Future<void> _processWebConfig() async {
    final webConfig = getWebConfig();
    if (webConfig == null || !webConfig.hasValidAuth) {
      return;
    }

    // Store the injected auth config
    await authService.setSession(
      token: webConfig.token!,
      serverUrl: webConfig.serverUrl!,
      userId: webConfig.userId ?? '',
      username: webConfig.username ?? '',
    );
  }

  Future<void> _checkAuth() async {
    state = const AsyncValue.loading();
    try {
      final isAuth = await authService.isAuthenticated();
      state = AsyncValue.data(isAuth);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Login with server URL and token.
  Future<void> login({
    required String serverUrl,
    required String token,
    required String userId,
    required String username,
  }) async {
    await authService.setSession(
      serverUrl: serverUrl,
      token: token,
      userId: userId,
      username: username,
    );
    await _checkAuth();
  }

  /// Logout and clear all session data.
  Future<void> logout() async {
    await authService.clearSession();
    state = const AsyncValue.data(false);
  }

  /// Refresh the authentication state.
  Future<void> refresh() async {
    await _checkAuth();
  }
}

/// Provider for the auth state notifier.
final authStateProvider =
    NotifierProvider<AuthStateNotifier, AsyncValue<bool>>(AuthStateNotifier.new);

/// Async provider for the GraphQL client.
///
/// Use this provider in async controllers that need to wait for the client
/// to be available. This properly handles the async loading of auth state.
final asyncGraphqlClientProvider = FutureProvider<GraphQLClient>((ref) async {
  // Wait for auth check to complete (isAuthenticatedProvider is a FutureProvider)
  final isAuthenticated = await ref.watch(isAuthenticatedProvider.future);
  if (!isAuthenticated) {
    throw Exception('Not authenticated');
  }

  // Wait for server URL and token to be available
  final serverUrl = await ref.watch(serverUrlProvider.future);
  await ref.watch(authTokenProvider.future); // Wait for token to be ready

  if (serverUrl == null) {
    throw Exception('Server URL not available');
  }

  // Now read the sync provider - it should have data since auth is ready
  final client = ref.read(graphqlClientProvider);
  if (client == null) {
    // This shouldn't happen if auth is ready, but handle it gracefully
    throw Exception('GraphQL client not available');
  }
  return client;
});

/// Provider for the media token service.
///
/// Provides media token management for authenticated direct media requests.
/// Requires GraphQL client to be available for token refresh.
final mediaTokenServiceProvider = Provider<MediaTokenService?>((ref) {
  final client = ref.watch(graphqlClientProvider);
  if (client == null) return null;

  return MediaTokenService(client);
});

/// Async provider for the media token service.
///
/// Use this in async contexts where you need to wait for the service to be ready.
final asyncMediaTokenServiceProvider = FutureProvider<MediaTokenService>((ref) async {
  final client = await ref.watch(asyncGraphqlClientProvider.future);
  return MediaTokenService(client);
});

/// Provider for the current media token (if available).
final mediaTokenProvider = FutureProvider<String?>((ref) async {
  final service = await ref.watch(asyncMediaTokenServiceProvider.future);
  return await service.getToken();
});
