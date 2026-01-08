import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/theme/colors.dart';

/// Banner displayed at the top of the screen when the app is in offline mode.
///
/// Shows a message indicating offline status and provides a "Retry Connection"
/// button to attempt reconnecting to the server.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  bool _isRetrying = false;

  Future<void> _retryConnection() async {
    setState(() => _isRetrying = true);

    try {
      await ref.read(authStateProvider.notifier).retryConnection();
    } finally {
      if (mounted) {
        setState(() => _isRetrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(
            color: AppColors.warning.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 18,
              color: AppColors.warning,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "You're offline - only downloads available",
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.warning,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _RetryButton(
              isLoading: _isRetrying,
              onPressed: _retryConnection,
            ),
          ],
        ),
      ),
    );
  }
}

/// Retry connection button with loading state.
class _RetryButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;

  const _RetryButton({
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: isLoading ? null : onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: AppColors.warning.withValues(alpha: 0.2),
        foregroundColor: AppColors.warning,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      child: isLoading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.warning,
              ),
            )
          : const Text(
              'Retry',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
