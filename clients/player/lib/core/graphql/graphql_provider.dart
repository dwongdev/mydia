import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../auth/auth_service.dart';
import '../config/web_config.dart';
import 'client.dart';

/// Provider for the auth service instance.
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});

/// Provider for the server URL from secure storage.
///
/// This is an async provider that loads the server URL when the app starts.
final serverUrlProvider = FutureProvider<String?>((ref) async {
  final authService = ref.watch(authServiceProvider);
  return await authService.getServerUrl();
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
  Future<void> _initAuth() async {
    state = const AsyncValue.loading();
    try {
      // On web, check for injected auth config from Phoenix
      if (isWebPlatform && !_webConfigProcessed) {
        await _processWebConfig();
        _webConfigProcessed = true;
      }

      final isAuth = await authService.isAuthenticated();
      state = AsyncValue.data(isAuth);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
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
