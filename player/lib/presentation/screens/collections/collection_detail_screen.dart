import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'collection_detail_controller.dart';
import '../../widgets/media_poster.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';

class CollectionDetailScreen extends ConsumerWidget {
  final String id;

  const CollectionDetailScreen({super.key, required this.id});

  void _handleItemTap(BuildContext context, String itemId, String type) {
    final normalizedType = type.toLowerCase();
    if (normalizedType == 'movie') {
      context.push('/movie/$itemId');
    } else if (normalizedType == 'tv_show' || normalizedType == 'show') {
      context.push('/show/$itemId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsData = ref.watch(collectionDetailControllerProvider(id));

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: AppBar(
              backgroundColor: AppColors.background.withValues(alpha: 0.8),
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/collections');
                  }
                },
              ),
              title: const Text(
                'Collection',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref
              .read(collectionDetailControllerProvider(id).notifier)
              .refresh();
        },
        child: itemsData.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _buildErrorView(context, error, ref),
          data: (items) {
            if (items.isEmpty) {
              return _buildEmptyState(context);
            }
            return _buildGridView(context, items);
          },
        ),
      ),
    );
  }

  Widget _buildErrorView(BuildContext context, Object error, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Failed to load collection',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () {
                ref
                    .read(collectionDetailControllerProvider(id).notifier)
                    .refresh();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try Again'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
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
                Icons.collections_bookmark_outlined,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Collection is empty',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Add items to this collection in Mydia',
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

  Widget _buildGridView(BuildContext context, List items) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final bottomPadding = isDesktop ? 32.0 : 100.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);

        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
              horizontalPadding, 100, horizontalPadding, bottomPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.58,
            crossAxisSpacing: cardSpacing,
            mainAxisSpacing: cardSpacing + 4,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MediaPoster(
              key: ValueKey(item.id),
              posterUrl: item.posterUrl,
              title: item.title,
              onTap: () => _handleItemTap(context, item.id, item.type),
            );
          },
        );
      },
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width > 1400) return 8;
    if (width > 1200) return 7;
    if (width > 1000) return 6;
    if (width > 800) return 5;
    if (width > 600) return 4;
    if (width > 400) return 3;
    return 2;
  }
}
