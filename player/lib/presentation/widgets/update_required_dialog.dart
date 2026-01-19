import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/protocol/protocol_version.dart';
import '../../core/theme/colors.dart';

/// Dialog shown when the client version is incompatible with the server.
///
/// This dialog is displayed when the server returns an `update_required` error
/// during connection handshake, indicating that the client needs to be updated
/// to support the server's protocol version.
///
/// The dialog displays:
/// - A clear message explaining the incompatibility
/// - Details about which protocol layers are incompatible
/// - An update button (if update URL is provided)
/// - A dismiss button
class UpdateRequiredDialog extends StatelessWidget {
  /// The error containing incompatibility details.
  final UpdateRequiredError error;

  const UpdateRequiredDialog({
    super.key,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.system_update, color: AppColors.warning),
          SizedBox(width: 12),
          Text('Update Required'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            error.message.isNotEmpty
                ? error.message
                : 'This app needs to be updated to connect to your server.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (error.incompatibleLayers.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Incompatible protocols:',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            _buildIncompatibleLayersList(context),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.info.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.info.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  color: AppColors.info,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Please update to the latest version of the app to continue using Mydia.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.info,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Dismiss'),
        ),
        if (error.updateUrl != null && error.updateUrl!.isNotEmpty)
          FilledButton.icon(
            onPressed: () => _openUpdateUrl(context),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Update Now'),
          ),
      ],
    );
  }

  Widget _buildIncompatibleLayersList(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.border,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: error.incompatibleLayers.map((layer) {
          final layerName = _formatLayerName(layer['layer'] as String? ?? '');
          final serverVersion = layer['server_version'] as String? ?? 'unknown';
          final clientVersion = layer['client_version'] as String? ?? 'unknown';

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.warning,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        layerName,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      Text(
                        'Server: $serverVersion • App: $clientVersion',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  String _formatLayerName(String layer) {
    // Convert snake_case to Title Case
    return layer
        .replaceAll('_', ' ')
        .split(' ')
        .map((word) => word.isNotEmpty
            ? '${word[0].toUpperCase()}${word.substring(1)}'
            : '')
        .join(' ');
  }

  Future<void> _openUpdateUrl(BuildContext context) async {
    if (error.updateUrl == null || error.updateUrl!.isEmpty) return;

    final uri = Uri.tryParse(error.updateUrl!);
    if (uri == null) return;

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open: ${error.updateUrl}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening update URL: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
}

/// Shows the update required dialog and waits for user dismissal.
///
/// Returns when the user closes the dialog.
Future<void> showUpdateRequiredDialog(
  BuildContext context,
  UpdateRequiredError error,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => UpdateRequiredDialog(error: error),
  );
}
