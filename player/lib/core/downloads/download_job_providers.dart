import 'dart:async';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download_option.dart';
import '../graphql/graphql_provider.dart';
import 'download_job_service.dart';

part 'download_job_providers.g.dart';

/// Provider for the DownloadJobService instance.
///
/// Returns null if authentication is not available.
@riverpod
DownloadJobService? downloadJobService(Ref ref) {
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final authTokenAsync = ref.watch(authTokenProvider);
  final mediaTokenService = ref.watch(mediaTokenServiceProvider);

  if (mediaTokenService == null) {
    return null;
  }

  return serverUrlAsync.when(
    data: (serverUrl) {
      if (serverUrl == null) return null;

      return authTokenAsync.when(
        data: (authToken) {
          if (authToken == null) return null;

          return DownloadJobService(
            baseUrl: serverUrl,
            authToken: authToken,
            mediaTokenService: mediaTokenService,
          );
        },
        loading: () => null,
        error: (_, __) => null,
      );
    },
    loading: () => null,
    error: (_, __) => null,
  );
}

/// Provider for fetching download quality options.
///
/// [contentType] must be either "movie" or "episode"
/// [id] is the media item ID (movie ID or episode ID)
///
/// Returns available quality options with estimated file sizes.
@riverpod
Future<DownloadOptionsResponse> downloadOptions(
  Ref ref,
  String contentType,
  String id,
) async {
  final service = ref.watch(downloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  return await service.getOptions(contentType, id);
}

/// Provider for monitoring download job status with auto-polling.
///
/// [jobId] is the unique job identifier.
///
/// Automatically polls for status updates every 2 seconds while job is in progress.
/// Stops polling once job is complete (ready or failed).
@riverpod
Stream<DownloadJobStatus> downloadJobStatus(
  Ref ref,
  String jobId,
) async* {
  final service = ref.watch(downloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  // Poll for status updates
  const pollInterval = Duration(seconds: 2);
  DownloadJobStatus? lastStatus;

  while (true) {
    try {
      final status = await service.getJobStatus(jobId);

      // Yield new status
      yield status;
      lastStatus = status;

      // Stop polling if job is complete
      if (status.isComplete) {
        break;
      }

      // Wait before next poll
      await Future.delayed(pollInterval);
    } catch (e) {
      // If we had a previous status, we can continue with that
      if (lastStatus != null) {
        // Job might have been deleted/cancelled, treat as complete
        if (e is DownloadServiceException && e.statusCode == 404) {
          break;
        }
      }
      rethrow;
    }
  }
}

/// Provider for preparing a download job.
///
/// This is a family provider that can be used to initiate download preparation.
/// Use `ref.refresh()` to start a new preparation.
@riverpod
Future<DownloadJobStatus> prepareDownload(
  Ref ref, {
  required String contentType,
  required String id,
  required String resolution,
}) async {
  final service = ref.watch(downloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  return await service.prepareDownload(
    contentType: contentType,
    id: id,
    resolution: resolution,
  );
}

/// Provider for getting authenticated download URL.
///
/// [jobId] is the unique job identifier.
///
/// Returns a URL with authentication token that can be used to download the file.
@riverpod
Future<String> downloadUrl(Ref ref, String jobId) async {
  final service = ref.watch(downloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  return await service.getDownloadUrl(jobId);
}

/// Provider for canceling a download job.
///
/// This is not a typical provider pattern - instead, create a notifier
/// or use the service directly for cancellation actions.
/// Kept here for reference but typically you'd call service.cancelJob() directly.
