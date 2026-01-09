import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/cache/poster_cache_manager.dart';
import 'movie_detail_controller.dart';
import '../../widgets/quality_selector.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_job_providers.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';

class MovieDetailScreen extends ConsumerWidget {
  final String id;

  const MovieDetailScreen({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movieAsync = ref.watch(movieDetailControllerProvider(id));

    return Scaffold(
      body: movieAsync.when(
        data: (movie) => _buildContent(context, ref, movie),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Failed to load movie',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => ref
                    .read(movieDetailControllerProvider(id).notifier)
                    .refresh(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, movie) {
    return CustomScrollView(
      slivers: [
        _buildAppBar(context, movie),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, ref, movie),
              const SizedBox(height: 24),
              _buildMetadata(context, movie),
              const SizedBox(height: 24),
              if (movie.overview != null) ...[
                _buildOverview(context, movie),
                const SizedBox(height: 24),
              ],
              _buildActions(context, ref, movie),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAppBar(BuildContext context, movie) {
    return SliverAppBar(
      expandedHeight: 400,
      pinned: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/');
          }
        },
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (movie.artwork.backdropUrl != null)
              CachedNetworkImage(
                imageUrl: movie.artwork.backdropUrl!,
                fit: BoxFit.cover,
                cacheManager: BackdropCacheManager(),
                placeholder: (context, url) => Container(
                  color: AppColors.background,
                ),
                errorWidget: (context, url, error) => Container(
                  color: AppColors.background,
                ),
              )
            else
              Container(color: AppColors.background),
            // Gradient overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.7),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.7, 1.0],
                ),
              ),
            ),
            // Poster overlay
            Positioned(
              left: 20,
              bottom: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildPoster(movie),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: MediaQuery.of(context).size.width - 180,
                        child: Text(
                          movie.title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withOpacity(0.8),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (movie.yearDisplay.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          movie.yearDisplay,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppColors.textPrimary,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black.withOpacity(0.8),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoster(movie) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 100,
        height: 150,
        child: movie.artwork.posterUrl != null
            ? CachedNetworkImage(
                imageUrl: movie.artwork.posterUrl!,
                fit: BoxFit.cover,
                cacheManager: PosterCacheManager(),
                placeholder: (context, url) => Container(
                  color: AppColors.surface,
                ),
                errorWidget: (context, url, error) => Container(
                  color: AppColors.surface,
                  child: const Icon(Icons.movie, color: Colors.grey),
                ),
              )
            : Container(
                color: AppColors.surface,
                child: const Icon(Icons.movie, color: Colors.grey),
              ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, movie) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: _buildPlayButton(context, ref, movie),
          ),
          if (isDownloadSupported) ...[
            const SizedBox(width: 12),
            _buildDownloadButton(context, ref, movie),
          ],
          const SizedBox(width: 12),
          _buildFavoriteButton(ref, movie),
        ],
      ),
    );
  }

  Widget _buildPlayButton(BuildContext context, WidgetRef ref, movie) {
    final hasFiles = movie.files.isNotEmpty;

    return ElevatedButton.icon(
      onPressed: hasFiles
          ? () async {
              final selectedFile = await showQualitySelector(
                context,
                movie.files,
              );
              if (selectedFile != null && context.mounted) {
                context.push(
                  '/player/movie/${movie.id}?fileId=${selectedFile.id}&title=${Uri.encodeComponent(movie.title)}',
                );
              }
            }
          : null,
      icon: const Icon(Icons.play_arrow),
      label: Text(hasFiles ? 'Play' : 'No Files Available'),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDownloadButton(BuildContext context, WidgetRef ref, movie) {
    final isDownloadedAsync = ref.watch(isMediaDownloadedProvider(movie.id));
    final isDownloaded = isDownloadedAsync.value ?? false;
    final hasFiles = movie.files.isNotEmpty;

    return IconButton(
      onPressed: hasFiles
          ? () async {
              if (isDownloaded) {
                // Already downloaded, show message
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Already downloaded'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              } else {
                // Show quality download dialog for progressive downloads
                final selectedResolution = await showQualityDownloadDialog(
                  context,
                  contentType: 'movie',
                  contentId: movie.id,
                  title: movie.title,
                );

                if (selectedResolution != null && context.mounted) {
                  final downloadService = ref.read(downloadJobServiceProvider);
                  final downloadManager = await ref.read(downloadManagerProvider.future);

                  if (downloadService != null) {
                    try {
                      // Start progressive download using the service
                      await downloadManager.startProgressiveDownload(
                        mediaId: movie.id,
                        title: movie.title,
                        contentType: 'movie',
                        resolution: selectedResolution,
                        mediaType: MediaType.movie,
                        posterUrl: movie.artwork.posterUrl,
                        overview: movie.overview,
                        runtime: movie.runtime,
                        genres: movie.genres,
                        rating: movie.rating,
                        backdropUrl: movie.artwork.backdropUrl,
                        year: movie.year,
                        contentRating: movie.contentRating,
                        getDownloadUrl: (jobId) async {
                          return await downloadService.getDownloadUrl(jobId);
                        },
                        prepareDownload: () async {
                          final status = await downloadService.prepareDownload(
                            contentType: 'movie',
                            id: movie.id,
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
                          final status =
                              await downloadService.getJobStatus(jobId);
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
                          const SnackBar(
                            content: Text('Download started'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
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
              }
            }
          : null,
      icon: Icon(
        isDownloaded ? Icons.download_done : Icons.download,
        color: isDownloaded ? AppColors.success : Colors.white,
        size: 32,
      ),
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surface,
        padding: const EdgeInsets.all(12),
      ),
    );
  }

  Widget _buildFavoriteButton(WidgetRef ref, movie) {
    return IconButton(
      onPressed: () => ref
          .read(movieDetailControllerProvider(id).notifier)
          .toggleFavorite(),
      icon: Icon(
        movie.isFavorite ? Icons.favorite : Icons.favorite_border,
        color: movie.isFavorite ? AppColors.error : Colors.white,
        size: 32,
      ),
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surface,
        padding: const EdgeInsets.all(12),
      ),
    );
  }

  Widget _buildMetadata(BuildContext context, movie) {
    final items = <Widget>[];

    if (movie.runtimeDisplay.isNotEmpty) {
      items.add(_buildMetadataChip(context, movie.runtimeDisplay));
    }

    if (movie.ratingDisplay.isNotEmpty) {
      items.add(_buildMetadataChip(
        context,
        '⭐ ${movie.ratingDisplay}',
      ));
    }

    if (movie.contentRating != null) {
      items.add(_buildMetadataChip(context, movie.contentRating!));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items,
      ),
    );
  }

  Widget _buildMetadataChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context, movie) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Overview',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            movie.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textPrimary,
                  height: 1.5,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, WidgetRef ref, movie) {
    if (movie.genres.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Genres',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: movie.genres
                .map<Widget>((genre) => _buildGenreChip(context, genre))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildGenreChip(BuildContext context, String genre) {
    return Chip(
      label: Text(genre),
      backgroundColor: AppColors.surface,
      labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.white,
          ),
    );
  }
}
