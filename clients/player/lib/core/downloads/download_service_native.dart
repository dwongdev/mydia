/// Native implementation of download service.
///
/// This provides the full download functionality on iOS, Android, and desktop.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models/download.dart';
import '../../domain/models/download_adapters.dart';
import 'download_service.dart';

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
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

  void setDatabase(_NativeDownloadDatabase database) {
    _database = database;
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
    );

    await _database!.saveTask(task);
    _startDownloadTask(task);

    return task;
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
    } catch (e) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      _cancelTokens.remove(task.id);
    }
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    if (_database == null) return;

    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);

      final task = _database!.getTask(taskId);
      if (task != null) {
        final pausedTask = task.copyWith(status: 'paused');
        await _database!.saveTask(pausedTask);
        _progressController.add(pausedTask);
      }
    }
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task != null && task.status == 'paused') {
      await _startDownloadTask(task);
    }
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    if (_database == null) return;

    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);
    }

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
