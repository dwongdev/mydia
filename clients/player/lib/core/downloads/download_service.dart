/// Abstract interface for download service.
///
/// This allows different implementations for web and native platforms.
/// Downloads are only supported on native platforms (iOS, Android, desktop).
/// On web, this provides a stub that reports downloads as unsupported.
library;

import 'dart:async';

import '../../domain/models/download.dart';
import 'download_service_stub.dart'
    if (dart.library.html) 'download_service_web.dart'
    if (dart.library.io) 'download_service_native.dart' as impl;

/// Get the platform-appropriate download service implementation.
DownloadService getDownloadService() => impl.getDownloadService();

/// Get the platform-appropriate download database implementation.
DownloadDatabase getDownloadDatabase() => impl.getDownloadDatabase();

/// Check if downloads are supported on the current platform.
bool get isDownloadSupported => impl.isDownloadSupported;

/// Abstract interface for the download database.
abstract class DownloadDatabase {
  Future<void> initialize();
  Future<void> saveTask(DownloadTask task);
  Future<void> deleteTask(String id);
  DownloadTask? getTask(String id);
  List<DownloadTask> getAllTasks();
  List<DownloadTask> getActiveTasks();
  List<DownloadTask> getCompletedTasks();
  Stream<dynamic> watchTasks();
  Future<void> clearCompletedTasks();
  Future<void> saveMedia(DownloadedMedia media);
  Future<void> deleteMedia(String id);
  DownloadedMedia? getMedia(String id);
  DownloadedMedia? getMediaByMediaId(String mediaId);
  bool isMediaDownloaded(String mediaId);
  List<DownloadedMedia> getAllMedia();
  Stream<dynamic> watchMedia();
  int getTotalStorageUsed();
  Future<void> clearAll();
  Future<void> close();
}

/// Abstract interface for the download service/manager.
abstract class DownloadService {
  Stream<DownloadTask> get progressStream;

  Future<DownloadTask> startDownload({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
    String? posterUrl,
    int? fileSize,
  });

  Future<void> pauseDownload(String taskId);
  Future<void> resumeDownload(String taskId);
  Future<void> cancelDownload(String taskId);
  Future<void> retryDownload(String taskId);
  Future<void> deleteDownload(String mediaId);
  List<DownloadTask> getActiveDownloads();
  List<DownloadedMedia> getDownloadedMedia();
  bool isMediaDownloaded(String mediaId);
  DownloadedMedia? getDownloadedMediaById(String mediaId);
  int getTotalStorageUsed();
  void dispose();
}
