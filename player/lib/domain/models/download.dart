import 'package:hive/hive.dart';

enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  paused,
  cancelled,
  /// Transcoding in progress on server
  transcoding,
  /// Queued waiting for download slot
  queued,
}

enum MediaType {
  movie,
  episode,
}

@HiveType(typeId: 0)
class DownloadTask {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String mediaId;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String quality;

  @HiveField(4)
  final double progress;

  @HiveField(5)
  final String status;

  @HiveField(6)
  final String mediaType;

  @HiveField(7)
  final String? filePath;

  @HiveField(8)
  final int? fileSize;

  @HiveField(9)
  final String? downloadUrl;

  @HiveField(10)
  final String? posterUrl;

  @HiveField(11)
  final String? error;

  @HiveField(12)
  final DateTime createdAt;

  @HiveField(13)
  final DateTime? completedAt;

  // Progressive download fields
  @HiveField(14)
  final String? transcodeJobId;

  @HiveField(15)
  final double transcodeProgress;

  @HiveField(16)
  final double downloadProgress;

  @HiveField(17)
  final bool isProgressive;

  @HiveField(18)
  final int? downloadedBytes;

  const DownloadTask({
    required this.id,
    required this.mediaId,
    required this.title,
    required this.quality,
    this.progress = 0.0,
    this.status = 'pending',
    this.mediaType = 'movie',
    this.filePath,
    this.fileSize,
    this.downloadUrl,
    this.posterUrl,
    this.error,
    required this.createdAt,
    this.completedAt,
    // Progressive download fields
    this.transcodeJobId,
    this.transcodeProgress = 0.0,
    this.downloadProgress = 0.0,
    this.isProgressive = false,
    this.downloadedBytes,
  });

  DownloadStatus get downloadStatus {
    switch (status) {
      case 'pending':
        return DownloadStatus.pending;
      case 'downloading':
        return DownloadStatus.downloading;
      case 'completed':
        return DownloadStatus.completed;
      case 'failed':
        return DownloadStatus.failed;
      case 'paused':
        return DownloadStatus.paused;
      case 'cancelled':
        return DownloadStatus.cancelled;
      case 'transcoding':
        return DownloadStatus.transcoding;
      case 'queued':
        return DownloadStatus.queued;
      default:
        return DownloadStatus.pending;
    }
  }

  /// Combined progress for progressive downloads.
  /// For progressive downloads, this weights transcode and download progress.
  double get combinedProgress {
    if (!isProgressive) {
      return progress;
    }
    // Weight: 30% transcode, 70% download (download is the slower operation)
    return (transcodeProgress * 0.3) + (downloadProgress * 0.7);
  }

  /// Status display text for progressive downloads.
  String get statusDisplay {
    if (!isProgressive) {
      return status;
    }

    switch (downloadStatus) {
      case DownloadStatus.transcoding:
        return 'Preparing ${(transcodeProgress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.downloading:
        if (transcodeProgress < 1.0) {
          return 'Preparing & Downloading';
        }
        return 'Downloading ${(downloadProgress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.paused:
        return 'Paused';
      case DownloadStatus.cancelled:
        return 'Cancelled';
      case DownloadStatus.pending:
        return 'Pending';
      case DownloadStatus.queued:
        return 'Queued';
    }
  }

  MediaType get type {
    return mediaType == 'episode' ? MediaType.episode : MediaType.movie;
  }

  DownloadTask copyWith({
    String? id,
    String? mediaId,
    String? title,
    String? quality,
    double? progress,
    String? status,
    String? mediaType,
    String? filePath,
    int? fileSize,
    String? downloadUrl,
    String? posterUrl,
    String? error,
    DateTime? createdAt,
    DateTime? completedAt,
    String? transcodeJobId,
    double? transcodeProgress,
    double? downloadProgress,
    bool? isProgressive,
    int? downloadedBytes,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      mediaId: mediaId ?? this.mediaId,
      title: title ?? this.title,
      quality: quality ?? this.quality,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      mediaType: mediaType ?? this.mediaType,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      posterUrl: posterUrl ?? this.posterUrl,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      transcodeJobId: transcodeJobId ?? this.transcodeJobId,
      transcodeProgress: transcodeProgress ?? this.transcodeProgress,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      isProgressive: isProgressive ?? this.isProgressive,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    );
  }

  String get fileSizeDisplay {
    if (fileSize == null) return 'Unknown size';
    final bytes = fileSize!;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get progressDisplay {
    return '${(progress * 100).toStringAsFixed(0)}%';
  }
}

@HiveType(typeId: 1)
class DownloadedMedia {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String mediaId;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String quality;

  @HiveField(4)
  final String filePath;

  @HiveField(5)
  final int fileSize;

  @HiveField(6)
  final String mediaType;

  @HiveField(7)
  final String? posterUrl;

  @HiveField(8)
  final DateTime downloadedAt;

  const DownloadedMedia({
    required this.id,
    required this.mediaId,
    required this.title,
    required this.quality,
    required this.filePath,
    required this.fileSize,
    this.mediaType = 'movie',
    this.posterUrl,
    required this.downloadedAt,
  });

  MediaType get type {
    return mediaType == 'episode' ? MediaType.episode : MediaType.movie;
  }

  String get fileSizeDisplay {
    final bytes = fileSize;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  factory DownloadedMedia.fromTask(DownloadTask task) {
    return DownloadedMedia(
      id: task.id,
      mediaId: task.mediaId,
      title: task.title,
      quality: task.quality,
      filePath: task.filePath!,
      fileSize: task.fileSize!,
      mediaType: task.mediaType,
      posterUrl: task.posterUrl,
      downloadedAt: task.completedAt ?? DateTime.now(),
    );
  }
}
