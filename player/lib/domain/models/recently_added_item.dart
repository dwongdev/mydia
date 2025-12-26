import 'artwork.dart';

class RecentlyAddedItem {
  final String id;
  final String type;
  final String title;
  final int? year;
  final Artwork? artwork;
  final String? addedAt;

  const RecentlyAddedItem({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.artwork,
    this.addedAt,
  });

  factory RecentlyAddedItem.fromJson(Map<String, dynamic> json) {
    return RecentlyAddedItem(
      id: json['id'].toString(),
      type: json['type'] as String,
      title: json['title'] as String,
      year: json['year'] as int?,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : null,
      addedAt: json['addedAt'] as String?,
    );
  }

  bool get isShow => type.toLowerCase() == 'tv_show';
  bool get isMovie => type.toLowerCase() == 'movie';

  String? get posterUrl => artwork?.posterUrl;
  String? get backdropUrl => artwork?.backdropUrl;
  // For compatibility with _HeroSection which checks showTitle
  String? get showTitle => null;

  String get displayTitle {
    if (year != null) {
      return '$title ($year)';
    }
    return title;
  }
}
