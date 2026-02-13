import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/recently_added_item.dart';

part 'collection_detail_controller.g.dart';

const String collectionItemsQuery = r'''
query CollectionItems($collectionId: ID!, $first: Int) {
  collectionItems(collectionId: $collectionId, first: $first) {
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
class CollectionDetailController extends _$CollectionDetailController {
  @override
  Future<List<RecentlyAddedItem>> build(String collectionId) async {
    return _fetchItems();
  }

  Future<List<RecentlyAddedItem>> _fetchItems() async {
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(collectionItemsQuery),
        variables: {
          'collectionId': collectionId,
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

    final items = (result.data!['collectionItems'] as List<dynamic>?)
            ?.map((e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return items;
  }

  Future<void> refresh() async {
    final previousData = state.value;
    state = const AsyncValue.loading();

    final result = await AsyncValue.guard(() => _fetchItems());
    if (result.hasError && previousData != null) {
      debugPrint(
          '[CollectionDetailController] Refresh failed, keeping previous data: ${result.error}');
      state = AsyncValue.data(previousData);
      return;
    }
    state = result;
  }
}
