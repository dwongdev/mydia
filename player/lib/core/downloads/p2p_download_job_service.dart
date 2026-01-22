import 'package:gql/language.dart' show printNode;

import '../../domain/models/download_option.dart';
import '../../graphql/mutations/download_options.graphql.dart';
import '../../graphql/mutations/prepare_download.graphql.dart';
import '../../graphql/mutations/download_job_status.graphql.dart';
import '../../graphql/mutations/cancel_download_job.graphql.dart';
import '../p2p/p2p_service.dart';
import 'download_job_service.dart';

/// P2P-aware download job service that uses GraphQL over P2P.
///
/// This class provides the same interface as [DownloadJobService] but
/// routes all requests through the P2P network instead of HTTP.
///
/// Uses the same GraphQL mutations as the regular GraphQL client,
/// ensuring consistency between HTTP and P2P transports.
class P2pDownloadJobService {
  final P2pService _p2pService;
  final String _serverNodeAddr;
  final String _authToken;

  P2pDownloadJobService({
    required P2pService p2pService,
    required String serverNodeAddr,
    required String authToken,
  })  : _p2pService = p2pService,
        _serverNodeAddr = serverNodeAddr,
        _authToken = authToken;

  // GraphQL query strings derived from generated document nodes
  // This ensures queries stay in sync with the .graphql files
  static final String _downloadOptionsQuery =
      printNode(documentNodeMutationDownloadOptions);
  static final String _prepareDownloadQuery =
      printNode(documentNodeMutationPrepareDownload);
  static final String _downloadJobStatusQuery =
      printNode(documentNodeMutationDownloadJobStatus);
  static final String _cancelDownloadJobQuery =
      printNode(documentNodeMutationCancelDownloadJob);

  /// Get available download quality options for a media item.
  ///
  /// [contentType] must be either "movie" or "episode"
  /// [id] is the media item ID (movie ID or episode ID)
  ///
  /// Returns a list of available quality options with estimated file sizes.
  Future<DownloadOptionsResponse> getOptions(String contentType, String id) async {
    final variables = {
      'contentType': contentType,
      'id': id,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _downloadOptionsQuery,
      variables: variables,
      operationName: 'DownloadOptions',
      authToken: _authToken,
    );

    final optionsData = result['downloadOptions'] as List<dynamic>?;
    if (optionsData == null) {
      throw DownloadServiceException('No options returned', statusCode: 400);
    }

    final options = optionsData.map((item) {
      final map = item as Map<String, dynamic>;
      return DownloadOption(
        resolution: map['resolution'] as String,
        label: map['label'] as String,
        estimatedSize: map['estimatedSize'] as int,
      );
    }).toList();

    return DownloadOptionsResponse(options: options);
  }

  /// Prepare a download by creating a transcode job.
  ///
  /// [contentType] must be either "movie" or "episode"
  /// [id] is the media item ID (movie ID or episode ID)
  /// [resolution] is the desired quality (e.g., "1080p", "720p", "480p")
  ///
  /// Returns the job status including job ID for tracking.
  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  }) async {
    final variables = {
      'contentType': contentType,
      'id': id,
      'resolution': resolution,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _prepareDownloadQuery,
      variables: variables,
      operationName: 'PrepareDownload',
      authToken: _authToken,
    );

    final prepareData = result['prepareDownload'] as Map<String, dynamic>?;
    if (prepareData == null) {
      throw DownloadServiceException('Failed to prepare download', statusCode: 500);
    }

    return DownloadJobStatus(
      jobId: prepareData['jobId'] as String,
      status: DownloadJobStatusType.fromString(prepareData['status'] as String),
      progress: (prepareData['progress'] as num).toDouble(),
      error: prepareData['error'] as String?,
      currentFileSize: prepareData['fileSize'] as int?,
    );
  }

  /// Get the current status of a transcode job.
  ///
  /// [jobId] is the unique job identifier returned from prepareDownload.
  ///
  /// Returns the current job status including progress, status, and any errors.
  Future<DownloadJobStatus> getJobStatus(String jobId) async {
    final variables = {
      'jobId': jobId,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _downloadJobStatusQuery,
      variables: variables,
      operationName: 'DownloadJobStatus',
      authToken: _authToken,
    );

    final statusData = result['downloadJobStatus'] as Map<String, dynamic>?;
    if (statusData == null) {
      throw DownloadServiceException('Job not found', statusCode: 404);
    }

    return DownloadJobStatus(
      jobId: statusData['jobId'] as String,
      status: DownloadJobStatusType.fromString(statusData['status'] as String),
      progress: (statusData['progress'] as num).toDouble(),
      error: statusData['error'] as String?,
      currentFileSize: statusData['fileSize'] as int?,
    );
  }

  /// Cancel a transcode job.
  ///
  /// [jobId] is the unique job identifier to cancel.
  ///
  /// This will stop the transcode process and delete the job record.
  Future<void> cancelJob(String jobId) async {
    final variables = {
      'jobId': jobId,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _cancelDownloadJobQuery,
      variables: variables,
      operationName: 'CancelDownloadJob',
      authToken: _authToken,
    );

    final cancelData = result['cancelDownloadJob'] as Map<String, dynamic>?;
    if (cancelData == null || cancelData['success'] != true) {
      throw DownloadServiceException('Failed to cancel job', statusCode: 500);
    }
  }

  /// Request a blob download ticket for a completed transcode job.
  ///
  /// [jobId] is the unique job identifier.
  ///
  /// Returns a map containing:
  /// - `ticket`: JSON string to pass to downloadBlob
  /// - `filename`: Suggested filename
  /// - `fileSize`: Size in bytes
  Future<Map<String, dynamic>> requestBlobTicket(String jobId) async {
    final result = await _p2pService.requestBlobDownload(
      peer: _serverNodeAddr,
      jobId: jobId,
      authToken: _authToken,
    );

    if (result['success'] != true) {
      throw DownloadServiceException(
        result['error'] as String? ?? 'Failed to get download ticket',
        statusCode: 500,
      );
    }

    return result;
  }

  /// Download a file using a blob ticket over P2P.
  ///
  /// [ticket] - The ticket JSON from [requestBlobTicket]
  /// [outputPath] - Where to save the downloaded file
  /// [onProgress] - Optional callback for progress updates (downloaded, total)
  Future<void> downloadBlob({
    required String ticket,
    required String outputPath,
    void Function(int downloaded, int total)? onProgress,
  }) async {
    await _p2pService.downloadBlob(
      peer: _serverNodeAddr,
      ticket: ticket,
      outputPath: outputPath,
      authToken: _authToken,
      onProgress: onProgress,
    );
  }

  /// Whether this service supports P2P blob download.
  bool get supportsBlobDownload => true;
}
