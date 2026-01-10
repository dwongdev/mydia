import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_queue_providers.dart';
import '../../../core/downloads/storage_quota_providers.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/download_settings.dart';
import '../../../domain/models/storage_settings.dart';
import '../../../core/theme/colors.dart';
import 'series_downloads_screen.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageQuotaAsync = ref.watch(storageQuotaStatusProvider);
    final downloadedMediaAsync = ref.watch(downloadedMediaProvider);
    final downloadQueueAsync = ref.watch(downloadQueueProvider);
    final failedDownloadsAsync = ref.watch(failedDownloadsProvider);

    // Grouping Logic
    final items = <String, DownloadGroup>{};

    // Helper to safely get show ID/Title
    String getGroupKey(bool isEpisode, String? showId, String mediaId) {
      if (isEpisode && showId != null) return showId;
      return mediaId;
    }

    // Process Active Downloads
    if (downloadQueueAsync.hasValue) {
      for (final task in downloadQueueAsync.value!) {
        final isEpisode = task.mediaType == 'episode';
        final key = getGroupKey(isEpisode, task.showId, task.mediaId);
        
        if (!items.containsKey(key)) {
          items[key] = DownloadGroup(
            id: key,
            title: isEpisode ? (task.showTitle ?? 'Unknown Series') : task.title,
            posterUrl: isEpisode ? task.showPosterUrl : task.posterUrl,
            backdropUrl: task.backdropUrl,
            type: isEpisode ? GroupType.series : GroupType.movie,
            updatedAt: task.createdAt,
          );
        }
        items[key]!.activeTasks.add(task);
        if (task.createdAt.isAfter(items[key]!.updatedAt)) {
            items[key]!.updatedAt = task.createdAt;
        }
      }
    }

    // Process Completed Downloads
    if (downloadedMediaAsync.hasValue) {
      for (final media in downloadedMediaAsync.value!) {
        final isEpisode = media.mediaType == 'episode';
        final key = getGroupKey(isEpisode, media.showId, media.mediaId);

        if (!items.containsKey(key)) {
           items[key] = DownloadGroup(
            id: key,
            title: isEpisode ? (media.showTitle ?? 'Unknown Series') : media.title,
            posterUrl: isEpisode ? media.showPosterUrl : media.posterUrl,
            backdropUrl: media.backdropUrl,
            type: isEpisode ? GroupType.series : GroupType.movie,
            updatedAt: media.downloadedAt,
          );
        }
        items[key]!.downloads.add(media);
        if (media.downloadedAt.isAfter(items[key]!.updatedAt)) {
            items[key]!.updatedAt = media.downloadedAt;
        }
      }
    }
    
    final sortedItems = items.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context),
      body: CustomScrollView(
        slivers: [
          // Top padding for app bar
          const SliverToBoxAdapter(
            child: SizedBox(height: 100),
          ),

          // Storage usage section
          SliverToBoxAdapter(
            child: storageQuotaAsync.when(
              data: (status) => _buildStorageHeader(context, ref, status),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),

          // Failed downloads section (keep as list for visibility)
          SliverToBoxAdapter(
            child: failedDownloadsAsync.when(
              data: (failed) {
                if (failed.isEmpty) return const SizedBox.shrink();
                return _buildFailedSection(context, ref, failed);
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),

          // Main Grid
          if (sortedItems.isEmpty && !downloadQueueAsync.isLoading && !downloadedMediaAsync.isLoading)
             SliverFillRemaining(
                child: _buildEmptyState(context),
             )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, // Adjust based on screen size ideally
                  childAspectRatio: 2 / 3,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return _buildGridItem(context, ref, sortedItems[index]);
                  },
                  childCount: sortedItems.length,
                ),
              ),
            ),
            
          // Bottom padding
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }

  Widget _buildFailedSection(BuildContext context, WidgetRef ref, List<DownloadTask> failed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.error),
              const SizedBox(width: 8),
              Text(
                'Failed Downloads (${failed.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.error,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: failed.length,
            itemBuilder: (context, index) {
               return Container(
                 width: 300,
                 margin: const EdgeInsets.only(right: 12),
                 child: _buildFailedDownloadCard(context, ref, failed[index]),
               );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGridItem(BuildContext context, WidgetRef ref, DownloadGroup group) {
    // Determine active status
    final isActive = group.activeTasks.isNotEmpty;
    
    // Calculate progress (use the first active task for display)
    double progress = 0.0;
    if (isActive) {
        final task = group.activeTasks.first;
        progress = task.isProgressive ? task.combinedProgress : task.progress;
    }

    return GestureDetector(
      onTap: () async {
        if (group.type == GroupType.series) {
            // Open Series Screen (Folder-like navigation)
            Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (context) => SeriesDownloadsScreen(
                        showId: group.id,
                        showTitle: group.title,
                        showPosterUrl: group.posterUrl,
                        backdropUrl: group.backdropUrl,
                    ),
                ),
            );
        } else {
            // Movie
            if (isActive) {
                // Active Movie Download -> Cancel Confirm
                final task = group.activeTasks.first;
                _showCancelDialog(context, ref, task);
            } else if (group.downloads.isNotEmpty) {
                // Downloaded Movie -> Play directly
                final media = group.downloads.first;
                context.push(
                  '/player/movie/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}',
                );
            }
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Poster
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: group.posterUrl != null
                ? CachedNetworkImage(
                    imageUrl: group.posterUrl!,
                    fit: BoxFit.cover,
                    cacheManager: PosterCacheManager(),
                    placeholder: (_, __) => Container(color: AppColors.surfaceVariant),
                    errorWidget: (_, __, ___) => Container(
                        color: AppColors.surfaceVariant,
                        child: const Icon(Icons.movie, color: AppColors.textSecondary),
                    ),
                  )
                : Container(
                    color: AppColors.surfaceVariant,
                    child: const Icon(Icons.movie, color: AppColors.textSecondary),
                  ),
          ),
          
          // Gradient Overlay
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.7),
                ],
                stops: const [0.6, 1.0],
              ),
            ),
          ),

          // Active Overlay (Darken)
          if (isActive)
            Container(
                decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                ),
            ),
          
          // Progress Bar
          if (isActive)
             Center(
                 child: Stack(
                     alignment: Alignment.center,
                     children: [
                         SizedBox(
                             width: 48,
                             height: 48,
                             child: CircularProgressIndicator(
                                 value: progress,
                                 color: AppColors.primary,
                                 backgroundColor: Colors.white.withOpacity(0.2),
                                 strokeWidth: 4,
                             ),
                         ),
                         Text(
                             '${(progress * 100).toStringAsFixed(0)}%',
                             style: const TextStyle(
                                 color: Colors.white,
                                 fontSize: 12,
                                 fontWeight: FontWeight.bold,
                                 shadows: [Shadow(blurRadius: 2, color: Colors.black)],
                             ),
                         ),
                     ],
                 ),
             ),

          // Series Indicator (if not downloading)
          if (group.type == GroupType.series && !isActive)
             Positioned(
                 top: 8,
                 right: 8,
                 child: Container(
                     padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                     decoration: BoxDecoration(
                         color: Colors.black.withOpacity(0.7),
                         borderRadius: BorderRadius.circular(4),
                     ),
                     child: Text(
                         '${group.downloads.length + group.activeTasks.length}',
                         style: const TextStyle(
                             color: Colors.white,
                             fontSize: 10,
                             fontWeight: FontWeight.bold,
                         ),
                     ),
                 ),
             ),
             
          // Title (Bottom)
          Positioned(
             left: 8,
             right: 8,
             bottom: 8,
             child: Text(
                 group.title,
                 maxLines: 2,
                 overflow: TextOverflow.ellipsis,
                 textAlign: TextAlign.center,
                 style: const TextStyle(
                     color: Colors.white,
                     fontSize: 12,
                     fontWeight: FontWeight.w600,
                     shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                 ),
             ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCancelDialog(BuildContext context, WidgetRef ref, DownloadTask task) async {
      final manager = await ref.read(downloadManagerProvider.future);
      
      if (!context.mounted) return;
      
      showDialog(
          context: context,
          builder: (context) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: const Text('Cancel Download?'),
              content: Text('Stop downloading "${task.title}"?'),
              actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Keep', style: TextStyle(color: AppColors.textSecondary)),
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

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            color: AppColors.background.withValues(alpha: 0.85),
            child: SafeArea(
              child: SizedBox(
                height: kToolbarHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.download_rounded,
                        color: AppColors.primary,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Downloads',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.3,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStorageHeader(BuildContext context, WidgetRef ref, StorageQuotaStatus status) {
    // Determine colors based on status
    final isWarning = status.isWarningExceeded;
    final isFull = status.isFull;
    final iconColor = isFull ? AppColors.error : (isWarning ? AppColors.warning : AppColors.primary);
    final progressColor = isFull ? AppColors.error : (isWarning ? AppColors.warning : AppColors.primary);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surface,
            AppColors.surfaceVariant.withValues(alpha: 0.5),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isWarning ? iconColor.withValues(alpha: 0.5) : AppColors.divider.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isFull ? Icons.storage_rounded : (isWarning ? Icons.warning_amber_rounded : Icons.storage_rounded),
                  color: iconColor,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Storage Used',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status.settings.hasLimit
                          ? '${status.usedDisplay} / ${status.maxDisplay}'
                          : status.usedDisplay,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              ),
              // Settings button
              Material(
                color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showStorageSettings(context, ref, status),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.settings_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // Progress bar if limit is set
          if (status.settings.hasLimit) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: status.usagePercentage,
                minHeight: 8,
                backgroundColor: AppColors.surfaceVariant,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showStorageSettings(BuildContext context, WidgetRef ref, StorageQuotaStatus status) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _StorageSettingsSheet(
        currentSettings: status.settings,
        currentUsage: status.usedBytes,
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_download_rounded,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No downloads yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Download movies and shows to watch offline',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a card for a failed download with error details and retry/dismiss actions.
  /// (Copied from original but simplified for horizontal list)
  Widget _buildFailedDownloadCard(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Row(
                children: [
                    const Icon(Icons.error, color: AppColors.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                    ),
                ],
            ),
            const SizedBox(height: 8),
            Text(
                'Failed',
                style: TextStyle(color: AppColors.error, fontSize: 12),
            ),
            const Spacer(),
            Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                    TextButton(
                        onPressed: () async {
                            final manager = await ref.read(downloadManagerProvider.future);
                            await manager.cancelDownload(task.id);
                        },
                        child: const Text('Dismiss', style: TextStyle(fontSize: 12)),
                    ),
                    FilledButton(
                        onPressed: () async {
                            final manager = await ref.read(downloadManagerProvider.future);
                            await manager.retryDownload(task.id);
                        },
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                            backgroundColor: AppColors.primary,
                            minimumSize: const Size(0, 32),
                        ),
                        child: const Text('Retry', style: TextStyle(fontSize: 12)),
                    ),
                ],
            ),
        ],
      ),
    );
  }
}

/// Storage settings bottom sheet.
class _StorageSettingsSheet extends ConsumerStatefulWidget {
  final StorageSettings currentSettings;
  final int currentUsage;

  const _StorageSettingsSheet({
    required this.currentSettings,
    required this.currentUsage,
  });

  @override
  ConsumerState<_StorageSettingsSheet> createState() => _StorageSettingsSheetState();
}

class _StorageSettingsSheetState extends ConsumerState<_StorageSettingsSheet> {
  late int? _selectedLimit;
  late double _warningThreshold;
  late bool _autoCleanupEnabled;
  late CleanupPolicy _cleanupPolicy;
  late int _maxConcurrentDownloads;
  late bool _autoStartQueued;

  static const List<int?> _limitOptions = [
    null, // No limit
    StorageSettings.gb1,
    StorageSettings.gb2,
    StorageSettings.gb5,
    StorageSettings.gb10,
    StorageSettings.gb20,
  ];

  static const List<int> _concurrentOptions = [1, 2, 3, 4, 5];

  @override
  void initState() {
    super.initState();
    _selectedLimit = widget.currentSettings.maxStorageBytes;
    _warningThreshold = widget.currentSettings.warningThreshold;
    _autoCleanupEnabled = widget.currentSettings.autoCleanupEnabled;
    _cleanupPolicy = widget.currentSettings.cleanupPolicy;
    _maxConcurrentDownloads = 2; // Default, will be loaded async
    _autoStartQueued = true;
    _loadDownloadSettings();
  }

  Future<void> _loadDownloadSettings() async {
    final downloadSettings = await ref.read(downloadSettingsProvider.future);
    if (mounted) {
      setState(() {
        _maxConcurrentDownloads = downloadSettings.maxConcurrentDownloads;
        _autoStartQueued = downloadSettings.autoStartQueued;
      });
    }
  }

  String _formatLimit(int? limit) {
    if (limit == null) return 'No limit';
    return StorageSettings.formatBytes(limit);
  }

  Future<void> _saveSettings() async {
    // Save storage settings
    final updateStorageSettings = ref.read(updateStorageSettingsProvider);
    final newStorageSettings = StorageSettings(
      maxStorageBytes: _selectedLimit,
      warningThreshold: _warningThreshold,
      autoCleanupEnabled: _autoCleanupEnabled,
      cleanupPolicyValue: _cleanupPolicy.name,
    );
    await updateStorageSettings(newStorageSettings);

    // Save download settings
    final updateDownloadSettings = ref.read(updateDownloadSettingsProvider);
    final newDownloadSettings = DownloadSettings(
      maxConcurrentDownloads: _maxConcurrentDownloads,
      autoStartQueued: _autoStartQueued,
    );
    await updateDownloadSettings(newDownloadSettings);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _cleanupNow() async {
    final cleanupService = await ref.read(storageCleanupServiceProvider.future);
    final totalCleanable = cleanupService.getTotalCleanableBytes();

    if (totalCleanable == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No downloads to clean up')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clean Up Downloads'),
        content: Text(
          'This will delete all downloaded media (${StorageSettings.formatBytes(totalCleanable)}). '
          'Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final freedBytes = await cleanupService.cleanup(
        targetBytes: totalCleanable,
        policy: _cleanupPolicy,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Freed ${StorageSettings.formatBytes(freedBytes)}')),
        );
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.settings_rounded, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                'Storage Settings',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Storage limit dropdown
          Text(
            'Maximum Storage',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                isExpanded: true,
                value: _limitOptions.contains(_selectedLimit) ? _selectedLimit : null,
                items: _limitOptions.map((limit) {
                  final isCurrentlyUsed = limit != null && widget.currentUsage > limit;
                  return DropdownMenuItem(
                    value: limit,
                    child: Row(
                      children: [
                        Text(_formatLimit(limit)),
                        if (isCurrentlyUsed) ...[
                          const SizedBox(width: 8),
                          Text(
                            '(Full)',
                            style: TextStyle(
                              color: AppColors.error,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) => setState(() => _selectedLimit = value),
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Concurrent downloads
          Text(
            'Concurrent Downloads',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isExpanded: true,
                value: _maxConcurrentDownloads,
                items: _concurrentOptions.map((count) {
                  return DropdownMenuItem(
                    value: count,
                    child: Text('$count'),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _maxConcurrentDownloads = value);
                  }
                },
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Auto start switch
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Auto Start Downloads',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              Switch(
                value: _autoStartQueued,
                onChanged: (value) => setState(() => _autoStartQueued = value),
                activeColor: AppColors.primary,
              ),
            ],
          ),

          const SizedBox(height: 16),
          
          // Auto cleanup switch
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Auto Cleanup',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              Switch(
                value: _autoCleanupEnabled,
                onChanged: (value) => setState(() => _autoCleanupEnabled = value),
                activeColor: AppColors.primary,
              ),
            ],
          ),

          if (_autoCleanupEnabled) ...[
            const SizedBox(height: 16),
            Text(
              'Cleanup Policy',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<CleanupPolicy>(
                  isExpanded: true,
                  value: _cleanupPolicy,
                  items: CleanupPolicy.values.map((policy) {
                    return DropdownMenuItem(
                      value: policy,
                      child: Text(policy.display),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _cleanupPolicy = value);
                  },
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Actions
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cleanupNow,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(color: AppColors.error),
                    foregroundColor: AppColors.error,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Clean Up Now'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saveSettings,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Group Types
enum GroupType { movie, series }

// Helper class for grouping downloads
class DownloadGroup {
  final String id;
  final String title;
  final String? posterUrl;
  final String? backdropUrl;
  final GroupType type;
  DateTime updatedAt;
  final List<DownloadTask> activeTasks = [];
  final List<DownloadedMedia> downloads = [];

  DownloadGroup({
    required this.id,
    required this.title,
    this.posterUrl,
    this.backdropUrl,
    required this.type,
    required this.updatedAt,
  });
}
