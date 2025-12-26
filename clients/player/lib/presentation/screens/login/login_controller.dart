import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/graphql/graphql_provider.dart';

part 'login_controller.g.dart';

/// State for the login screen.
class LoginState {
  const LoginState({
    this.isLoading = false,
    this.error,
    this.success = false,
  });

  final bool isLoading;
  final String? error;
  final bool success;

  LoginState copyWith({
    bool? isLoading,
    String? error,
    bool? success,
  }) {
    return LoginState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      success: success ?? this.success,
    );
  }

  factory LoginState.initial() => const LoginState();
}

@riverpod
class LoginController extends _$LoginController {
  @override
  LoginState build() => LoginState.initial();

  /// Perform login with the given credentials.
  Future<void> login(
    String serverUrl,
    String username,
    String password,
  ) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final authService = ref.read(authServiceProvider);

      // Call the login method from AuthService
      final sessionData = await authService.login(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      // Update the auth state provider to trigger UI updates
      await ref.read(authStateProvider.notifier).refresh();

      state = state.copyWith(isLoading: false, success: true);
    } catch (e) {
      // Extract a user-friendly error message
      String errorMessage = 'Login failed. Please check your credentials.';

      if (e.toString().contains('401') || e.toString().contains('invalid')) {
        errorMessage = 'Invalid username or password';
      } else if (e.toString().contains('connection') ||
                 e.toString().contains('network') ||
                 e.toString().contains('SocketException')) {
        errorMessage = 'Cannot connect to server. Check the URL and your network.';
      } else if (e.toString().contains('404')) {
        errorMessage = 'Server not found. Check the URL.';
      }

      state = state.copyWith(isLoading: false, error: errorMessage);
    }
  }

  /// Clear error message.
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// Reset state to initial.
  void reset() {
    state = LoginState.initial();
  }
}
