import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../presentation/screens/home_screen.dart';
import '../../presentation/screens/login_screen.dart';
import '../../presentation/screens/movie/movie_detail_screen.dart';
import '../../presentation/screens/show/show_detail_screen.dart';
import '../../presentation/screens/episode_detail_screen.dart';
import '../../presentation/screens/library/library_screen.dart';
import '../../presentation/screens/library/library_controller.dart';
import '../../presentation/screens/settings_screen.dart';
import '../../presentation/screens/settings/devices_screen.dart';
import '../../presentation/screens/player/player_screen.dart';
import '../../presentation/screens/downloads/downloads_screen.dart';
import '../../presentation/widgets/app_shell.dart';
import '../graphql/graphql_provider.dart';

part 'app_router.g.dart';

/// Global key for the navigator used by the app shell
final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// Transition duration for page animations
const _transitionDuration = Duration(milliseconds: 300);

/// Creates a slide-fade transition page (Material 3 style)
/// Slides in from right while fading in
CustomTransitionPage<T> _buildSlideTransition<T>({
  required Widget child,
  required GoRouterState state,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: _transitionDuration,
    reverseTransitionDuration: _transitionDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // Slide from right
      final slideAnimation = Tween<Offset>(
        begin: const Offset(0.25, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ));

      // Fade in
      final fadeAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
      );

      // Secondary animation for the outgoing page
      final secondarySlide = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.15, 0),
      ).animate(CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
      ));

      final secondaryFade = Tween<double>(
        begin: 1.0,
        end: 0.9,
      ).animate(secondaryAnimation);

      return SlideTransition(
        position: secondarySlide,
        child: FadeTransition(
          opacity: secondaryFade,
          child: SlideTransition(
            position: slideAnimation,
            child: FadeTransition(
              opacity: fadeAnimation,
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

/// Creates a fade transition page (for modals/overlays)
CustomTransitionPage<T> _buildFadeTransition<T>({
  required Widget child,
  required GoRouterState state,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
        ),
        child: child,
      );
    },
  );
}

/// Simple ChangeNotifier to trigger GoRouter refreshes.
/// The actual auth state is read directly from the provider in the redirect callback.
class _AuthRefreshNotifier extends ChangeNotifier {
  void refresh() {
    debugPrint('[AppRouter] _AuthRefreshNotifier.refresh() called');
    notifyListeners();
  }
}

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  debugPrint('[AppRouter] Creating appRouter provider');

  // Simple notifier just to trigger GoRouter refreshes
  final refreshNotifier = _AuthRefreshNotifier();

  // Listen to auth state changes and trigger router refresh
  ref.listen<AsyncValue<bool>>(authStateProvider, (previous, next) {
    debugPrint('[AppRouter] Auth state changed: $previous -> $next');
    refreshNotifier.refresh();
  });

  // Dispose the notifier when the provider is disposed
  ref.onDispose(() {
    debugPrint('[AppRouter] Disposing appRouter provider');
    refreshNotifier.dispose();
  });

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      // Read auth state directly from the provider each time
      // This ensures we always get the latest state
      final authState = ref.read(authStateProvider);
      final isAuthenticated = authState.maybeWhen(
        data: (value) => value,
        orElse: () => false,
      );
      final isLoading = authState.isLoading;
      final isLoginRoute = state.matchedLocation == '/login';

      debugPrint('[AppRouter] Redirect check: authState=$authState, isAuthenticated=$isAuthenticated, isLoading=$isLoading, path=${state.matchedLocation}');

      // While loading, allow navigation to continue
      if (isLoading) {
        return null;
      }

      // If not authenticated and not on login page, redirect to login
      if (!isAuthenticated && !isLoginRoute) {
        debugPrint('[AppRouter] Redirecting to /login (not authenticated)');
        return '/login';
      }

      // If authenticated and on login page, redirect to home
      if (isAuthenticated && isLoginRoute) {
        debugPrint('[AppRouter] Redirecting to / (authenticated on login page)');
        return '/';
      }

      // No redirect needed
      return null;
    },
    routes: [
      // Login route - outside shell (fade transition)
      GoRoute(
        path: '/login',
        name: 'login',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _buildFadeTransition(
          child: const LoginScreen(),
          state: state,
        ),
      ),

      // Shell route for main app with bottom navigation
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(
          location: state.matchedLocation,
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/',
            name: 'home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/movies',
            name: 'movies_library',
            builder: (context, state) => const LibraryScreen(
              libraryType: LibraryType.movies,
            ),
          ),
          GoRoute(
            path: '/shows',
            name: 'shows_library',
            builder: (context, state) => const LibraryScreen(
              libraryType: LibraryType.tvShows,
            ),
          ),
          GoRoute(
            path: '/downloads',
            name: 'downloads',
            builder: (context, state) => const DownloadsScreen(),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),

      // Detail routes - outside shell (slide-fade transition)
      GoRoute(
        path: '/settings/devices',
        name: 'devices',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          return _buildSlideTransition(
            child: const DevicesScreen(),
            state: state,
          );
        },
      ),
      GoRoute(
        path: '/movie/:id',
        name: 'movie_detail',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final id = state.pathParameters['id']!;
          return _buildSlideTransition(
            child: MovieDetailScreen(id: id),
            state: state,
          );
        },
      ),
      GoRoute(
        path: '/show/:id',
        name: 'show_detail',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final id = state.pathParameters['id']!;
          return _buildSlideTransition(
            child: ShowDetailScreen(id: id),
            state: state,
          );
        },
      ),
      GoRoute(
        path: '/episode/:id',
        name: 'episode_detail',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final id = state.pathParameters['id']!;
          return _buildSlideTransition(
            child: EpisodeDetailScreen(id: id),
            state: state,
          );
        },
      ),
      // Player route - fade transition (fullscreen experience)
      GoRoute(
        path: '/player/:type/:id',
        name: 'player',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final type = state.pathParameters['type']!;
          final id = state.pathParameters['id']!;
          final fileId = state.uri.queryParameters['fileId'];
          final title = state.uri.queryParameters['title'];

          if (fileId == null) {
            // If no fileId provided, show error
            return _buildFadeTransition(
              child: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      const Text('No file selected for playback'),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () => context.pop(),
                        child: const Text('Go Back'),
                      ),
                    ],
                  ),
                ),
              ),
              state: state,
            );
          }

          return _buildFadeTransition(
            child: PlayerScreen(
              mediaType: type,
              mediaId: id,
              fileId: fileId,
              title: title,
            ),
            state: state,
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Page not found: ${state.uri}'),
      ),
    ),
  );
}
