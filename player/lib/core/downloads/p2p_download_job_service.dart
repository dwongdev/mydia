import 'package:gql/language.dart' show printNode;

import '../../domain/models/download_option.dart';
import '../../graphql/mutations/download_options.graphql.dart';
import '../../graphql/mutations/prepare_download.graphql.dart';
import '../../graphql/mutations/download_job_status.graphql.dart';
import '../../graphql/mutations/cancel_download_job.graphql.dart';
import '../p2p/local_proxy_service.dart';
import '../p2p/p2p_service.dart';
import 'download_job_service.dart';

/// P2P-aware download job service that uses GraphQL over P2P.
///
/// This class implements [DownloadJobService] and routes all job management
/// requests through the P2P network via GraphQL. File downloads are served
/// through the local HTTP proxy, making them compatible with Dio/Range requests.
class P2pDownloadJobService implements DownloadJobService {
  final P2pService _p2pService;
  final LocalProxyService _localProxy;
  final String _serverNodeAddr;
  final String _authToken;

  P2pDownloadJobService({
    required P2pService p2pService,
    required LocalProxyService localProxy,
    required String serverNodeAddr,
    required String authToken,
  })  : _p2pService = p2pService,
        _localProxy = localProxy,
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

  @override
  Future<DownloadOptionsResponse> getOptions(
      String contentType, String id) async {
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

  @override
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
      throw DownloadServiceException('Failed to prepare download',
          statusCode: 500);
    }

    return DownloadJobStatus(
      jobId: prepareData['jobId'] as String,
      status: DownloadJobStatusType.fromString(prepareData['status'] as String),
      progress: (prepareData['progress'] as num).toDouble(),
      error: prepareData['error'] as String?,
      currentFileSize: prepareData['fileSize'] as int?,
    );
  }

  @override
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

  @override
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

  @override
  Future<String> getDownloadUrl(String jobId) async {
    final port = _localProxy.port;
    if (port == 0) {
      throw StateError('Local proxy is not running');
    }
    return 'http://127.0.0.1:$port/download/$jobId/file';
  }
}
