/// Download settings for concurrent download management.
///
/// Allows users to configure max concurrent downloads and queue behavior.
library;

import 'package:hive/hive.dart';

part 'download_settings_adapter.dart';

/// Download settings configuration.
@HiveType(typeId: 3)
class DownloadSettings {
  /// Maximum number of concurrent downloads.
  @HiveField(0)
  final int maxConcurrentDownloads;

  /// Whether to auto-start queued downloads when slots become available.
  @HiveField(1)
  final bool autoStartQueued;

  const DownloadSettings({
    this.maxConcurrentDownloads = 2,
    this.autoStartQueued = true,
  });

  /// Default download settings.
  static const DownloadSettings defaultSettings = DownloadSettings();

  DownloadSettings copyWith({
    int? maxConcurrentDownloads,
    bool? autoStartQueued,
  }) {
    return DownloadSettings(
      maxConcurrentDownloads:
          maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      autoStartQueued: autoStartQueued ?? this.autoStartQueued,
    );
  }
}
