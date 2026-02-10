import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download.dart';
import 'download_service.dart';

import 'download_job_providers.dart';

part 'download_providers.g.dart';

/// Whether downloads are supported on the current platform.
/// Returns false on web, true on native platforms.
@riverpod
bool downloadsSupported(Ref ref) {
  return isDownloadSupported;
}

@Riverpod(keepAlive: true)
Future<DownloadDatabase> downloadDatabase(Ref ref) async {
  final database = getDownloadDatabase();
  await database.initialize();
  ref.onDispose(() {
    database.close();
  });
  return database;
}

@Riverpod(keepAlive: true)
Future<DownloadService> downloadManager(Ref ref) async {
  final database = await ref.watch(downloadDatabaseProvider.future);
  final service = getDownloadService();
  service.setDatabase(database);

  // Inject unified job service (works for both HTTP and P2P modes)
  final jobService = ref.watch(unifiedDownloadJobServiceProvider);
  if (jobService != null) {
    service.setJobService(jobService);
  }

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

  final database = await ref.watch(downloadDatabaseProvider.future);
  await ref.watch(downloadManagerProvider.future);

  // Emit initial active/queued tasks (exclude failed and completed)
  yield _getActiveTasks(database);

  // Listen to database changes and emit latest tasks
  await for (final _ in database.watchTasks()) {
    yield _getActiveTasks(database);
  }
}

/// Returns only active tasks (not failed, completed, or cancelled).
List<DownloadTask> _getActiveTasks(DownloadDatabase database) {
  return database
      .getAllTasks()
      .where((t) =>
          t.status != 'failed' &&
          t.status != 'completed' &&
          t.status != 'cancelled')
      .toList();
}

@riverpod
Stream<List<DownloadedMedia>> downloadedMedia(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = await ref.watch(downloadDatabaseProvider.future);
  final manager = await ref.watch(downloadManagerProvider.future);

  // Emit current downloaded media
  yield manager.getDownloadedMedia();

  // Listen to database changes and emit downloaded media
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

  final database = await ref.watch(downloadDatabaseProvider.future);
  final manager = await ref.watch(downloadManagerProvider.future);

  // Emit initial state
  yield manager.getTotalStorageUsed();

  // Listen to database changes
  await for (final _ in database.watchMedia()) {
    yield manager.getTotalStorageUsed();
  }
}

@riverpod
Stream<DownloadTask> downloadProgress(Ref ref) async* {
  final manager = await ref.watch(downloadManagerProvider.future);
  yield* manager.progressStream;
}

/// Provider for failed download tasks.
/// Returns tasks with 'failed' status, sorted by most recent first.
@riverpod
Stream<List<DownloadTask>> failedDownloads(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = await ref.watch(downloadDatabaseProvider.future);

  // Emit initial failed tasks
  yield _getFailedTasks(database);

  // Listen to database changes and emit failed tasks
  await for (final _ in database.watchTasks()) {
    yield _getFailedTasks(database);
  }
}

List<DownloadTask> _getFailedTasks(DownloadDatabase database) {
  return database.getAllTasks().where((t) => t.status == 'failed').toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

@riverpod
Future<bool> isMediaDownloaded(Ref ref, String mediaId) async {
  if (!isDownloadSupported) {
    return false;
  }

  final manager = await ref.watch(downloadManagerProvider.future);
  return manager.isMediaDownloaded(mediaId);
}

@riverpod
Future<DownloadedMedia?> getDownloadedMediaById(Ref ref, String mediaId) async {
  if (!isDownloadSupported) {
    return null;
  }

  final manager = await ref.watch(downloadManagerProvider.future);
  return manager.getDownloadedMediaById(mediaId);
}
