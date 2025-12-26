/// Represents a subtitle track available for a media file.
class SubtitleTrack {
  /// Unique identifier for the track
  final String id;

  /// ISO 639-2 language code (e.g., 'eng', 'spa')
  final String language;

  /// Human-readable title (optional)
  final String? title;

  /// URL for external subtitles (if not embedded)
  final String? url;

  /// Whether this is the default track
  final bool isDefault;

  /// Format of the subtitle (srt, vtt, ass)
  final String format;

  /// Whether the subtitle is embedded in the video file
  final bool embedded;

  const SubtitleTrack({
    required this.id,
    required this.language,
    this.title,
    this.url,
    this.isDefault = false,
    this.format = 'srt',
    this.embedded = false,
  });

  /// Returns a display name for the track
  String get displayName {
    if (title != null && title!.isNotEmpty) {
      return title!;
    }
    return _languageCodeToName(language);
  }

  /// Convert language code to human-readable name
  static String _languageCodeToName(String code) {
    const languageMap = {
      'eng': 'English',
      'spa': 'Spanish',
      'fre': 'French',
      'ger': 'German',
      'ita': 'Italian',
      'por': 'Portuguese',
      'rus': 'Russian',
      'jpn': 'Japanese',
      'kor': 'Korean',
      'chi': 'Chinese',
      'ara': 'Arabic',
      'hin': 'Hindi',
    };
    return languageMap[code] ?? code.toUpperCase();
  }

  /// Create from API response JSON
  factory SubtitleTrack.fromJson(Map<String, dynamic> json) {
    return SubtitleTrack(
      id: json['track_id'].toString(),
      language: json['language'] as String? ?? 'und',
      title: json['title'] as String?,
      format: json['format'] as String? ?? 'srt',
      embedded: json['embedded'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleTrack &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
