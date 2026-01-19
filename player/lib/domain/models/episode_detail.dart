import 'artwork.dart';
import 'progress.dart';
import 'media_file.dart';

/// Represents detailed episode information including parent show context.
/// Used by the episode detail screen.
class EpisodeDetail {
  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String? overview;
  final String? airDate;
  final int? runtime;
  final bool monitored;
  final String? thumbnailUrl;
  final bool hasFile;
  final Progress? progress;
  final List<MediaFile> files;
  final EpisodeShow show;

  const EpisodeDetail({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.overview,
    this.airDate,
    this.runtime,
    required this.monitored,
    this.thumbnailUrl,
    required this.hasFile,
    this.progress,
    this.files = const [],
    required this.show,
  });

  factory EpisodeDetail.fromJson(Map<String, dynamic> json) {
    return EpisodeDetail(
      id: json['id'].toString(),
      seasonNumber: json['seasonNumber'] as int,
      episodeNumber: json['episodeNumber'] as int,
      title: json['title'] as String? ?? 'Episode ${json['episodeNumber']}',
      overview: json['overview'] as String?,
      airDate: json['airDate'] as String?,
      runtime: json['runtime'] as int?,
      monitored: json['monitored'] as bool? ?? false,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      hasFile: json['hasFile'] as bool? ?? false,
      progress: json['progress'] != null
          ? Progress.fromJson(json['progress'] as Map<String, dynamic>)
          : null,
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      show: EpisodeShow.fromJson(json['show'] as Map<String, dynamic>),
    );
  }

  /// Episode code in S##E## format
  String get episodeCode =>
      'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';

  /// Formatted runtime display (e.g., "45m" or "1h 30m")
  String get runtimeDisplay {
    if (runtime == null) return '';
    final minutes = runtime!;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  }

  /// Full title including show name and episode code
  String get fullTitle => '${show.title} - $episodeCode';
}

/// Minimal show info embedded in episode detail
class EpisodeShow {
  final String id;
  final String title;
  final Artwork artwork;

  const EpisodeShow({
    required this.id,
    required this.title,
    required this.artwork,
  });

  factory EpisodeShow.fromJson(Map<String, dynamic> json) {
    return EpisodeShow(
      id: json['id'].toString(),
      title: json['title'] as String? ?? 'Unknown Show',
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : const Artwork(),
    );
  }
}
