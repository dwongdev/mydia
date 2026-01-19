import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/download.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/downloads/download_providers.dart';
import '../../core/downloads/download_job_providers.dart';
import '../../core/theme/colors.dart';
import 'quality_download_dialog.dart';
import 'quality_badge.dart';

class EpisodeCard extends ConsumerStatefulWidget {
  final Episode episode;
  final String showTitle;
  final VoidCallback? onTap;

  const EpisodeCard({
    super.key,
    required this.episode,
    required this.showTitle,
    this.onTap,
  });

  @override
  ConsumerState<EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends ConsumerState<EpisodeCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isPressed = false;

  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleHoverEnter() {
    setState(() => _isHovered = true);
    _animationController.forward();
  }

  void _handleHoverExit() {
    setState(() => _isHovered = false);
    _animationController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDownloadedAsync = ref.watch(isMediaDownloadedProvider(widget.episode.id));
    final isDownloaded = isDownloadedAsync.value ?? false;

    return MouseRegion(
      onEnter: (_) => _handleHoverEnter(),
      onExit: (_) => _handleHoverExit(),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap?.call();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Transform.scale(
              scale: _isPressed ? 0.98 : _scaleAnimation.value,
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: _isHovered ? AppColors.surfaceVariant : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isHovered
                    ? AppColors.primary.withValues(alpha: 0.3)
                    : Colors.transparent,
              ),
              boxShadow: _isHovered
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildThumbnail(),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildEpisodeHeader(context),
                            const SizedBox(height: 6),
                            Text(
                              widget.episode.title,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (widget.episode.overview != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                widget.episode.overview!,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppColors.textSecondary,
                                      height: 1.4,
                                    ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 10),
                            _buildMetadata(context),
                          ],
                        ),
                      ),
                    ),
                    _buildActionButtons(context, isDownloaded),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    return SizedBox(
      width: 160,
      child: Stack(
        children: [
          // Thumbnail image
          Positioned.fill(
            child: widget.episode.thumbnailUrl != null
                ? CachedNetworkImage(
                    imageUrl: widget.episode.thumbnailUrl!,
                    fit: BoxFit.cover,
                    cacheManager: EpisodeThumbnailCacheManager(),
                    placeholder: (context, url) => Container(
                      color: AppColors.surfaceVariant,
                    ),
                    errorWidget: (context, url, error) => _buildPlaceholder(),
                  )
                : _buildPlaceholder(),
          ),

          // Hover overlay with play button
          AnimatedOpacity(
            opacity: _isHovered && widget.episode.hasFile ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 28,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Progress bar at bottom
          if (widget.episode.progress != null &&
              widget.episode.progress!.percentage > 0)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceVariant,
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: widget.episode.progress!.percentage / 100,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(2),
                        bottomRight: Radius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Watched indicator
          if (widget.episode.progress?.watched == true)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check_rounded,
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.surfaceVariant,
      child: const Center(
        child: Icon(
          Icons.tv_rounded,
          size: 32,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildEpisodeHeader(BuildContext context) {
    final quality = getBestQuality(widget.episode.files);
    final badges = quality.toBadges();

    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.episode.episodeCode,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
        ),
        if (widget.episode.runtimeDisplay.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.access_time_rounded,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                widget.episode.runtimeDisplay,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
          ),
        if (badges.isNotEmpty) QualityBadgeRow(badges: badges, spacing: 4),
      ],
    );
  }

  Widget _buildMetadata(BuildContext context) {
    final items = <Widget>[];

    if (widget.episode.progress?.watched == true) {
      items.add(_buildStatusBadge(
        'Watched',
        AppColors.success,
        Icons.check_rounded,
      ));
    } else if (widget.episode.progress != null &&
        widget.episode.progress!.percentage > 0) {
      items.add(_buildStatusBadge(
        '${widget.episode.progress!.percentage.toInt()}%',
        AppColors.primary,
        Icons.play_arrow_rounded,
      ));
    }

    if (!widget.episode.hasFile) {
      items.add(_buildStatusBadge(
        'Unavailable',
        AppColors.textSecondary,
        Icons.cloud_off_rounded,
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: items,
    );
  }

  Widget _buildStatusBadge(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, bool isDownloaded) {
    if (!widget.episode.hasFile || !isDownloadSupported) {
      return const SizedBox(width: 16);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Download button
          _ActionButton(
            icon: isDownloaded
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            color: isDownloaded ? AppColors.success : AppColors.textSecondary,
            onTap: () => _handleDownload(context, isDownloaded),
            tooltip: isDownloaded ? 'Downloaded' : 'Download',
          ),
        ],
      ),
    );
  }

  Future<void> _handleDownload(BuildContext context, bool isDownloaded) async {
    if (isDownloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                SizedBox(width: 12),
                Text('Already downloaded'),
              ],
            ),
            backgroundColor: AppColors.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else if (widget.episode.files.isNotEmpty) {
      // Show quality download dialog for progressive downloads
      final selectedResolution = await showQualityDownloadDialog(
        context,
        contentType: 'episode',
        contentId: widget.episode.id,
        title: '${widget.showTitle} - ${widget.episode.episodeCode}',
      );

      if (selectedResolution != null && context.mounted) {
        final downloadService = ref.read(downloadJobServiceProvider);
        final downloadManager = await ref.read(downloadManagerProvider.future);

        if (downloadService != null) {
          try {
            // Start progressive download using the service
            await downloadManager.startProgressiveDownload(
              mediaId: widget.episode.id,
              title:
                  '${widget.showTitle} - ${widget.episode.episodeCode}: ${widget.episode.title}',
              contentType: 'episode',
              resolution: selectedResolution,
              mediaType: MediaType.episode,
              posterUrl: widget.episode.thumbnailUrl,
              overview: widget.episode.overview,
              runtime: widget.episode.runtime,
              seasonNumber: widget.episode.seasonNumber,
              episodeNumber: widget.episode.episodeNumber,
              showTitle: widget.showTitle,
              thumbnailUrl: widget.episode.thumbnailUrl,
              airDate: widget.episode.airDate,
              getDownloadUrl: (jobId) async {
                return await downloadService.getDownloadUrl(jobId);
              },
              prepareDownload: () async {
                final status = await downloadService.prepareDownload(
                  contentType: 'episode',
                  id: widget.episode.id,
                  resolution: selectedResolution,
                );
                return (
                  jobId: status.jobId,
                  status: status.status.name,
                  progress: status.progress,
                  fileSize: status.currentFileSize,
                );
              },
              getJobStatus: (jobId) async {
                final status = await downloadService.getJobStatus(jobId);
                return (
                  status: status.status.name,
                  progress: status.progress,
                  fileSize: status.currentFileSize,
                  error: status.error,
                );
              },
              cancelJob: (jobId) async {
                await downloadService.cancelJob(jobId);
              },
            );

            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Row(
                    children: [
                      Icon(Icons.download_rounded,
                          color: Colors.white, size: 20),
                      SizedBox(width: 12),
                      Text('Download started'),
                    ],
                  ),
                  backgroundColor: AppColors.primary,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to start download: $e'),
                  backgroundColor: AppColors.error,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            }
          }
        }
      }
    }
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _isHovered
                  ? widget.color.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              widget.icon,
              color: widget.color,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
