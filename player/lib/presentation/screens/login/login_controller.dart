import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/channels/pairing_service.dart';
import '../../../core/auth/device_info_service.dart';

part 'login_controller.g.dart';

/// Connection mode for the login flow.
enum ConnectionMode {
  /// Initial mode selection screen
  selection,
  /// Claim code pairing mode (E2E encrypted via relay)
  claimCode,
  /// Direct HTTPS connection mode
  direct,
}

/// Status for claim code pairing.
enum ClaimCodeStatus {
  /// Waiting for user to enter code
  idle,
  /// Looking up claim code on relay
  lookingUp,
  /// Connecting to instance via relay
  connecting,
  /// Performing Noise handshake
  handshaking,
  /// Pairing complete
  paired,
  /// Error occurred
  error,
}

/// State for the login screen.
class LoginState {
  const LoginState({
    this.mode = ConnectionMode.selection,
    this.isLoading = false,
    this.error,
    this.success = false,
    this.claimCodeStatus = ClaimCodeStatus.idle,
    this.claimCodeMessage,
  });

  final ConnectionMode mode;
  final bool isLoading;
  final String? error;
  final bool success;
  final ClaimCodeStatus claimCodeStatus;
  final String? claimCodeMessage;

  LoginState copyWith({
    ConnectionMode? mode,
    bool? isLoading,
    String? error,
    bool? success,
    ClaimCodeStatus? claimCodeStatus,
    String? claimCodeMessage,
  }) {
    return LoginState(
      mode: mode ?? this.mode,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      success: success ?? this.success,
      claimCodeStatus: claimCodeStatus ?? this.claimCodeStatus,
      claimCodeMessage: claimCodeMessage,
    );
  }

  factory LoginState.initial() => const LoginState();
}

@riverpod
class LoginController extends _$LoginController {
  @override
  LoginState build() => LoginState.initial();

  /// Switch to a different connection mode.
  void setMode(ConnectionMode mode) {
    state = state.copyWith(mode: mode, error: null);
  }

  /// Go back to mode selection.
  void goBackToSelection() {
    state = LoginState.initial();
  }

  /// Attempt to pair using a claim code.
  ///
  /// Uses the PairingService to:
  /// 1. Look up the claim code via the relay service
  /// 2. Get the instance's direct URLs and public key
  /// 3. Connect to the instance and submit the claim code
  /// 4. Store credentials and complete pairing
  Future<void> pairWithClaimCode(String claimCode) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Looking up claim code...',
    );

    try {
      final pairingService = PairingService();
      final deviceInfo = DeviceInfoService();
      final deviceName = await deviceInfo.getDeviceName();

      final result = await pairingService.pairWithClaimCodeOnly(
        claimCode: claimCode,
        deviceName: deviceName,
        onStatusUpdate: (status) {
          // Map status messages to claim code statuses
          ClaimCodeStatus claimStatus;
          if (status.contains('Looking up')) {
            claimStatus = ClaimCodeStatus.lookingUp;
          } else if (status.contains('Connecting') || status.contains('Joining')) {
            claimStatus = ClaimCodeStatus.connecting;
          } else if (status.contains('Establishing') || status.contains('Submitting')) {
            claimStatus = ClaimCodeStatus.handshaking;
          } else {
            claimStatus = ClaimCodeStatus.handshaking;
          }

          state = state.copyWith(
            claimCodeStatus: claimStatus,
            claimCodeMessage: status,
          );
        },
      );

      if (!result.success) {
        throw Exception(result.error ?? 'Pairing failed');
      }

      // Pairing successful - store credentials in auth service
      final credentials = result.credentials!;
      final authService = ref.read(authServiceProvider);

      await authService.setSession(
        token: credentials.mediaToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId, // Use device ID as user ID for now
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );

      // Refresh auth state
      await ref.read(authStateProvider.notifier).refresh();

      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
        success: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// Perform login with the given credentials using GraphQL.
  Future<void> login(
    String serverUrl,
    String username,
    String password,
  ) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final authService = ref.read(authServiceProvider);

      // Call the GraphQL login method from AuthService
      await authService.loginWithGraphQL(
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

      final errorStr = e.toString();
      if (errorStr.contains('Invalid username or password') ||
          errorStr.contains('Local authentication is disabled')) {
        errorMessage = errorStr.replaceFirst('Exception: Login failed: ', '')
            .replaceFirst('Exception: Login error: Exception: ', '');
      } else if (errorStr.contains('401') || errorStr.contains('invalid')) {
        errorMessage = 'Invalid username or password';
      } else if (errorStr.contains('connection') ||
                 errorStr.contains('network') ||
                 errorStr.contains('SocketException')) {
        errorMessage = 'Cannot connect to server. Check the URL and your network.';
      } else if (errorStr.contains('404')) {
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
