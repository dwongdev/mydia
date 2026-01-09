import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../models/library_data.dart';

part 'library_controller.g.dart';

enum LibraryType { movies, tvShows }

enum SortOption {
  titleAsc('Title A-Z'),
  titleDesc('Title Z-A'),
  yearDesc('Year (Newest)'),
  yearAsc('Year (Oldest)'),
  recentlyAdded('Recently Added');

  const SortOption(this.displayName);
  final String displayName;
}

const String moviesListQuery = r'''
query MoviesList($first: Int, $after: String) {
  movies(first: $first, after: $after) {
    edges {
      node {
        id
        title
        year
        overview
        runtime
        genres
        contentRating
        rating
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
        isFavorite
      }
      cursor
    }
    pageInfo {
      hasNextPage
      hasPreviousPage
      startCursor
      endCursor
    }
    totalCount
  }
}
''';

const String tvShowsListQuery = r'''
query TvShowsList($first: Int, $after: String) {
  tvShows(first: $first, after: $after) {
    edges {
      node {
        id
        title
        year
        overview
        status
        genres
        contentRating
        rating
        seasonCount
        episodeCount
        artwork {
          posterUrl
          backdropUrl
          thumbnailUrl
        }
        isFavorite
        nextEpisode {
          id
          seasonNumber
          episodeNumber
          title
        }
      }
      cursor
    }
    pageInfo {
      hasNextPage
      hasPreviousPage
      startCursor
      endCursor
    }
    totalCount
  }
}
''';

@riverpod
class LibraryController extends _$LibraryController {
  String? _endCursor;
  bool _hasMore = true;
  SortOption _currentSort = SortOption.recentlyAdded;
  List<LibraryItem> _items = [];

  @override
  Future<LibraryData> build(LibraryType libraryType) async {
    return _fetchLibrary(reset: true);
  }

  Future<void> loadMore() async {
    if (!_hasMore || state.isLoading) return;

    state = const AsyncValue.loading();

    try {
      final newData = await _fetchLibrary(reset: false);
      state = AsyncValue.data(newData);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> setSort(SortOption sort) async {
    if (_currentSort == sort) return;

    _currentSort = sort;
    state = const AsyncValue.loading();

    try {
      final newData = await _fetchLibrary(reset: true);
      state = AsyncValue.data(newData);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();

    try {
      final newData = await _fetchLibrary(reset: true);
      state = AsyncValue.data(newData);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<LibraryData> _fetchLibrary({required bool reset}) async {
    if (reset) {
      _endCursor = null;
      _hasMore = true;
      _items = [];
    }

    // Use async provider to wait for client to be ready
    final client = await ref.read(asyncGraphqlClientProvider.future);

    if (libraryType == LibraryType.movies) {
      return _fetchMovies(client);
    } else {
      return _fetchTvShows(client);
    }
  }

  Future<LibraryData> _fetchMovies(GraphQLClient client) async {
    final result = await client.query(
      QueryOptions(
        document: gql(moviesListQuery),
        variables: {
          'first': 20,
          if (_endCursor != null) 'after': _endCursor,
        },
        fetchPolicy: FetchPolicy.cacheAndNetwork,
      ),
    );

    if (result.hasException) {
      throw Exception(result.exception.toString());
    }

    if (result.data == null) {
      throw Exception('No data returned from query');
    }

    final moviesData = result.data!['movies'] as Map<String, dynamic>;
    final edges = moviesData['edges'] as List<dynamic>;
    final pageInfo = moviesData['pageInfo'] as Map<String, dynamic>;

    _endCursor = pageInfo['endCursor'] as String?;
    _hasMore = pageInfo['hasNextPage'] as bool;

    final newItems = edges.map((edge) {
      final edgeMap = edge as Map<String, dynamic>;
      final node = edgeMap['node'] as Map<String, dynamic>;
      final artwork = node['artwork'] as Map<String, dynamic>?;
      final progress = node['progress'] as Map<String, dynamic>?;

      return LibraryItem(
        id: node['id'] as String,
        title: node['title'] as String,
        year: node['year'] as int?,
        posterUrl: artwork?['posterUrl'] as String?,
        progressPercentage: progress?['percentage'] as double?,
        isFavorite: node['isFavorite'] as bool,
        type: 'movie',
        subtitle: node['year']?.toString(),
      );
    }).toList();

    _items.addAll(newItems);

    return LibraryData(
      items: List.from(_items),
      hasMore: _hasMore,
      totalCount: moviesData['totalCount'] as int?,
    );
  }

  Future<LibraryData> _fetchTvShows(GraphQLClient client) async {
    final result = await client.query(
      QueryOptions(
        document: gql(tvShowsListQuery),
        variables: {
          'first': 20,
          if (_endCursor != null) 'after': _endCursor,
        },
        fetchPolicy: FetchPolicy.cacheAndNetwork,
      ),
    );

    if (result.hasException) {
      throw Exception(result.exception.toString());
    }

    if (result.data == null) {
      throw Exception('No data returned from query');
    }

    final tvShowsData = result.data!['tvShows'] as Map<String, dynamic>;
    final edges = tvShowsData['edges'] as List<dynamic>;
    final pageInfo = tvShowsData['pageInfo'] as Map<String, dynamic>;

    _endCursor = pageInfo['endCursor'] as String?;
    _hasMore = pageInfo['hasNextPage'] as bool;

    final newItems = edges.map((edge) {
      final edgeMap = edge as Map<String, dynamic>;
      final node = edgeMap['node'] as Map<String, dynamic>;
      final artwork = node['artwork'] as Map<String, dynamic>?;

      final subtitle = node['year'] != null ? '${node['year']}' : null;
      return LibraryItem(
        id: node['id'] as String,
        title: node['title'] as String,
        year: node['year'] as int?,
        posterUrl: artwork?['posterUrl'] as String?,
        progressPercentage: null, // TV shows don't have overall progress
        isFavorite: node['isFavorite'] as bool,
        type: 'tv_show',
        subtitle: subtitle,
        seasonCount: node['seasonCount'] as int?,
        episodeCount: node['episodeCount'] as int?,
      );
    }).toList();

    _items.addAll(newItems);

    return LibraryData(
      items: List.from(_items),
      hasMore: _hasMore,
      totalCount: tvShowsData['totalCount'] as int?,
    );
  }
}
