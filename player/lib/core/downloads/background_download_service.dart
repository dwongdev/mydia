/// Background download service using background_downloader package.
///
/// Provides background download capabilities on iOS and Android.
/// Uses WorkManager on Android and URLSession on iOS.
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/download.dart' as models;

/// Check if background downloads are supported on this platform.
bool get isBackgroundDownloadSupported => Platform.isIOS || Platform.isAndroid;

/// Service for managing background downloads.
///
/// This service wraps the background_downloader package to provide
/// background download functionality on iOS and Android.
class BackgroundDownloadService {
  static BackgroundDownloadService? _instance;
  static BackgroundDownloadService get instance {
    _instance ??= BackgroundDownloadService._();
    return _instance!;
  }

  BackgroundDownloadService._();

  final bg.FileDownloader _downloader = bg.FileDownloader();
  final Map<String, models.DownloadTask> _taskIdToDownloadTask = {};
  final Map<String, String> _bgTaskIdToTaskId = {};
  final StreamController<models.DownloadTask> _progressController =
      StreamController<models.DownloadTask>.broadcast();

  bool _initialized = false;

  /// Stream of download progress updates.
  Stream<models.DownloadTask> get progressStream => _progressController.stream;

  /// Initialize the background download service.
  ///
  /// Must be called before using any download methods.
  Future<void> initialize() async {
    if (_initialized) return;

    // Configure the downloader
    _downloader.configure(
      globalConfig: [
        // Max 3 concurrent downloads in the holding queue
        (bg.Config.holdingQueue, (3, null, null)),
      ],
      androidConfig: [
        // Run in foreground for long downloads (avoids 9-minute timeout)
        (bg.Config.runInForeground, bg.Config.always),
      ],
      iOSConfig: [
        // 1 hour resource timeout for large files
        (bg.Config.resourceTimeout, 3600),
      ],
    );

    // Configure notifications
    _downloader.configureNotification(
      running: const bg.TaskNotification(
        'Downloading',
        '{displayName}',
      ),
      complete: const bg.TaskNotification(
        'Download complete',
        '{displayName}',
      ),
      error: const bg.TaskNotification(
        'Download failed',
        '{displayName}',
      ),
      paused: const bg.TaskNotification(
        'Download paused',
        '{displayName}',
      ),
      progressBar: true,
    );

    // Register the task status callback
    _downloader.registerCallbacks(
      taskStatusCallback: _onTaskStatus,
      taskProgressCallback: _onTaskProgress,
    );

    // Resume any downloads that were interrupted when app was killed
    await _resumeInterruptedDownloads();

    _initialized = true;
  }

  /// Get the download directory path.
  Future<String> _getDownloadDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final downloadDir = Directory('${directory.path}/downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  /// Generate a filename for a download task.
  String _generateFileName(models.DownloadTask task) {
    final sanitizedTitle = task.title.replaceAll(RegExp(r'[^\w\s-]'), '');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${sanitizedTitle}_${task.quality}_$timestamp.mp4';
  }

  /// Start a background download.
  ///
  /// Returns the updated DownloadTask with the background task ID.
  Future<models.DownloadTask> startDownload(models.DownloadTask task) async {
    if (!_initialized) {
      throw StateError('BackgroundDownloadService not initialized');
    }

    if (task.downloadUrl == null) {
      throw ArgumentError('Download URL is required');
    }

    final downloadDir = await _getDownloadDirectory();
    final fileName = _generateFileName(task);
    final filePath = '$downloadDir/$fileName';

    // Create the background download task
    final bgTask = bg.DownloadTask(
      url: task.downloadUrl!,
      filename: fileName,
      directory: downloadDir,
      displayName: task.title,
      updates: bg.Updates.statusAndProgress,
      allowPause: true,
      retries: 3,
    );

    // Map the background task ID to our task ID
    _bgTaskIdToTaskId[bgTask.taskId] = task.id;
    _taskIdToDownloadTask[task.id] = task.copyWith(
      filePath: filePath,
      status: 'downloading',
    );

    // Enqueue the download
    final result = await _downloader.enqueue(bgTask);
    if (!result) {
      throw StateError('Failed to enqueue download');
    }

    return _taskIdToDownloadTask[task.id]!;
  }

  /// Pause a background download.
  Future<void> pauseDownload(String taskId) async {
    final bgTaskId = _findBgTaskId(taskId);
    if (bgTaskId != null) {
      await _downloader.pause(
        bg.DownloadTask(url: '', taskId: bgTaskId),
      );
    }
  }

  /// Resume a paused background download.
  Future<void> resumeDownload(String taskId) async {
    final bgTaskId = _findBgTaskId(taskId);
    if (bgTaskId != null) {
      await _downloader.resume(
        bg.DownloadTask(url: '', taskId: bgTaskId),
      );
    }
  }

  /// Cancel a background download.
  Future<void> cancelDownload(String taskId) async {
    final bgTaskId = _findBgTaskId(taskId);
    if (bgTaskId != null) {
      await _downloader.cancelTaskWithId(bgTaskId);
      _cleanup(taskId);
    }
  }

  /// Find the background task ID for a given task ID.
  String? _findBgTaskId(String taskId) {
    for (final entry in _bgTaskIdToTaskId.entries) {
      if (entry.value == taskId) {
        return entry.key;
      }
    }
    return null;
  }

  /// Handle task status updates from background_downloader.
  void _onTaskStatus(bg.TaskStatusUpdate update) {
    final taskId = _bgTaskIdToTaskId[update.task.taskId];
    if (taskId == null) return;

    final task = _taskIdToDownloadTask[taskId];
    if (task == null) return;

    models.DownloadTask updatedTask;
    switch (update.status) {
      case bg.TaskStatus.enqueued:
        updatedTask = task.copyWith(status: 'pending');
      case bg.TaskStatus.running:
        updatedTask = task.copyWith(status: 'downloading');
      case bg.TaskStatus.complete:
        updatedTask = task.copyWith(
          status: 'completed',
          progress: 1.0,
          downloadProgress: 1.0,
          completedAt: DateTime.now(),
        );
        _cleanup(taskId);
      case bg.TaskStatus.paused:
        updatedTask = task.copyWith(status: 'paused');
      case bg.TaskStatus.canceled:
        updatedTask = task.copyWith(
          status: 'cancelled',
          error: 'Cancelled by user',
        );
        _cleanup(taskId);
      case bg.TaskStatus.failed:
        final error = update.exception?.description ?? 'Download failed';
        updatedTask = task.copyWith(
          status: 'failed',
          error: error,
        );
        _cleanup(taskId);
      case bg.TaskStatus.notFound:
        updatedTask = task.copyWith(
          status: 'failed',
          error: 'Download not found',
        );
        _cleanup(taskId);
      case bg.TaskStatus.waitingToRetry:
        updatedTask = task.copyWith(status: 'pending');
    }

    _taskIdToDownloadTask[taskId] = updatedTask;
    _progressController.add(updatedTask);
  }

  /// Handle task progress updates from background_downloader.
  void _onTaskProgress(bg.TaskProgressUpdate update) {
    final taskId = _bgTaskIdToTaskId[update.task.taskId];
    if (taskId == null) return;

    final task = _taskIdToDownloadTask[taskId];
    if (task == null) return;

    final progress = update.progress;
    final updatedTask = task.copyWith(
      progress: progress,
      downloadProgress: progress,
      status: 'downloading',
    );

    _taskIdToDownloadTask[taskId] = updatedTask;
    _progressController.add(updatedTask);
  }

  /// Resume downloads that were interrupted when app was killed.
  Future<void> _resumeInterruptedDownloads() async {
    final records = await _downloader.database.allRecords();
    for (final record in records) {
      if (record.status == bg.TaskStatus.paused ||
          record.status == bg.TaskStatus.running) {
        // Try to resume
        await _downloader.resume(record.task as bg.DownloadTask);
      }
    }
  }

  /// Clean up task mappings.
  void _cleanup(String taskId) {
    final bgTaskId = _findBgTaskId(taskId);
    if (bgTaskId != null) {
      _bgTaskIdToTaskId.remove(bgTaskId);
    }
    _taskIdToDownloadTask.remove(taskId);
  }

  /// Dispose of resources.
  void dispose() {
    _progressController.close();
    _instance = null;
  }
}
