import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/home_data.dart';

part 'home_controller.g.dart';

const String homeScreenQuery = r'''
query HomeScreen($continueWatchingLimit: Int, $recentlyAddedLimit: Int, $upNextLimit: Int, $favoritesLimit: Int) {
  continueWatching(first: $continueWatchingLimit) {
    id
    type
    title
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    showTitle
    seasonNumber
    episodeNumber
  }

  recentlyAdded(first: $recentlyAddedLimit) {
    id
    type
    title
    year
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    addedAt
  }

  upNext(first: $upNextLimit) {
    progressState
    episode {
      id
      seasonNumber
      episodeNumber
      title
      airDate
      thumbnailUrl
      hasFile
    }
    show {
      id
      title
      artwork {
        posterUrl
        backdropUrl
        thumbnailUrl
      }
    }
  }

  favorites(first: $favoritesLimit) {
    id
    type
    title
    year
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    addedAt
  }
}
''';

@riverpod
class HomeController extends _$HomeController {
  @override
  Future<HomeData> build() async {
    return _fetchHomeData();
  }

  Future<HomeData> _fetchHomeData() async {
    // Use async provider to wait for client to be ready
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(homeScreenQuery),
        variables: const {
          'continueWatchingLimit': 10,
          'recentlyAddedLimit': 20,
          'upNextLimit': 10,
          'favoritesLimit': 10,
        },
        fetchPolicy: FetchPolicy.cacheAndNetwork,
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    if (result.data == null) {
      throw Exception('No data received from server');
    }

    return HomeData.fromJson(result.data!);
  }

  Future<void> refresh() async {
    final previousData = state.value;
    state = const AsyncValue.loading();

    final result = await AsyncValue.guard(() => _fetchHomeData());
    if (result.hasError && previousData != null) {
      // Keep showing stale data instead of replacing with error
      debugPrint(
          '[HomeController] Refresh failed, keeping previous data: ${result.error}');
      state = AsyncValue.data(previousData);
      return;
    }
    state = result;
  }
}
