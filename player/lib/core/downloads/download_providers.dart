import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download.dart';
import 'download_service.dart';

part 'download_providers.g.dart';

/// Whether downloads are supported on the current platform.
/// Returns false on web, true on native platforms.
@riverpod
bool downloadsSupported(Ref ref) {
  return isDownloadSupported;
}

@Riverpod(keepAlive: true)
DownloadDatabase downloadDatabase(Ref ref) {
  final database = getDownloadDatabase();
  ref.onDispose(() {
    database.close();
  });
  return database;
}

@Riverpod(keepAlive: true)
DownloadService downloadManager(Ref ref) {
  final service = getDownloadService();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
}

@riverpod
Stream<List<DownloadTask>> downloadQueue(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = ref.watch(downloadDatabaseProvider);
  final manager = ref.watch(downloadManagerProvider);

  // Emit initial state
  yield manager.getActiveDownloads();

  // Listen to database changes
  await for (final _ in database.watchTasks()) {
    yield manager.getActiveDownloads();
  }
}

@riverpod
Stream<List<DownloadedMedia>> downloadedMedia(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = ref.watch(downloadDatabaseProvider);
  final manager = ref.watch(downloadManagerProvider);

  // Emit initial state
  yield manager.getDownloadedMedia();

  // Listen to database changes
  await for (final _ in database.watchMedia()) {
    yield manager.getDownloadedMedia();
  }
}

@riverpod
Stream<int> storageUsage(Ref ref) async* {
  if (!isDownloadSupported) {
    yield 0;
    return;
  }

  final database = ref.watch(downloadDatabaseProvider);
  final manager = ref.watch(downloadManagerProvider);

  // Emit initial state
  yield manager.getTotalStorageUsed();

  // Listen to database changes
  await for (final _ in database.watchMedia()) {
    yield manager.getTotalStorageUsed();
  }
}

@riverpod
Stream<DownloadTask> downloadProgress(Ref ref) {
  final manager = ref.watch(downloadManagerProvider);
  return manager.progressStream;
}

@riverpod
bool isMediaDownloaded(Ref ref, String mediaId) {
  if (!isDownloadSupported) {
    return false;
  }

  final manager = ref.watch(downloadManagerProvider);
  return manager.isMediaDownloaded(mediaId);
}

@riverpod
DownloadedMedia? getDownloadedMediaById(Ref ref, String mediaId) {
  if (!isDownloadSupported) {
    return null;
  }

  final manager = ref.watch(downloadManagerProvider);
  return manager.getDownloadedMediaById(mediaId);
}
