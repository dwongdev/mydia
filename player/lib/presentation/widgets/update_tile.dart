import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_provider.dart';

/// A ListTile-based widget that shows update availability in the Settings screen.
class UpdateTile extends ConsumerWidget {
  const UpdateTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateProvider);
    final update = updateState.availableUpdate;

    if (update == null) return const SizedBox.shrink();

    return Column(
      children: [
        ListTile(
          leading: Icon(
            Icons.system_update,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text('Update available: v${update.version}'),
          subtitle: Text(update.releaseTitle),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (updateState.isApplying) ...[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: updateState.downloadProgress > 0
                            ? updateState.downloadProgress
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Downloading... ${(updateState.downloadProgress * 100).toInt()}%',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: () => _handleUpdateTap(context, ref),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Update Now'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _openReleaseNotes(update.releaseNotesUrl),
                  child: const Text('Release Notes'),
                ),
              ],
            ],
          ),
        ),
        if (updateState.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              updateState.error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _handleUpdateTap(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(updateProvider.notifier);

    if (notifier.canUpdateInPlace) {
      // Show confirmation dialog before applying
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Update Mydia'),
          content: Text(
            'Mydia will close and update to v${ref.read(updateProvider).availableUpdate?.version}. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                notifier.applyUpdate();
              },
              child: const Text('Update'),
            ),
          ],
        ),
      );
    } else {
      // macOS / fallback: just start the download+open flow
      notifier.applyUpdate();
    }
  }

  Future<void> _openReleaseNotes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
