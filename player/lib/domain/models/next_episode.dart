class NextEpisode {
  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String? title;
  final String? airDate;

  const NextEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.airDate,
  });

  factory NextEpisode.fromJson(Map<String, dynamic> json) {
    return NextEpisode(
      id: json['id'].toString(),
      seasonNumber: json['seasonNumber'] as int,
      episodeNumber: json['episodeNumber'] as int,
      title: json['title'] as String?,
      airDate: json['airDate'] as String?,
    );
  }

  String get episodeCode => 'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';
}
