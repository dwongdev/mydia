/// User settings model representing app preferences.
class UserSettings {
  final String serverUrl;
  final String username;
  final String defaultQuality;
  final bool autoPlayNextEpisode;

  const UserSettings({
    required this.serverUrl,
    required this.username,
    this.defaultQuality = 'auto',
    this.autoPlayNextEpisode = true,
  });

  UserSettings copyWith({
    String? serverUrl,
    String? username,
    String? defaultQuality,
    bool? autoPlayNextEpisode,
  }) {
    return UserSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'defaultQuality': defaultQuality,
      'autoPlayNextEpisode': autoPlayNextEpisode,
    };
  }

  factory UserSettings.fromJson(Map<String, dynamic> json) {
    return UserSettings(
      serverUrl: json['serverUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      defaultQuality: json['defaultQuality'] as String? ?? 'auto',
      autoPlayNextEpisode: json['autoPlayNextEpisode'] as bool? ?? true,
    );
  }
}
