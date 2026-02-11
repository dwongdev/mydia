import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';

class SeriesDownloadsScreen extends ConsumerWidget {
  final String showId;
  final String showTitle;
  final String? showPosterUrl;
  final String? backdropUrl;

  const SeriesDownloadsScreen({
    super.key,
    required this.showId,
    required this.showTitle,
    this.showPosterUrl,
    this.backdropUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadedMediaAsync = ref.watch(downloadedMediaProvider);
    final downloadQueueAsync = ref.watch(downloadQueueProvider);

    // Combine data
    final downloaded = downloadedMediaAsync.value ?? [];
    final queue = downloadQueueAsync.value ?? [];

    // Filter for this show
    final showDownloads = downloaded.where((m) => m.showId == showId).toList();
    final showQueue = queue.where((t) => t.showId == showId).toList();

    // Sort by Season/Episode
    showDownloads.sort((a, b) {
      final sA = a.seasonNumber ?? 0;
      final sB = b.seasonNumber ?? 0;
      if (sA != sB) return sA.compareTo(sB);
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });

    showQueue.sort((a, b) {
      final sA = a.seasonNumber ?? 0;
      final sB = b.seasonNumber ?? 0;
      if (sA != sB) return sA.compareTo(sB);
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (showQueue.isNotEmpty) ...[
                  Text(
                    'Downloading',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ...showQueue
                      .map((task) => _buildQueueItem(context, ref, task)),
                  const SizedBox(height: 24),
                ],
                if (showDownloads.isNotEmpty) ...[
                  Text(
                    'Downloaded',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.success,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ...showDownloads.map(
                      (media) => _buildDownloadedItem(context, ref, media)),
                ],
                if (showQueue.isEmpty && showDownloads.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text("No episodes found")),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      backgroundColor: AppColors.background,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          showTitle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(color: Colors.black, blurRadius: 4)],
          ),
        ),
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (backdropUrl != null)
              CachedNetworkImage(
                imageUrl: backdropUrl!,
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(color: AppColors.surface),
                errorWidget: (context, url, error) =>
                    Container(color: AppColors.surface),
              )
            else
              Container(color: AppColors.surface),

            // Gradient
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.3),
                    AppColors.background,
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueItem(
      BuildContext context, WidgetRef ref, DownloadTask task) {
    final progress = task.isProgressive ? task.combinedProgress : task.progress;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'S${task.seasonNumber?.toString().padLeft(2, '0')}E${task.episodeNumber?.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (task.title.isNotEmpty)
                      Text(
                        task.title,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () async {
                  _showCancelDialog(context, ref, task);
                },
                icon: const Icon(Icons.close_rounded),
                color: AppColors.textSecondary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            backgroundColor: AppColors.surfaceVariant,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                task.statusDisplay,
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (task.downloadStatus == DownloadStatus.downloading ||
              task.downloadStatus == DownloadStatus.transcoding) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  task.progressBytesDisplay ?? task.fileSizeDisplay,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
                Consumer(
                  builder: (context, ref, _) {
                    final speedAsync = ref.watch(downloadSpeedInfoProvider);
                    return speedAsync.when(
                      data: (speedMap) {
                        final info = speedMap[task.id];
                        if (info == null || info.bytesPerSecond <= 0) {
                          return const SizedBox.shrink();
                        }
                        final parts = <String>[];
                        parts.add(info.speedDisplay);
                        if (info.etaDisplay.isNotEmpty) {
                          parts.add(info.etaDisplay);
                        }
                        return Text(
                          parts.join(' \u00B7 '),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        );
                      },
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                    );
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadedItem(
      BuildContext context, WidgetRef ref, DownloadedMedia media) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.play_arrow, color: AppColors.primary),
        ),
        title: Text(
          'S${media.seasonNumber?.toString().padLeft(2, '0')}E${media.episodeNumber?.toString().padLeft(2, '0')}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          media.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon:
              const Icon(Icons.delete_outline_rounded, color: AppColors.error),
          onPressed: () async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: AppColors.surface,
                title: const Text('Delete Episode'),
                content: Text(
                    'Delete S${media.seasonNumber}E${media.episodeNumber}?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.error),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );

            if (confirm == true) {
              final manager = await ref.read(downloadManagerProvider.future);
              await manager.deleteDownload(media.mediaId);
            }
          },
        ),
        onTap: () {
          context.push(
            '/player/episode/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}&showId=$showId&seasonNumber=${media.seasonNumber}',
          );
        },
      ),
    );
  }

  Future<void> _showCancelDialog(
      BuildContext context, WidgetRef ref, DownloadTask task) async {
    final manager = await ref.read(downloadManagerProvider.future);

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Cancel Download?'),
        content: Text('Stop downloading this episode?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () {
              manager.cancelDownload(task.id);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Cancel Download'),
          ),
        ],
      ),
    );
  }
}
