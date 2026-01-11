import 'package:flutter/foundation.dart' show debugPrint;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/channels/pairing_service.dart';
import '../../../core/auth/device_info_service.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/connection/connection_provider.dart';
import '../../../core/protocol/protocol_version.dart';
import '../../../core/relay/relay_service.dart';

// Re-export QrPairingData so UI can import from one place
export '../../../core/channels/pairing_service.dart' show QrPairingData;
// Re-export UpdateRequiredError so UI can import from one place
export '../../../core/protocol/protocol_version.dart' show UpdateRequiredError;

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
    this.updateRequiredError,
  });

  final ConnectionMode mode;
  final bool isLoading;
  final String? error;
  final bool success;
  final ClaimCodeStatus claimCodeStatus;
  final String? claimCodeMessage;

  /// Set when an update_required error is received from the server.
  /// The UI should show an UpdateRequiredDialog when this is not null.
  final UpdateRequiredError? updateRequiredError;

  LoginState copyWith({
    ConnectionMode? mode,
    bool? isLoading,
    String? error,
    bool? success,
    ClaimCodeStatus? claimCodeStatus,
    String? claimCodeMessage,
    UpdateRequiredError? updateRequiredError,
    bool clearUpdateRequiredError = false,
  }) {
    return LoginState(
      mode: mode ?? this.mode,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      success: success ?? this.success,
      claimCodeStatus: claimCodeStatus ?? this.claimCodeStatus,
      claimCodeMessage: claimCodeMessage,
      updateRequiredError:
          clearUpdateRequiredError ? null : (updateRequiredError ?? this.updateRequiredError),
    );
  }

  factory LoginState.initial() => const LoginState(mode: ConnectionMode.claimCode);
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
  ///
  /// If [relayUrl] is provided, uses that instead of the default relay.
  Future<void> pairWithClaimCode(String claimCode, {String? relayUrl}) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Looking up claim code...',
    );

    try {
      // Create relay service with custom URL if provided
      final relayService = relayUrl != null && relayUrl.isNotEmpty
          ? RelayService(relayUrl: relayUrl)
          : null;
      final pairingService = PairingService(
        relayService: relayService,
        relayUrl: relayUrl,
      );
      final deviceInfo = DeviceInfoService();
      final deviceName = await deviceInfo.getDeviceName();

      final result = await pairingService.pairWithClaimCodeOnly(
        claimCode: claimCode,
        deviceName: deviceName,
        onStatusUpdate: (status) {
          // Check if still mounted before updating state
          if (!ref.mounted) return;

          // Map status messages to claim code statuses
          ClaimCodeStatus claimStatus;
          if (status.contains('Looking up')) {
            claimStatus = ClaimCodeStatus.lookingUp;
          } else if (status.contains('Connecting') ||
                     status.contains('Joining') ||
                     status.contains('relay')) {
            claimStatus = ClaimCodeStatus.connecting;
          } else if (status.contains('Establishing') ||
                     status.contains('Submitting') ||
                     status.contains('secure')) {
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

      // Check if still mounted before updating state
      if (!ref.mounted) {
        debugPrint('[LoginController] Not mounted after pairing, returning early');
        return;
      }

      // Pairing successful - store credentials in auth service
      debugPrint('[LoginController] Pairing successful! Storing credentials...');
      debugPrint('[LoginController] isRelayMode=${result.isRelayMode}');
      final credentials = result.credentials!;
      final authService = ref.read(authServiceProvider);

      // Store access token for GraphQL/API authentication (typ: access)
      // Media token is already stored by PairingService for streaming
      await authService.setSession(
        token: credentials.accessToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId, // Use device ID as user ID for now
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );
      debugPrint('[LoginController] Credentials stored');

      // If relay mode, set the tunnel in the connection provider
      if (result.isRelayMode && result.webrtcManager != null) {
        debugPrint('[LoginController] Setting relay tunnel in connection provider');
        await ref.read(connectionProvider.notifier).setWebRTCManager(
          result.webrtcManager!,
          instanceId: credentials.instanceId,
          relayUrl: relayUrl,
        );
        debugPrint('[LoginController] Relay tunnel set');
        // Invalidate GraphQL providers to force rebuild with relay mode
        ref.invalidate(graphqlClientProvider);
        ref.invalidate(asyncGraphqlClientProvider);
        debugPrint('[LoginController] GraphQL providers invalidated');
      } else {
        debugPrint('[LoginController] Direct mode, ensuring connection provider is in direct mode');
        await ref.read(connectionProvider.notifier).setDirectMode();
      }

      debugPrint('[LoginController] Refreshing auth state...');

      if (!ref.mounted) {
        debugPrint('[LoginController] Not mounted after setSession, returning early');
        return;
      }

      // Refresh auth state
      debugPrint('[LoginController] Calling authStateProvider.notifier.refresh()...');
      await ref.read(authStateProvider.notifier).refresh();
      debugPrint('[LoginController] Auth state refreshed!');

      if (!ref.mounted) {
        debugPrint('[LoginController] Not mounted after refresh, returning early');
        return;
      }
      debugPrint('[LoginController] Setting success state...');
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
        success: true,
      );
      debugPrint('[LoginController] Success state set!');
    } on UpdateRequiredError catch (e) {
      if (!ref.mounted) return;
      debugPrint('[LoginController] UpdateRequiredError: ${e.message}');
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.message,
        updateRequiredError: e,
      );
    } catch (e) {
      if (!ref.mounted) return;
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

      // Check if still mounted before updating state
      if (!ref.mounted) return;

      // Update the auth state provider to trigger UI updates
      await ref.read(authStateProvider.notifier).refresh();

      if (!ref.mounted) return;
      state = state.copyWith(isLoading: false, success: true);
    } catch (e) {
      // Check if still mounted before updating state
      if (!ref.mounted) return;

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

  /// Attempt to pair using QR code data.
  ///
  /// Uses the PairingService to pair using data scanned from a QR code.
  /// The QR code contains the relay URL, instance ID, public key, and claim code.
  Future<void> pairWithQrCode(QrPairingData qrData) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Validating QR code...',
    );

    try {
      final pairingService = PairingService(
        relayUrl: qrData.relayUrl,
      );
      final deviceInfo = DeviceInfoService();
      final deviceName = await deviceInfo.getDeviceName();

      final result = await pairingService.pairWithQrData(
        qrData: qrData,
        deviceName: deviceName,
        onStatusUpdate: (status) {
          // Check if still mounted before updating state
          if (!ref.mounted) return;

          ClaimCodeStatus claimStatus;
          if (status.contains('Validating')) {
            claimStatus = ClaimCodeStatus.lookingUp;
          } else if (status.contains('Connecting') ||
                     status.contains('Joining') ||
                     status.contains('relay')) {
            claimStatus = ClaimCodeStatus.connecting;
          } else if (status.contains('Establishing') ||
                     status.contains('Submitting') ||
                     status.contains('secure')) {
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

      // Check if still mounted before updating state
      if (!ref.mounted) return;

      // Pairing successful - store credentials in auth service
      debugPrint('[LoginController] QR pairing successful! isRelayMode=${result.isRelayMode}');
      final credentials = result.credentials!;
      final authService = ref.read(authServiceProvider);

      // Store access token for GraphQL/API authentication (typ: access)
      // Media token is already stored by PairingService for streaming
      await authService.setSession(
        token: credentials.accessToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId,
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );

      // If relay mode, set the tunnel in the connection provider
      if (result.isRelayMode && result.webrtcManager != null) {
        debugPrint('[LoginController] Setting relay tunnel from QR pairing');
        await ref.read(connectionProvider.notifier).setWebRTCManager(
          result.webrtcManager!,
          instanceId: credentials.instanceId,
          relayUrl: qrData.relayUrl,
        );
        // Invalidate GraphQL providers to force rebuild with relay mode
        ref.invalidate(graphqlClientProvider);
        ref.invalidate(asyncGraphqlClientProvider);
        debugPrint('[LoginController] GraphQL providers invalidated');
      } else {
        await ref.read(connectionProvider.notifier).setDirectMode();
      }

      if (!ref.mounted) return;

      // Refresh auth state
      await ref.read(authStateProvider.notifier).refresh();

      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
        success: true,
      );
    } on UpdateRequiredError catch (e) {
      if (!ref.mounted) return;
      debugPrint('[LoginController] UpdateRequiredError (QR): ${e.message}');
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.message,
        updateRequiredError: e,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// Clear error message.
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// Clear update required error.
  void clearUpdateRequiredError() {
    state = state.copyWith(clearUpdateRequiredError: true);
  }

  /// Reset state to initial.
  void reset() {
    state = LoginState.initial();
  }
}
