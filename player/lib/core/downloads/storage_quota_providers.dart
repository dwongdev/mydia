/// Providers for storage quota management.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download.dart';
import '../../domain/models/storage_settings.dart';
import 'download_providers.dart';
import 'download_service.dart';

part 'storage_quota_providers.g.dart';

/// Box name for storage settings.
const String _storageSettingsBoxName = 'storage_settings';
const String _storageSettingsKey = 'settings';

/// Provider for storage settings box.
@Riverpod(keepAlive: true)
Future<Box<StorageSettings>> storageSettingsBox(Ref ref) async {
  // Register adapter if not already registered
  if (!Hive.isAdapterRegistered(2)) {
    Hive.registerAdapter(StorageSettingsAdapter());
  }
  return Hive.openBox<StorageSettings>(_storageSettingsBoxName);
}

/// Provider for current storage settings.
@riverpod
Future<StorageSettings> storageSettings(Ref ref) async {
  final box = await ref.watch(storageSettingsBoxProvider.future);
  return box.get(_storageSettingsKey) ?? StorageSettings.defaultSettings;
}

/// Provider to update storage settings.
@riverpod
Future<void> Function(StorageSettings) updateStorageSettings(Ref ref) {
  return (StorageSettings settings) async {
    final box = await ref.read(storageSettingsBoxProvider.future);
    await box.put(_storageSettingsKey, settings);
    // Invalidate the storage settings provider to trigger refresh
    ref.invalidate(storageSettingsProvider);
  };
}

/// Storage quota status information.
class StorageQuotaStatus {
  final int usedBytes;
  final int? maxBytes;
  final double usagePercentage;
  final bool isWarningExceeded;
  final bool isFull;
  final int remainingBytes;
  final StorageSettings settings;

  const StorageQuotaStatus({
    required this.usedBytes,
    required this.maxBytes,
    required this.usagePercentage,
    required this.isWarningExceeded,
    required this.isFull,
    required this.remainingBytes,
    required this.settings,
  });

  /// Format used bytes for display.
  String get usedDisplay => StorageSettings.formatBytes(usedBytes);

  /// Format max bytes for display.
  String get maxDisplay =>
      maxBytes != null ? StorageSettings.formatBytes(maxBytes!) : 'Unlimited';

  /// Format remaining bytes for display.
  String get remainingDisplay => remainingBytes >= 0
      ? StorageSettings.formatBytes(remainingBytes)
      : 'Unlimited';
}

/// Provider for storage quota status.
@riverpod
Future<StorageQuotaStatus> storageQuotaStatus(Ref ref) async {
  final usedBytes = await ref.watch(storageUsageProvider.future);
  final settings = await ref.watch(storageSettingsProvider.future);

  return StorageQuotaStatus(
    usedBytes: usedBytes,
    maxBytes: settings.maxStorageBytes,
    usagePercentage: settings.usagePercentage(usedBytes),
    isWarningExceeded: settings.isWarningThresholdExceeded(usedBytes),
    isFull: settings.isStorageFull(usedBytes),
    remainingBytes: settings.remainingBytes(usedBytes),
    settings: settings,
  );
}

/// Storage cleanup service.
class StorageCleanupService {
  final DownloadDatabase _database;
  final DownloadService _downloadService;

  StorageCleanupService(this._database, this._downloadService);

  /// Clean up downloads to free up space.
  ///
  /// [targetBytes] - Target number of bytes to free up
  /// [policy] - Cleanup policy (byDate or lru)
  ///
  /// Returns the number of bytes freed.
  Future<int> cleanup({
    required int targetBytes,
    required CleanupPolicy policy,
  }) async {
    final downloads = _database.getAllMedia();
    if (downloads.isEmpty) return 0;

    // Sort by policy
    final sorted = List<DownloadedMedia>.from(downloads);
    if (policy == CleanupPolicy.byDate) {
      // Oldest first
      sorted.sort((a, b) => a.downloadedAt.compareTo(b.downloadedAt));
    } else {
      // LRU - currently same as by date since we don't track access time
      // In a real implementation, you'd track last access time
      sorted.sort((a, b) => a.downloadedAt.compareTo(b.downloadedAt));
    }

    int freedBytes = 0;
    for (final download in sorted) {
      if (freedBytes >= targetBytes) break;

      await _downloadService.deleteDownload(download.mediaId);
      freedBytes += download.fileSize;
    }

    return freedBytes;
  }

  /// Get total bytes that can be cleaned up (all downloaded media).
  int getTotalCleanableBytes() {
    return _database.getTotalStorageUsed();
  }
}

/// Provider for storage cleanup service.
@riverpod
Future<StorageCleanupService> storageCleanupService(Ref ref) async {
  final database = await ref.watch(downloadDatabaseProvider.future);
  final downloadService = await ref.watch(downloadManagerProvider.future);
  return StorageCleanupService(database, downloadService);
}

/// Perform automatic cleanup if needed.
@riverpod
Future<int> performAutoCleanup(Ref ref, int requiredBytes) async {
  final settings = await ref.read(storageSettingsProvider.future);
  if (!settings.autoCleanupEnabled || !settings.hasLimit) {
    return 0;
  }

  final status = await ref.read(storageQuotaStatusProvider.future);
  final bytesToFree = (status.usedBytes + requiredBytes) - status.maxBytes!;

  if (bytesToFree <= 0) return 0;

  final cleanupService = await ref.read(storageCleanupServiceProvider.future);
  return cleanupService.cleanup(
    targetBytes: bytesToFree,
    policy: settings.cleanupPolicy,
  );
}
