/// Native implementation of download service.
///
/// This provides the full download functionality on iOS, Android, and desktop.
/// On mobile platforms (iOS/Android), uses background_downloader for background
/// download capability. On desktop, uses Dio for foreground downloads.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models/download.dart';
import '../../domain/models/download_adapters.dart';
import '../../domain/models/download_settings.dart';
import '../../domain/models/storage_settings.dart';
import 'background_download_service.dart';
import 'download_service.dart';

/// Whether to use background downloads (true on mobile, false on desktop).
bool get _useBackgroundDownloader => Platform.isIOS || Platform.isAndroid;

/// Downloads are fully supported on native platforms.
const bool isDownloadSupported = true;

/// Get the native download service implementation.
DownloadService getDownloadService() => _NativeDownloadService();

/// Get the native download database implementation.
DownloadDatabase getDownloadDatabase() => _NativeDownloadDatabase();

class _NativeDownloadDatabase implements DownloadDatabase {
  static const String _tasksBoxName = 'download_tasks';
  static const String _mediaBoxName = 'downloaded_media';

  late Box<DownloadTask> _tasksBox;
  late Box<DownloadedMedia> _mediaBox;

  @override
  Future<void> initialize() async {
    await Hive.initFlutter();

    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(DownloadedMediaAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(StorageSettingsAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(DownloadSettingsAdapter());
    }

    _tasksBox = await Hive.openBox<DownloadTask>(_tasksBoxName);
    _mediaBox = await Hive.openBox<DownloadedMedia>(_mediaBoxName);
  }

  @override
  Future<void> saveTask(DownloadTask task) async {
    await _tasksBox.put(task.id, task);
  }

  @override
  Future<void> deleteTask(String id) async {
    await _tasksBox.delete(id);
  }

  @override
  DownloadTask? getTask(String id) {
    return _tasksBox.get(id);
  }

  @override
  List<DownloadTask> getAllTasks() {
    return _tasksBox.values.toList();
  }

  @override
  List<DownloadTask> getActiveTasks() {
    return _tasksBox.values
        .where((task) =>
            task.status == 'pending' ||
            task.status == 'downloading' ||
            task.status == 'paused')
        .toList();
  }

  @override
  List<DownloadTask> getCompletedTasks() {
    return _tasksBox.values
        .where((task) => task.status == 'completed')
        .toList();
  }

  @override
  Stream<dynamic> watchTasks() {
    return _tasksBox.watch();
  }

  @override
  Future<void> clearCompletedTasks() async {
    final completedIds = _tasksBox.values
        .where((task) => task.status == 'completed')
        .map((task) => task.id)
        .toList();

    for (final id in completedIds) {
      await _tasksBox.delete(id);
    }
  }

  @override
  Future<void> saveMedia(DownloadedMedia media) async {
    await _mediaBox.put(media.id, media);
  }

  @override
  Future<void> deleteMedia(String id) async {
    await _mediaBox.delete(id);
  }

  @override
  DownloadedMedia? getMedia(String id) {
    return _mediaBox.get(id);
  }

  @override
  DownloadedMedia? getMediaByMediaId(String mediaId) {
    try {
      return _mediaBox.values.firstWhere(
        (media) => media.mediaId == mediaId,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool isMediaDownloaded(String mediaId) {
    try {
      _mediaBox.values.firstWhere((media) => media.mediaId == mediaId);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  List<DownloadedMedia> getAllMedia() {
    return _mediaBox.values.toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  }

  @override
  Stream<dynamic> watchMedia() {
    return _mediaBox.watch();
  }

  @override
  int getTotalStorageUsed() {
    return _mediaBox.values.fold<int>(
      0,
      (total, media) => total + media.fileSize,
    );
  }

  @override
  Future<void> clearAll() async {
    await _tasksBox.clear();
    await _mediaBox.clear();
  }

  @override
  Future<void> close() async {
    await _tasksBox.close();
    await _mediaBox.close();
  }
}

class _NativeDownloadService implements DownloadService {
  _NativeDownloadDatabase? _database;
  final Dio _dio = Dio(BaseOptions(
    receiveTimeout: const Duration(minutes: 30),
    sendTimeout: const Duration(minutes: 30),
  ));
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, bool> _pausedTasks = {};
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  // Background download service for mobile platforms
  BackgroundDownloadService? _backgroundService;
  StreamSubscription<DownloadTask>? _backgroundProgressSubscription;
  bool _backgroundServiceInitialized = false;

  // Queue management
  int _maxConcurrentDownloads = 2;
  bool _autoStartQueued = true;

  /// Set the maximum concurrent downloads limit.
  void setMaxConcurrentDownloads(int max) {
    _maxConcurrentDownloads = max;
  }

  /// Set whether to auto-start queued downloads.
  void setAutoStartQueued(bool autoStart) {
    _autoStartQueued = autoStart;
  }

  /// Get the number of currently active downloads.
  int getActiveDownloadCount() {
    if (_database == null) return 0;
    return _database!.getAllTasks().where((t) =>
        t.status == 'downloading' || t.status == 'transcoding').length;
  }

  /// Check if there are available download slots.
  bool hasAvailableSlots() {
    return getActiveDownloadCount() < _maxConcurrentDownloads;
  }

  /// Process the download queue and start next queued downloads if slots available.
  Future<void> _processQueue() async {
    if (_database == null || !_autoStartQueued) return;

    while (hasAvailableSlots()) {
      // Get queued tasks sorted by creation date (FIFO)
      final queuedTasks = _database!.getAllTasks()
          .where((t) => t.status == 'queued')
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      if (queuedTasks.isEmpty) break;

      // Start the first queued task
      final task = queuedTasks.first;
      final pendingTask = task.copyWith(status: 'pending');
      await _database!.saveTask(pendingTask);

      // Start the download based on type
      if (task.isProgressive && task.transcodeJobId != null) {
        // For progressive downloads that were queued, we need to resume
        // The transcode job ID and other data should still be valid
        _progressController.add(pendingTask);
      } else if (task.downloadUrl != null) {
        // Use background downloads on mobile, Dio on desktop
        if (_useBackgroundDownloader) {
          await _initializeBackgroundService();
          await _backgroundService!.startDownload(pendingTask);
        } else {
          _startDownloadTask(pendingTask);
        }
      }
    }
  }

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

  void setDatabase(_NativeDownloadDatabase database) {
    _database = database;
  }

  /// Initialize background download service for mobile platforms.
  Future<void> _initializeBackgroundService() async {
    if (!_useBackgroundDownloader || _backgroundServiceInitialized) return;

    _backgroundService = BackgroundDownloadService.instance;
    await _backgroundService!.initialize();

    // Listen to background download progress and forward to our stream
    _backgroundProgressSubscription =
        _backgroundService!.progressStream.listen((task) {
      _onBackgroundProgress(task);
    });

    _backgroundServiceInitialized = true;
  }

  /// Handle progress updates from background download service.
  void _onBackgroundProgress(DownloadTask task) {
    if (_database == null) return;

    // Update the task in our database
    _database!.saveTask(task);

    // If completed, save to downloaded media
    if (task.status == 'completed' && task.filePath != null) {
      final media = DownloadedMedia.fromTask(task);
      _database!.saveMedia(media);

      // Process queue to start next download
      _processQueue();
    } else if (task.status == 'failed' || task.status == 'cancelled') {
      // Process queue on failure/cancel too
      _processQueue();
    }

    // Forward to our progress stream
    _progressController.add(task);
  }

  Future<String> _getDownloadDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final downloadDir = Directory('${directory.path}/downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  String _generateFileName(DownloadTask task) {
    final sanitizedTitle = task.title.replaceAll(RegExp(r'[^\w\s-]'), '');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${sanitizedTitle}_${task.quality}_$timestamp.mp4';
  }

  @override
  Future<DownloadTask> startDownload({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
    String? posterUrl,
    int? fileSize,
  }) async {
    if (_database == null) {
      throw StateError('Database not initialized');
    }

    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    // Check if we should queue this download
    final shouldQueue = !hasAvailableSlots();

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      fileSize: fileSize,
      createdAt: DateTime.now(),
      status: shouldQueue ? 'queued' : 'pending',
    );

    await _database!.saveTask(task);
    _progressController.add(task);

    // Only start if not queued
    if (!shouldQueue) {
      // Use background downloads on mobile, Dio on desktop
      if (_useBackgroundDownloader) {
        await _initializeBackgroundService();
        await _backgroundService!.startDownload(task);
      } else {
        _startDownloadTask(task);
      }
    }

    return task;
  }

  @override
  Future<DownloadTask> startProgressiveDownload({
    required String mediaId,
    required String title,
    required String contentType,
    required String resolution,
    required MediaType mediaType,
    String? posterUrl,
    required Future<String> Function(String jobId) getDownloadUrl,
    required Future<({String jobId, String status, double progress, int? fileSize})> Function() prepareDownload,
    required Future<({String status, double progress, int? fileSize, String? error})> Function(String jobId) getJobStatus,
  }) async {
    if (_database == null) {
      throw StateError('Database not initialized');
    }

    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    // Check if we should queue this download
    final shouldQueue = !hasAvailableSlots();

    if (shouldQueue) {
      // Queue the download - don't start transcode yet
      final task = DownloadTask(
        id: taskId,
        mediaId: mediaId,
        title: title,
        quality: resolution,
        mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
        posterUrl: posterUrl,
        createdAt: DateTime.now(),
        isProgressive: true,
        status: 'queued',
      );

      await _database!.saveTask(task);
      _progressController.add(task);
      return task;
    }

    // Prepare the transcode job on the server
    final prepareResult = await prepareDownload();
    final jobId = prepareResult.jobId;

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: resolution,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      createdAt: DateTime.now(),
      isProgressive: true,
      transcodeJobId: jobId,
      transcodeProgress: prepareResult.progress,
      status: prepareResult.status == 'ready' ? 'downloading' : 'transcoding',
      fileSize: prepareResult.fileSize,
    );

    await _database!.saveTask(task);
    _progressController.add(task);

    // Start the progressive download process
    _startProgressiveDownloadTask(
      task,
      getDownloadUrl: getDownloadUrl,
      getJobStatus: getJobStatus,
    );

    return task;
  }

  Future<void> _startProgressiveDownloadTask(
    DownloadTask task, {
    required Future<String> Function(String jobId) getDownloadUrl,
    required Future<({String status, double progress, int? fileSize, String? error})> Function(String jobId) getJobStatus,
  }) async {
    if (_database == null) return;
    if (task.transcodeJobId == null) return;

    final jobId = task.transcodeJobId!;
    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;
    _pausedTasks[task.id] = false;

    DownloadTask updatedTask = task;

    try {
      final downloadDir = await _getDownloadDirectory();
      final fileName = _generateFileName(task);
      final filePath = '$downloadDir/$fileName';

      updatedTask = task.copyWith(filePath: filePath);
      await _database!.saveTask(updatedTask);

      // Phase 1: Wait for transcoding
      // On mobile: wait for full transcode completion before using background download
      // On desktop: can start downloading once some content is available (progressive)
      bool transcodeComplete = updatedTask.transcodeProgress >= 1.0;
      int? lastKnownFileSize;

      while (!transcodeComplete && !cancelToken.isCancelled) {
        if (_pausedTasks[task.id] == true) {
          // Paused, wait and check again
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        final status = await getJobStatus(jobId);

        if (status.error != null) {
          throw Exception('Transcode failed: ${status.error}');
        }

        updatedTask = updatedTask.copyWith(
          transcodeProgress: status.progress,
          fileSize: status.fileSize ?? updatedTask.fileSize,
          status: status.status == 'ready' ? 'downloading' : 'transcoding',
        );
        await _database!.saveTask(updatedTask);
        _progressController.add(updatedTask);

        if (status.status == 'ready') {
          transcodeComplete = true;
          lastKnownFileSize = status.fileSize;
        } else if (!_useBackgroundDownloader &&
            status.status == 'transcoding' &&
            (status.fileSize ?? 0) > 0) {
          // Desktop only: File is being produced, we can start progressive download
          lastKnownFileSize = status.fileSize;
          break;
        }

        await Future.delayed(const Duration(seconds: 2));
      }

      if (cancelToken.isCancelled) return;

      // Phase 2: Start downloading
      final downloadUrl = await getDownloadUrl(jobId);
      updatedTask = updatedTask.copyWith(
        downloadUrl: downloadUrl,
        status: 'downloading',
        fileSize: lastKnownFileSize ?? updatedTask.fileSize,
      );
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);

      // On mobile, use background download service for the file download
      // This allows downloads to continue when app is backgrounded
      if (_useBackgroundDownloader && transcodeComplete) {
        await _initializeBackgroundService();
        await _backgroundService!.startDownload(updatedTask);
        _cancelTokens.remove(task.id);
        _pausedTasks.remove(task.id);
        return; // Background service will handle the rest
      }

      // Progressive download loop - handles the case where file is still growing
      int downloadedBytes = updatedTask.downloadedBytes ?? 0;
      final file = File(filePath);

      // If resuming, check existing file size
      if (await file.exists()) {
        downloadedBytes = await file.length();
      }

      bool downloadComplete = false;

      while (!downloadComplete && !cancelToken.isCancelled) {
        if (_pausedTasks[task.id] == true) {
          // Save current progress and wait
          updatedTask = updatedTask.copyWith(
            status: 'paused',
            downloadedBytes: downloadedBytes,
          );
          await _database!.saveTask(updatedTask);
          _progressController.add(updatedTask);
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        // Check current transcode status
        if (!transcodeComplete) {
          final status = await getJobStatus(jobId);
          if (status.error != null) {
            throw Exception('Transcode failed: ${status.error}');
          }
          updatedTask = updatedTask.copyWith(
            transcodeProgress: status.progress,
            fileSize: status.fileSize ?? updatedTask.fileSize,
          );
          transcodeComplete = status.status == 'ready';
          lastKnownFileSize = status.fileSize ?? lastKnownFileSize;
        }

        // Download available bytes using Range request
        final headers = <String, dynamic>{};
        if (downloadedBytes > 0) {
          headers['Range'] = 'bytes=$downloadedBytes-';
        }

        try {
          final response = await _dio.download(
            downloadUrl,
            filePath,
            cancelToken: cancelToken,
            deleteOnError: false,
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
            ),
            onReceiveProgress: (received, total) async {
              final actualReceived = downloadedBytes + received;
              final estimatedTotal = lastKnownFileSize ?? total;

              if (estimatedTotal > 0) {
                final downloadProgress = actualReceived / estimatedTotal;
                updatedTask = updatedTask.copyWith(
                  downloadProgress: downloadProgress.clamp(0.0, 1.0),
                  progress: updatedTask.combinedProgress,
                  downloadedBytes: actualReceived,
                );
                await _database!.saveTask(updatedTask);
                _progressController.add(updatedTask);
              }
            },
          );

          // Check if we got all the data
          final currentFileSize = await file.length();
          downloadedBytes = currentFileSize;

          if (transcodeComplete && lastKnownFileSize != null && currentFileSize >= lastKnownFileSize) {
            downloadComplete = true;
          } else if (!transcodeComplete) {
            // Still transcoding, wait a bit then check for more data
            await Future.delayed(const Duration(seconds: 2));
          } else if (response.statusCode == 206) {
            // Partial content received, continue downloading
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            rethrow;
          }
          // For other errors during progressive download, retry after delay
          if (!transcodeComplete) {
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          rethrow;
        }
      }

      if (cancelToken.isCancelled) return;

      // Download complete
      final downloadedFileSize = await file.length();
      updatedTask = updatedTask.copyWith(
        status: 'completed',
        progress: 1.0,
        transcodeProgress: 1.0,
        downloadProgress: 1.0,
        fileSize: downloadedFileSize,
        completedAt: DateTime.now(),
      );
      await _database!.saveTask(updatedTask);

      // Save to downloaded media
      final media = DownloadedMedia.fromTask(updatedTask);
      await _database!.saveMedia(media);

      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
      _pausedTasks.remove(task.id);

      // Process queue to start next download
      _processQueue();
    } on DioException catch (e) {
      String errorMessage;
      if (e.type == DioExceptionType.cancel) {
        errorMessage = 'Download cancelled';
        updatedTask = updatedTask.copyWith(status: 'cancelled', error: errorMessage);
      } else {
        errorMessage = e.message ?? 'Download failed';
        updatedTask = updatedTask.copyWith(status: 'failed', error: errorMessage);
      }
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
      _pausedTasks.remove(task.id);

      // Process queue on failure/cancel
      _processQueue();
    } catch (e) {
      final errorTask = updatedTask.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      _cancelTokens.remove(task.id);
      _pausedTasks.remove(task.id);

      // Process queue on error
      _processQueue();
    }
  }

  Future<void> _startDownloadTask(DownloadTask task) async {
    if (_database == null) return;

    if (task.downloadUrl == null) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: 'Download URL is not available',
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      return;
    }

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    DownloadTask updatedTask = task;
    try {
      final downloadDir = await _getDownloadDirectory();
      final fileName = _generateFileName(task);
      final filePath = '$downloadDir/$fileName';

      // Update status to downloading
      updatedTask = task.copyWith(
        status: 'downloading',
        filePath: filePath,
      );
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);

      // Download the file
      await _dio.download(
        task.downloadUrl!,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) async {
          if (total != -1) {
            final progress = received / total;
            updatedTask = updatedTask.copyWith(
              progress: progress,
              fileSize: total,
            );
            await _database!.saveTask(updatedTask);
            _progressController.add(updatedTask);
          }
        },
      );

      // Mark as completed
      final file = File(filePath);
      final downloadedFileSize = await file.length();
      updatedTask = updatedTask.copyWith(
        status: 'completed',
        progress: 1.0,
        fileSize: downloadedFileSize,
        completedAt: DateTime.now(),
      );
      await _database!.saveTask(updatedTask);

      // Save to downloaded media
      final media = DownloadedMedia.fromTask(updatedTask);
      await _database!.saveMedia(media);

      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);

      // Process queue to start next download
      _processQueue();
    } on DioException catch (e) {
      String errorMessage;
      if (e.type == DioExceptionType.cancel) {
        errorMessage = 'Download cancelled';
        updatedTask = task.copyWith(status: 'cancelled', error: errorMessage);
      } else {
        errorMessage = e.message ?? 'Download failed';
        updatedTask = task.copyWith(status: 'failed', error: errorMessage);
      }
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);

      // Process queue even on failure/cancel
      _processQueue();
    } catch (e) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      _cancelTokens.remove(task.id);

      // Process queue even on error
      _processQueue();
    }
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task == null) return;

    // On mobile, try to pause via background service first
    if (_useBackgroundDownloader && _backgroundServiceInitialized) {
      await _backgroundService!.pauseDownload(taskId);
      // Background service will update the task status
      return;
    }

    // For progressive downloads, use the pause flag instead of cancelling
    if (task.isProgressive) {
      _pausedTasks[taskId] = true;
      final pausedTask = task.copyWith(status: 'paused');
      await _database!.saveTask(pausedTask);
      _progressController.add(pausedTask);
      return;
    }

    // For regular downloads, cancel the token
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);

      final pausedTask = task.copyWith(status: 'paused');
      await _database!.saveTask(pausedTask);
      _progressController.add(pausedTask);
    }
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task == null || task.status != 'paused') return;

    // On mobile, try to resume via background service first
    if (_useBackgroundDownloader && _backgroundServiceInitialized) {
      await _backgroundService!.resumeDownload(taskId);
      // Background service will update the task status
      return;
    }

    // For progressive downloads, just clear the pause flag
    // The download loop will continue automatically
    if (task.isProgressive) {
      _pausedTasks[taskId] = false;
      final resumedTask = task.copyWith(
        status: task.transcodeProgress >= 1.0 ? 'downloading' : 'transcoding',
      );
      await _database!.saveTask(resumedTask);
      _progressController.add(resumedTask);
      return;
    }

    // For regular downloads, restart the task
    await _startDownloadTask(task);
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    if (_database == null) return;

    // On mobile, try to cancel via background service first
    if (_useBackgroundDownloader && _backgroundServiceInitialized) {
      await _backgroundService!.cancelDownload(taskId);
      // Background service will update the task status
    }

    // Cancel the download token (for Dio-based downloads)
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);
    }

    // Remove from paused tracking
    _pausedTasks.remove(taskId);

    final task = _database!.getTask(taskId);
    if (task != null) {
      final cancelledTask = task.copyWith(
        status: 'cancelled',
        error: 'Cancelled by user',
      );
      await _database!.saveTask(cancelledTask);
      _progressController.add(cancelledTask);

      // Delete partial file if exists
      if (task.filePath != null) {
        final file = File(task.filePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  @override
  Future<void> retryDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task != null &&
        (task.status == 'failed' || task.status == 'cancelled')) {
      final retryTask = task.copyWith(
        status: 'pending',
        progress: 0.0,
        error: null,
      );
      await _database!.saveTask(retryTask);
      await _startDownloadTask(retryTask);
    }
  }

  @override
  Future<void> deleteDownload(String mediaId) async {
    if (_database == null) return;

    // Find the downloaded media
    final media = _database!.getMediaByMediaId(mediaId);
    if (media == null) {
      throw StateError('Media not found');
    }

    // Delete the file
    final file = File(media.filePath);
    if (await file.exists()) {
      await file.delete();
    }

    // Remove from database
    await _database!.deleteMedia(media.id);

    // Also remove any associated tasks
    final tasks =
        _database!.getAllTasks().where((t) => t.mediaId == mediaId);
    for (final task in tasks) {
      await _database!.deleteTask(task.id);
    }
  }

  @override
  List<DownloadTask> getActiveDownloads() {
    return _database?.getActiveTasks() ?? [];
  }

  @override
  List<DownloadedMedia> getDownloadedMedia() {
    return _database?.getAllMedia() ?? [];
  }

  @override
  bool isMediaDownloaded(String mediaId) {
    return _database?.isMediaDownloaded(mediaId) ?? false;
  }

  @override
  DownloadedMedia? getDownloadedMediaById(String mediaId) {
    return _database?.getMediaByMediaId(mediaId);
  }

  @override
  int getTotalStorageUsed() {
    return _database?.getTotalStorageUsed() ?? 0;
  }

  @override
  void dispose() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _progressController.close();

    // Clean up background service subscription
    _backgroundProgressSubscription?.cancel();
    _backgroundService?.dispose();
  }
}

/// Factory function to create a native download service with database.
/// This is used by the providers to properly wire up the database.
_NativeDownloadService createNativeDownloadService(
    _NativeDownloadDatabase database) {
  final service = _NativeDownloadService();
  service.setDatabase(database);
  return service;
}
