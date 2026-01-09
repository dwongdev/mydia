import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/episode_detail.dart';

part 'episode_detail_controller.g.dart';

const String episodeDetailQuery = r'''
query EpisodeDetail($id: ID!) {
  episode(id: $id) {
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
      subtitles {
        trackId
        language
        title
        format
        embedded
        url(format: VTT)
      }
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
}
''';

@riverpod
class EpisodeDetailController extends _$EpisodeDetailController {
  @override
  Future<EpisodeDetail> build(String id) async {
    return _fetchEpisode(id);
  }

  Future<EpisodeDetail> _fetchEpisode(String id) async {
    final client = await ref.read(asyncGraphqlClientProvider.future);

    final result = await client.query(
      QueryOptions(
        document: gql(episodeDetailQuery),
        variables: {'id': id},
        fetchPolicy: FetchPolicy.cacheAndNetwork,
      ),
    );

    if (result.hasException) {
      throw result.exception!;
    }

    if (result.data == null || result.data!['episode'] == null) {
      throw Exception('Episode not found');
    }

    return EpisodeDetail.fromJson(
        result.data!['episode'] as Map<String, dynamic>);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _fetchEpisode(id));
  }
}
