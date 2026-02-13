import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/collection.dart';

part 'collections_controller.g.dart';

const String collectionsQuery = r'''
query Collections($first: Int) {
  collections(first: $first) {
    id
    name
    description
    type
    visibility
    itemCount
    posterPaths
  }
}
''';

@riverpod
class CollectionsController extends _$CollectionsController {
  @override
  Future<List<Collection>> build() async {
    return _fetchCollections();
  }

  Future<List<Collection>> _fetchCollections() async {
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(collectionsQuery),
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

    final items = (result.data!['collections'] as List<dynamic>?)
            ?.map((e) => Collection.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return items;
  }

  Future<void> refresh() async {
    final previousData = state.value;
    state = const AsyncValue.loading();

    final result = await AsyncValue.guard(() => _fetchCollections());
    if (result.hasError && previousData != null) {
      debugPrint(
          '[CollectionsController] Refresh failed, keeping previous data: ${result.error}');
      state = AsyncValue.data(previousData);
      return;
    }
    state = result;
  }
}
