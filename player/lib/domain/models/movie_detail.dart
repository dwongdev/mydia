import 'artwork.dart';
import 'progress.dart';
import 'media_file.dart';

class MovieDetail {
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final int? runtime;
  final List<String> genres;
  final String? contentRating;
  final double? rating;
  final String? tmdbId;
  final String? imdbId;
  final String? category;
  final bool monitored;
  final String? addedAt;
  final Artwork artwork;
  final Progress? progress;
  final List<MediaFile> files;
  final bool isFavorite;

  const MovieDetail({
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.runtime,
    this.genres = const [],
    this.contentRating,
    this.rating,
    this.tmdbId,
    this.imdbId,
    this.category,
    required this.monitored,
    this.addedAt,
    required this.artwork,
    this.progress,
    this.files = const [],
    required this.isFavorite,
  });

  factory MovieDetail.fromJson(Map<String, dynamic> json) {
    return MovieDetail(
      id: json['id'].toString(),
      title: json['title'] as String,
      originalTitle: json['originalTitle'] as String?,
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      runtime: json['runtime'] as int?,
      genres: (json['genres'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      contentRating: json['contentRating'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      tmdbId: json['tmdbId']?.toString(),
      imdbId: json['imdbId'] as String?,
      category: json['category'] as String?,
      monitored: json['monitored'] as bool? ?? false,
      addedAt: json['addedAt'] as String?,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : const Artwork(),
      progress: json['progress'] != null
          ? Progress.fromJson(json['progress'] as Map<String, dynamic>)
          : null,
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }

  String get yearDisplay => year?.toString() ?? '';

  String get runtimeDisplay {
    if (runtime == null) return '';
    final hours = runtime! ~/ 60;
    final minutes = runtime! % 60;
    if (hours == 0) return '${minutes}m';
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }

  String get ratingDisplay {
    if (rating == null) return '';
    return rating!.toStringAsFixed(1);
  }
}
