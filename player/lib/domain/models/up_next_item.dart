import 'artwork.dart';

class UpNextEpisode {
  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String? airDate;
  final String? thumbnailUrl;
  final bool hasFile;

  const UpNextEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.airDate,
    this.thumbnailUrl,
    required this.hasFile,
  });

  factory UpNextEpisode.fromJson(Map<String, dynamic> json) {
    return UpNextEpisode(
      id: json['id'].toString(),
      seasonNumber: json['seasonNumber'] as int,
      episodeNumber: json['episodeNumber'] as int,
      title: json['title'] as String,
      airDate: json['airDate'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      hasFile: json['hasFile'] as bool,
    );
  }

  String get episodeCode => 'S${seasonNumber}E${episodeNumber}';
}

class UpNextShow {
  final String id;
  final String title;
  final Artwork? artwork;

  const UpNextShow({
    required this.id,
    required this.title,
    this.artwork,
  });

  factory UpNextShow.fromJson(Map<String, dynamic> json) {
    return UpNextShow(
      id: json['id'].toString(),
      title: json['title'] as String,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : null,
    );
  }

  String? get posterUrl => artwork?.posterUrl;
}

class UpNextItem {
  final String progressState;
  final UpNextEpisode episode;
  final UpNextShow show;

  const UpNextItem({
    required this.progressState,
    required this.episode,
    required this.show,
  });

  factory UpNextItem.fromJson(Map<String, dynamic> json) {
    return UpNextItem(
      progressState: json['progressState'] as String,
      episode: UpNextEpisode.fromJson(json['episode'] as Map<String, dynamic>),
      show: UpNextShow.fromJson(json['show'] as Map<String, dynamic>),
    );
  }

  String get displayTitle => '${show.title} - ${episode.episodeCode}';
  String? get posterUrl => show.posterUrl;
}
