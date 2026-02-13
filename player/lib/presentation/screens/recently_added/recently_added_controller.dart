import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/recently_added_item.dart';

part 'recently_added_controller.g.dart';

const String recentlyAddedFullQuery = r'''
query RecentlyAddedFull($first: Int) {
  recentlyAdded(first: $first) {
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
class RecentlyAddedController extends _$RecentlyAddedController {
  @override
  Future<List<RecentlyAddedItem>> build() async {
    return _fetchRecentlyAdded();
  }

  Future<List<RecentlyAddedItem>> _fetchRecentlyAdded() async {
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(recentlyAddedFullQuery),
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

    final items = (result.data!['recentlyAdded'] as List<dynamic>?)
            ?.map((e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return items;
  }

  Future<void> refresh() async {
    final previousData = state.value;
    state = const AsyncValue.loading();

    final result = await AsyncValue.guard(() => _fetchRecentlyAdded());
    if (result.hasError && previousData != null) {
      debugPrint(
          '[RecentlyAddedController] Refresh failed, keeping previous data: ${result.error}');
      state = AsyncValue.data(previousData);
      return;
    }
    state = result;
  }
}
