import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';

class DownloadedMediaDetailSheet extends ConsumerWidget {
  final DownloadedMedia media;

  const DownloadedMediaDetailSheet({
    super.key,
    required this.media,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Content
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.zero,
                children: [
                  _buildHeader(context, media),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildMetadata(context, media),
                        const SizedBox(height: 20),
                        if (media.overview != null) ...[
                          Text(
                            'Overview',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            media.overview!,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppColors.textSecondary,
                                  height: 1.5,
                                ),
                          ),
                          const SizedBox(height: 24),
                        ],
                        _buildActions(context, ref, media),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, DownloadedMedia media) {
    return SizedBox(
      height: 300,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop
          if (media.backdropUrl != null)
            CachedNetworkImage(
              imageUrl: media.backdropUrl!,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(color: AppColors.surface),
              errorWidget: (context, url, error) => Container(color: AppColors.surface),
            )
          else
            Container(color: AppColors.surface),
          
          // Gradient overlay
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppColors.background.withValues(alpha: 0.8),
                  AppColors.background,
                ],
                stops: const [0.0, 0.7, 1.0],
              ),
            ),
          ),

          // Content overlay
          Positioned(
            left: 20,
            bottom: 20,
            right: 20,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Poster
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 100,
                    height: 150,
                    child: media.posterUrl != null
                        ? CachedNetworkImage(
                            imageUrl: media.posterUrl!,
                            fit: BoxFit.cover,
                            cacheManager: PosterCacheManager(),
                            placeholder: (context, url) => Container(
                              color: AppColors.surfaceVariant,
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: AppColors.surfaceVariant,
                              child: const Icon(Icons.movie, color: AppColors.textSecondary),
                            ),
                          )
                        : Container(
                            color: AppColors.surfaceVariant,
                            child: const Icon(Icons.movie, color: AppColors.textSecondary),
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                // Title and basic info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (media.showTitle != null) ...[
                        Text(
                          media.showTitle!,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        media.title,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (media.seasonNumber != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'S${media.seasonNumber!.toString().padLeft(2, '0')}E${media.episodeNumber!.toString().padLeft(2, '0')}',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: AppColors.textSecondary,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadata(BuildContext context, DownloadedMedia media) {
    final items = <Widget>[];

    // Year or Air Date
    if (media.year != null) {
      items.add(_buildChip(context, '${media.year}'));
    } else if (media.airDate != null) {
      items.add(_buildChip(context, media.airDate!));
    }

    // Runtime
    if (media.runtime != null) {
      final minutes = media.runtime!;
      final duration = minutes < 60 
          ? '${minutes}m' 
          : '${minutes ~/ 60}h ${minutes % 60}m';
      items.add(_buildChip(context, duration, icon: Icons.schedule_rounded));
    }

    // Rating
    if (media.rating != null) {
      items.add(_buildChip(
        context, 
        media.rating!.toStringAsFixed(1), 
        icon: Icons.star_rounded,
        color: Colors.amber,
      ));
    }

    // Quality
    items.add(_buildChip(
      context, 
      media.quality, 
      color: AppColors.accent,
      backgroundColor: AppColors.accent.withValues(alpha: 0.15),
    ));

    // Content Rating
    if (media.contentRating != null) {
      items.add(_buildChip(context, media.contentRating!));
    }

    // Genres
    if (media.genres.isNotEmpty) {
      for (final genre in media.genres.take(3)) {
        items.add(_buildChip(context, genre));
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items,
    );
  }

  Widget _buildChip(
    BuildContext context, 
    String label, {
    IconData? icon,
    Color? color,
    Color? backgroundColor,
  }) {
    final effectiveColor = color ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: effectiveColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: effectiveColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, WidgetRef ref, DownloadedMedia media) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop(); // Close sheet
              if (media.type == MediaType.movie) {
                context.push(
                  '/player/movie/${media.mediaId}?offline=true&title=${Uri.encodeComponent(media.title)}',
                );
              } else {
                // Determine show/episode IDs if available, else use mediaId
                // The player route for episodes might need checking
                context.push(
                  '/player/episode/${media.mediaId}?offline=true&title=${Uri.encodeComponent(media.title)}',
                );
              }
            },
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
          ),
          child: IconButton(
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  title: const Text('Delete Download'),
                  content: Text('Are you sure you want to delete "${media.title}"?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.error),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                if (context.mounted) {
                  Navigator.of(context).pop(); // Close sheet
                }
                final manager = await ref.read(downloadManagerProvider.future);
                await manager.deleteDownload(media.mediaId);
              }
            },
            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
            style: IconButton.styleFrom(
              padding: const EdgeInsets.all(16),
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> showDownloadedMediaDetail(BuildContext context, DownloadedMedia media) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DownloadedMediaDetailSheet(media: media),
  );
}
