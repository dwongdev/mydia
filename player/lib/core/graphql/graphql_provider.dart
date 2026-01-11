import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../auth/auth_service.dart';
import '../auth/auth_status.dart';
import '../auth/auth_storage.dart';
import '../auth/media_token_service.dart';
import '../config/web_config.dart';
import '../connection/connection_provider.dart';
import '../connection/reconnection_service.dart';
import '../webrtc/media_proxy_service.dart';
import 'client.dart';
import 'webrtc_link.dart';

// ... (existing providers)

// Media Proxy Service Provider
final mediaProxyServiceProvider = FutureProvider<MediaProxyService?>((ref) async {
  // MediaProxyService uses dart:io HttpServer which is not available on web
  if (kIsWeb) {
    debugPrint('[mediaProxyServiceProvider] Skipping on web platform');
    return null;
  }
  
  final connectionState = ref.watch(connectionProvider);
  debugPrint('[mediaProxyServiceProvider] isWebRTCMode=${connectionState.isWebRTCMode}, hasManager=${connectionState.webrtcManager != null}');
  if (connectionState.isWebRTCMode && connectionState.webrtcManager != null) {
    debugPrint('[mediaProxyServiceProvider] Creating media proxy service');
    final proxy = MediaProxyService(connectionState.webrtcManager!);
    await proxy.start();
    debugPrint('[mediaProxyServiceProvider] Media proxy started');
    // Ensure we stop it when provider is disposed
    ref.onDispose(() {
      proxy.stop();
    });
    return proxy;
  }
  debugPrint('[mediaProxyServiceProvider] Not in WebRTC mode, returning null');
  return null;
});

/// Provider for the server URL.
///
/// On web platform, always uses window.location.origin to ensure correct
/// browser-accessible URL (not internal Docker hostnames like 'storage:4000').
/// On native platforms, uses the stored server URL from secure storage.
final serverUrlProvider = FutureProvider<String?>((ref) async {
  // Check WebRTC proxy first
  final mediaProxy = await ref.watch(mediaProxyServiceProvider.future);
  if (mediaProxy != null) {
    final url = await mediaProxy.start(); // Returns http://127.0.0.1:port
    debugPrint('[serverUrlProvider] Using WebRTC proxy: $url');
    return url;
  }

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
final graphqlClientProvider = Provider<GraphQLClient?>((ref) {
  final connectionState = ref.watch(connectionProvider);
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final authTokenAsync = ref.watch(authTokenProvider);
  final authService = ref.watch(authServiceProvider);

  debugPrint('[graphqlClientProvider] Building: isWebRTCMode=${connectionState.isWebRTCMode}, hasManager=${connectionState.webrtcManager != null}');

  // Check if we're in WebRTC mode
  if (connectionState.isWebRTCMode && connectionState.webrtcManager != null) {
    return authTokenAsync.when(
      data: (authToken) {
        debugPrint('[graphqlClientProvider] Using WebRTC mode with authToken=${authToken != null ? "present" : "null"}');
        final link = WebRTCLink(connectionState.webrtcManager!, authToken: authToken);
        return GraphQLClient(
          link: link,
          cache: GraphQLCache(store: HiveStore()),
        );
      },
      loading: () {
        debugPrint('[graphqlClientProvider] Auth token loading...');
        return null;
      },
      error: (error, stackTrace) {
        debugPrint('[graphqlClientProvider] Auth token error in WebRTC mode: $error\n$stackTrace');
        return null;
      },
    );
  }

  // Wait for both async providers to complete (direct mode)
  return serverUrlAsync.when(
    data: (serverUrl) {
      if (serverUrl == null) return null;

      return authTokenAsync.when(
        data: (authToken) {
          debugPrint('[graphqlClientProvider] Using direct mode');
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
        error: (error, stackTrace) {
          debugPrint('[graphqlClientProvider] Auth token error in direct mode: $error\n$stackTrace');
          return null;
        },
      );
    },
    loading: () => null,
    error: (error, stackTrace) {
      debugPrint('[graphqlClientProvider] Server URL error: $error\n$stackTrace');
      return null;
    },
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
        error: (error, stackTrace) {
          debugPrint('[graphqlClientWithSubscriptionsProvider] Auth token error: $error\n$stackTrace');
          return null;
        },
      );
    },
    loading: () => null,
    error: (error, stackTrace) {
      debugPrint('[graphqlClientWithSubscriptionsProvider] Server URL error: $error\n$stackTrace');
      return null;
    },
  );
});

/// Notifier for managing authentication state.
///
/// Use this to update the auth token and server URL, which will automatically
/// refresh the GraphQL client provider.
///
/// On web platform, automatically reads injected auth config from Phoenix.
/// On native platforms, supports offline mode when server is unreachable.
class AuthStateNotifier extends Notifier<AsyncValue<AuthStatus>> {
  /// Whether web config has been initialized (to avoid re-processing).
  bool _webConfigProcessed = false;

  @override
  AsyncValue<AuthStatus> build() {
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
  /// - Entering offline mode if reconnection fails (preserves credentials)
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

      state = AsyncValue.data(isAuth ? AuthStatus.authenticated : AuthStatus.unauthenticated);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Attempt to reconnect to the paired instance using ReconnectionService.
  ///
  /// Returns [AuthStatus.authenticated] if reconnection succeeded,
  /// [AuthStatus.offlineMode] if reconnection failed but credentials exist,
  /// [AuthStatus.unauthenticated] if no valid credentials.
  Future<AuthStatus> _attemptReconnection() async {
    final reconnectionService = ref.read(reconnectionServiceProvider);

    try {
      // Check if relay credentials exist (instanceId) to determine strategy
      final authStorage = getAuthStorage();
      final instanceId = await authStorage.read('instance_id');

      // Use relay-first strategy if we have relay credentials (instanceId).
      // Only force direct-only when there's no instanceId (user logged in directly).
      final hasRelayCredentials = instanceId != null && instanceId.isNotEmpty;
      final forceDirectOnly = !hasRelayCredentials;
      debugPrint('[AuthStateNotifier] instanceId: ${hasRelayCredentials ? "present" : "null"}, strategy: ${forceDirectOnly ? "direct-only" : "relay-first"}');
      final result = await reconnectionService.reconnect(forceDirectOnly: forceDirectOnly);

      if (result.success && result.session != null) {
        final session = result.session!;
        debugPrint('[AuthStateNotifier] Reconnection successful, isRelay=${session.isRelayConnection}');

        // Update auth service with the access token for GraphQL/API authentication
        // Media token is stored separately for streaming
        await authService.setSession(
          token: session.accessToken,
          serverUrl: session.serverUrl,
          userId: session.deviceId,
          username: 'Device ${session.deviceId.substring(0, 8)}',
        );

        // Also update the pairing tokens storage with refreshed tokens
        final authStorage = getAuthStorage();
        await authStorage.write('pairing_media_token', session.mediaToken);
        await authStorage.write('pairing_access_token', session.accessToken);

        // Set the connection provider mode
        if (session.isRelayConnection && session.webrtcManager != null) {
          debugPrint('[AuthStateNotifier] Setting WebRTC manager in connection provider');
          await ref.read(connectionProvider.notifier).setWebRTCManager(
            session.webrtcManager,
            instanceId: session.instanceId,
            relayUrl: session.relayUrl,
          );
        } else {
          debugPrint('[AuthStateNotifier] Setting direct mode in connection provider');
          await ref.read(connectionProvider.notifier).setDirectMode();
        }

        return AuthStatus.authenticated;
      } else {
        debugPrint('[AuthStateNotifier] Reconnection failed: ${result.error}, entering offline mode');
        // Don't clear session - enter offline mode instead to allow downloads access
        return AuthStatus.offlineMode;
      }
    } catch (e) {
      debugPrint('[AuthStateNotifier] Reconnection error: $e, entering offline mode');
      // Don't clear session on error - enter offline mode
      return AuthStatus.offlineMode;
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
    debugPrint('[AuthStateNotifier] _checkAuth() called, setting state to loading');
    state = const AsyncValue.loading();
    try {
      debugPrint('[AuthStateNotifier] Calling isAuthenticated()...');
      final isAuth = await authService.isAuthenticated();
      debugPrint('[AuthStateNotifier] isAuthenticated() returned: $isAuth');
      final status = isAuth ? AuthStatus.authenticated : AuthStatus.unauthenticated;
      state = AsyncValue.data(status);
      debugPrint('[AuthStateNotifier] State set to AsyncValue.data($status)');
    } catch (e, st) {
      debugPrint('[AuthStateNotifier] _checkAuth() error: $e');
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
    state = const AsyncValue.data(AuthStatus.unauthenticated);
  }

  /// Retry connection to server from offline mode.
  ///
  /// Call this when the user taps "Retry Connection" in the offline banner.
  /// If successful, transitions to authenticated state.
  /// If failed, stays in offline mode.
  Future<void> retryConnection() async {
    debugPrint('[AuthStateNotifier] retryConnection() called');
    state = const AsyncValue.loading();

    try {
      final result = await _attemptReconnection();
      state = AsyncValue.data(result);
      debugPrint('[AuthStateNotifier] retryConnection() complete, state=$result');
    } catch (e) {
      debugPrint('[AuthStateNotifier] retryConnection() error: $e');
      // Stay in offline mode on error
      state = const AsyncValue.data(AuthStatus.offlineMode);
    }
  }

  /// Refresh the authentication state.
  Future<void> refresh() async {
    debugPrint('[AuthStateNotifier] refresh() called');
    await _checkAuth();
    debugPrint('[AuthStateNotifier] refresh() complete, state=$state');
  }
}

/// Provider for the auth state notifier.
final authStateProvider =
    NotifierProvider<AuthStateNotifier, AsyncValue<AuthStatus>>(AuthStateNotifier.new);

/// Async provider for the GraphQL client.
///
/// Use this provider in async controllers that need to wait for the client
/// to be available. This properly handles the async loading of auth state.
///
/// NOTE: Uses ref.watch for graphqlClientProvider to ensure updates when
/// connection mode changes (e.g., from direct to relay mode after pairing).
final asyncGraphqlClientProvider = FutureProvider<GraphQLClient>((ref) async {
  debugPrint('[asyncGraphqlClientProvider] Starting...');
  
  // Wait for auth check to complete (isAuthenticatedProvider is a FutureProvider)
  final isAuthenticated = await ref.watch(isAuthenticatedProvider.future);
  debugPrint('[asyncGraphqlClientProvider] isAuthenticated=$isAuthenticated');
  if (!isAuthenticated) {
    throw Exception('Not authenticated');
  }

  // Wait for server URL and token to be available
  final serverUrl = await ref.watch(serverUrlProvider.future);
  debugPrint('[asyncGraphqlClientProvider] serverUrl=$serverUrl');
  await ref.watch(authTokenProvider.future); // Wait for token to be ready

  if (serverUrl == null) {
    throw Exception('Server URL not available');
  }

  // Watch the sync provider to get updates when connection mode changes
  debugPrint('[asyncGraphqlClientProvider] Getting graphqlClientProvider...');
  final client = ref.watch(graphqlClientProvider);
  debugPrint('[asyncGraphqlClientProvider] client=${client != null ? "available" : "null"}');
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
