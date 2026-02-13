import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/recently_added_item.dart';

part 'favorites_controller.g.dart';

const String favoritesQuery = r'''
query Favorites($first: Int) {
  favorites(first: $first) {
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
class FavoritesController extends _$FavoritesController {
  @override
  Future<List<RecentlyAddedItem>> build() async {
    return _fetchFavorites();
  }

  Future<List<RecentlyAddedItem>> _fetchFavorites() async {
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(favoritesQuery),
        variables: const {
          'first': 50,
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

    final items = (result.data!['favorites'] as List<dynamic>?)
            ?.map((e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return items;
  }

  Future<void> refresh() async {
    final previousData = state.value;
    state = const AsyncValue.loading();

    final result = await AsyncValue.guard(() => _fetchFavorites());
    if (result.hasError && previousData != null) {
      debugPrint(
          '[FavoritesController] Refresh failed, keeping previous data: ${result.error}');
      state = AsyncValue.data(previousData);
      return;
    }
    state = result;
  }
}
