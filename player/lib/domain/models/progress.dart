class Progress {
  final int positionSeconds;
  final int? durationSeconds;
  final double percentage;
  final bool watched;
  final String? lastWatchedAt;

  const Progress({
    required this.positionSeconds,
    this.durationSeconds,
    required this.percentage,
    required this.watched,
    this.lastWatchedAt,
  });

  factory Progress.fromJson(Map<String, dynamic> json) {
    return Progress(
      positionSeconds: json['positionSeconds'] as int,
      durationSeconds: json['durationSeconds'] as int?,
      percentage: (json['percentage'] as num).toDouble(),
      watched: json['watched'] as bool,
      lastWatchedAt: json['lastWatchedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'positionSeconds': positionSeconds,
      'durationSeconds': durationSeconds,
      'percentage': percentage,
      'watched': watched,
      'lastWatchedAt': lastWatchedAt,
    };
  }
}
