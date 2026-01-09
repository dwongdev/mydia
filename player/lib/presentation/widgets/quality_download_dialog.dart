import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloads/download_job_providers.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/download_option.dart';

/// Dialog for selecting download quality before starting a progressive download.
///
/// Shows available quality options (1080p, 720p, 480p) with estimated file sizes.
/// Fetches options from the server and handles loading/error states.
class QualityDownloadDialog extends ConsumerStatefulWidget {
  final String contentType;
  final String contentId;
  final String title;

  const QualityDownloadDialog({
    super.key,
    required this.contentType,
    required this.contentId,
    required this.title,
  });

  @override
  ConsumerState<QualityDownloadDialog> createState() =>
      _QualityDownloadDialogState();
}

class _QualityDownloadDialogState extends ConsumerState<QualityDownloadDialog> {
  String? _selectedResolution;
  bool _isStartingDownload = false;

  @override
  Widget build(BuildContext context) {
    final optionsAsync = ref.watch(
      downloadOptionsProvider(widget.contentType, widget.contentId),
    );

    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Download Quality',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: optionsAsync.when(
          data: (response) => _buildOptionsContent(context, response),
          loading: () => _buildLoadingContent(),
          error: (error, stack) => _buildErrorContent(context, error),
        ),
      ),
      actions: _buildActions(context, optionsAsync),
    );
  }

  Widget _buildOptionsContent(
      BuildContext context, DownloadOptionsResponse response) {
    if (response.options.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 48,
            color: AppColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            'No download options available',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    // Pre-select first option if none selected
    if (_selectedResolution == null && response.options.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _selectedResolution = response.options.first.resolution;
          });
        }
      });
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select Quality',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 12),
        ...response.options.map((option) => _buildQualityOption(option)),
      ],
    );
  }

  Widget _buildQualityOption(DownloadOption option) {
    final isSelected = _selectedResolution == option.resolution;

    return InkWell(
      onTap: _isStartingDownload
          ? null
          : () {
              setState(() {
                _selectedResolution = option.resolution;
              });
            },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.2)
              : AppColors.surfaceVariant,
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
              size: 24,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.label,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '~${option.formattedSize}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle,
                color: AppColors.primary,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingContent() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Loading quality options...'),
      ],
    );
  }

  Widget _buildErrorContent(BuildContext context, Object error) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.error_outline,
          size: 48,
          color: AppColors.error,
        ),
        const SizedBox(height: 12),
        Text(
          'Failed to load options',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          error.toString(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () {
            ref.invalidate(
              downloadOptionsProvider(widget.contentType, widget.contentId),
            );
          },
          child: const Text('Retry'),
        ),
      ],
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    AsyncValue<DownloadOptionsResponse> optionsAsync,
  ) {
    final hasOptions =
        optionsAsync.hasValue && optionsAsync.value!.options.isNotEmpty;
    final canDownload =
        hasOptions && _selectedResolution != null && !_isStartingDownload;

    return [
      TextButton(
        onPressed: _isStartingDownload
            ? null
            : () => Navigator.of(context).pop(null),
        child: Text(
          'Cancel',
          style: TextStyle(
            color: _isStartingDownload
                ? AppColors.textDisabled
                : AppColors.textSecondary,
          ),
        ),
      ),
      ElevatedButton(
        onPressed: canDownload ? _startDownload : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          disabledBackgroundColor: AppColors.surfaceVariant,
          disabledForegroundColor: AppColors.textDisabled,
        ),
        child: _isStartingDownload
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Text('Download'),
      ),
    ];
  }

  Future<void> _startDownload() async {
    if (_selectedResolution == null) return;

    setState(() {
      _isStartingDownload = true;
    });

    try {
      // Return the selected resolution - the caller will handle the download
      if (mounted) {
        Navigator.of(context).pop(_selectedResolution);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isStartingDownload = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start download: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

}

/// Shows the quality download dialog and returns the selected resolution.
///
/// Returns null if the dialog was cancelled.
Future<String?> showQualityDownloadDialog(
  BuildContext context, {
  required String contentType,
  required String contentId,
  required String title,
}) async {
  return showDialog<String>(
    context: context,
    builder: (context) => QualityDownloadDialog(
      contentType: contentType,
      contentId: contentId,
      title: title,
    ),
  );
}
