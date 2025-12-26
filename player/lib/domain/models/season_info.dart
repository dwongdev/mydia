class SeasonInfo {
  final int seasonNumber;
  final int episodeCount;
  final int airedEpisodeCount;
  final bool hasFiles;

  const SeasonInfo({
    required this.seasonNumber,
    required this.episodeCount,
    required this.airedEpisodeCount,
    required this.hasFiles,
  });

  factory SeasonInfo.fromJson(Map<String, dynamic> json) {
    return SeasonInfo(
      seasonNumber: json['seasonNumber'] as int,
      episodeCount: json['episodeCount'] as int? ?? 0,
      airedEpisodeCount: json['airedEpisodeCount'] as int? ?? 0,
      hasFiles: json['hasFiles'] as bool? ?? false,
    );
  }
}
