class Artwork {
  final String? posterUrl;
  final String? backdropUrl;
  final String? thumbnailUrl;

  const Artwork({
    this.posterUrl,
    this.backdropUrl,
    this.thumbnailUrl,
  });

  factory Artwork.fromJson(Map<String, dynamic> json) {
    return Artwork(
      posterUrl: json['posterUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'posterUrl': posterUrl,
      'backdropUrl': backdropUrl,
      'thumbnailUrl': thumbnailUrl,
    };
  }
}
