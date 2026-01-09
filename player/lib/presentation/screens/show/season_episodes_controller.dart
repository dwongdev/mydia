import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/episode.dart';

part 'season_episodes_controller.g.dart';

const String seasonEpisodesQuery = r'''
query SeasonEpisodes($showId: ID!, $seasonNumber: Int!) {
  seasonEpisodes(showId: $showId, seasonNumber: $seasonNumber) {
    id
    seasonNumber
    episodeNumber
    title
    overview
    airDate
    runtime
    monitored
    thumbnailUrl
    hasFile
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    files {
      id
      resolution
      codec
      audioCodec
      hdrFormat
      size
      bitrate
      directPlaySupported
      streamUrl
      directPlayUrl
    }
  }
}
''';

@riverpod
class SeasonEpisodesController extends _$SeasonEpisodesController {
  @override
  Future<List<Episode>> build({
    required String showId,
    required int seasonNumber,
  }) async {
    return _fetchEpisodes(showId, seasonNumber);
  }

  Future<List<Episode>> _fetchEpisodes(String showId, int seasonNumber) async {
    // Use async provider to wait for client to be ready
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(seasonEpisodesQuery),
        variables: {
          'showId': showId,
          'seasonNumber': seasonNumber,
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

    final episodesData = result.data!['seasonEpisodes'] as List<dynamic>? ?? [];
    // Only return episodes that have files available in Mydia
    return episodesData
        .map((e) => Episode.fromJson(e as Map<String, dynamic>))
        .where((episode) => episode.hasFile)
        .toList();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _fetchEpisodes(showId, seasonNumber),
    );
  }
}
