import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/show_detail.dart';

part 'show_detail_controller.g.dart';

const String tvShowDetailQuery = r'''
query TvShowDetail($id: ID!) {
  tvShow(id: $id) {
    id
    title
    originalTitle
    year
    overview
    status
    genres
    contentRating
    rating
    tmdbId
    imdbId
    category
    monitored
    addedAt
    seasonCount
    episodeCount
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    seasons {
      seasonNumber
      episodeCount
      airedEpisodeCount
      hasFiles
    }
    nextEpisode {
      id
      seasonNumber
      episodeNumber
      title
      airDate
    }
    isFavorite
  }
}
''';

const String toggleShowFavoriteMutation = r'''
mutation ToggleShowFavorite($id: ID!) {
  toggleShowFavorite(showId: $id) {
    id
    isFavorite
  }
}
''';

@riverpod
class ShowDetailController extends _$ShowDetailController {
  @override
  Future<ShowDetail> build(String id) async {
    return _fetchShow(id);
  }

  Future<ShowDetail> _fetchShow(String id) async {
    // Use async provider to wait for client to be ready
    final client = await ref.watch(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(tvShowDetailQuery),
        variables: {'id': id},
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    if (result.data == null || result.data!['tvShow'] == null) {
      throw Exception('TV show not found');
    }

    return ShowDetail.fromJson(result.data!['tvShow'] as Map<String, dynamic>);
  }

  Future<void> toggleFavorite() async {
    final currentState = state.value;
    if (currentState == null) return;

    final client = ref.read(graphqlClientProvider);
    if (client == null) return;

    // Optimistically update UI
    state = AsyncValue.data(
      ShowDetail(
        id: currentState.id,
        title: currentState.title,
        originalTitle: currentState.originalTitle,
        year: currentState.year,
        overview: currentState.overview,
        status: currentState.status,
        genres: currentState.genres,
        contentRating: currentState.contentRating,
        rating: currentState.rating,
        tmdbId: currentState.tmdbId,
        imdbId: currentState.imdbId,
        category: currentState.category,
        monitored: currentState.monitored,
        addedAt: currentState.addedAt,
        seasonCount: currentState.seasonCount,
        episodeCount: currentState.episodeCount,
        artwork: currentState.artwork,
        seasons: currentState.seasons,
        nextEpisode: currentState.nextEpisode,
        isFavorite: !currentState.isFavorite,
      ),
    );

    try {
      final result = await client.mutate(
        MutationOptions(
          document: gql(toggleShowFavoriteMutation),
          variables: {'id': currentState.id},
        ),
      );

      if (result.hasException) {
        // Revert on error
        state = AsyncValue.data(currentState);
        throw result.exception!;
      }
    } catch (e) {
      // Revert on error
      state = AsyncValue.data(currentState);
      rethrow;
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _fetchShow(id));
  }
}

// Provider for selected season state
@riverpod
class SelectedSeason extends _$SelectedSeason {
  @override
  int build(String showId) {
    // Default to season 1
    return 1;
  }

  void select(int seasonNumber) {
    state = seasonNumber;
  }
}
