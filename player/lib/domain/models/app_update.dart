/// Represents an available app update from GitHub Releases.
class AppUpdate {
  /// The new version string (e.g. "1.2.0").
  final String version;

  /// Direct download URL for the platform-specific asset.
  final String downloadUrl;

  /// Size of the download in bytes, if known.
  final int? downloadSize;

  /// URL to the release notes page on GitHub.
  final String releaseNotesUrl;

  /// Brief description / release title.
  final String releaseTitle;

  /// When the release was published.
  final DateTime publishedAt;

  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    this.downloadSize,
    required this.releaseNotesUrl,
    required this.releaseTitle,
    required this.publishedAt,
  });
}
