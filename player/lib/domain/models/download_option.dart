/// Represents a single download quality option with estimated file size.
class DownloadOption {
  /// Quality resolution identifier (e.g., "original", "1080p", "720p", "480p")
  final String resolution;

  /// Display label from server (e.g., "Original", "1080p (Full HD)")
  /// Falls back to resolution if not provided
  final String? _label;

  /// Estimated file size in bytes
  final int estimatedSize;

  const DownloadOption({
    required this.resolution,
    String? label,
    required this.estimatedSize,
  }) : _label = label;

  /// Display label - uses server-provided label or falls back to resolution
  String get label => _label ?? resolution;

  factory DownloadOption.fromJson(Map<String, dynamic> json) {
    final resolution = json['resolution'] as String;
    return DownloadOption(
      resolution: resolution,
      label: json['label'] as String?,
      estimatedSize: json['estimated_size'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'resolution': resolution,
      'label': label,
      'estimated_size': estimatedSize,
    };
  }

  /// Format file size as human-readable string
  String get formattedSize {
    if (estimatedSize < 1024) {
      return '$estimatedSize B';
    } else if (estimatedSize < 1024 * 1024) {
      return '${(estimatedSize / 1024).toStringAsFixed(1)} KB';
    } else if (estimatedSize < 1024 * 1024 * 1024) {
      return '${(estimatedSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(estimatedSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}

/// Response containing available download quality options
class DownloadOptionsResponse {
  /// List of available quality options
  final List<DownloadOption> options;

  const DownloadOptionsResponse({
    required this.options,
  });

  factory DownloadOptionsResponse.fromJson(Map<String, dynamic> json) {
    final optionsList = json['options'] as List<dynamic>? ?? [];
    return DownloadOptionsResponse(
      options: optionsList
          .map((option) => DownloadOption.fromJson(option as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'options': options.map((o) => o.toJson()).toList(),
    };
  }
}

/// Status of a download transcode job
enum DownloadJobStatusType {
  pending,
  transcoding,
  ready,
  failed;

  static DownloadJobStatusType fromString(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return DownloadJobStatusType.pending;
      case 'transcoding':
        return DownloadJobStatusType.transcoding;
      case 'ready':
        return DownloadJobStatusType.ready;
      case 'failed':
        return DownloadJobStatusType.failed;
      default:
        return DownloadJobStatusType.pending;
    }
  }
}

/// Current status and progress of a download transcode job
class DownloadJobStatus {
  /// Unique job identifier
  final String jobId;

  /// Current job status
  final DownloadJobStatusType status;

  /// Transcode progress (0.0 to 1.0)
  final double progress;

  /// Current file size in bytes (for in-progress downloads)
  final int? currentFileSize;

  /// Error message if job failed
  final String? error;

  const DownloadJobStatus({
    required this.jobId,
    required this.status,
    required this.progress,
    this.currentFileSize,
    this.error,
  });

  factory DownloadJobStatus.fromJson(Map<String, dynamic> json) {
    return DownloadJobStatus(
      jobId: json['job_id'] as String,
      status: DownloadJobStatusType.fromString(json['status'] as String),
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      currentFileSize: json['current_file_size'] as int?,
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'job_id': jobId,
      'status': status.name,
      'progress': progress,
      if (currentFileSize != null) 'current_file_size': currentFileSize,
      if (error != null) 'error': error,
    };
  }

  /// Whether the job is complete (ready or failed)
  bool get isComplete => status == DownloadJobStatusType.ready || status == DownloadJobStatusType.failed;

  /// Whether the job is in progress (pending or transcoding)
  bool get isInProgress => status == DownloadJobStatusType.pending || status == DownloadJobStatusType.transcoding;

  /// Format progress as percentage string
  String get progressPercentage => '${(progress * 100).toStringAsFixed(0)}%';
}
