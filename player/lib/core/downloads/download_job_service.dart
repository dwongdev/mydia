import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/models/download_option.dart';
import '../auth/media_token_service.dart';

/// Abstract interface for download job services.
///
/// Both HTTP and P2P implementations provide the same operations:
/// - Query available download quality options
/// - Prepare/start download transcode jobs
/// - Monitor job status and progress
/// - Cancel ongoing jobs
/// - Get download URLs
abstract class DownloadJobService {
  Future<DownloadOptionsResponse> getOptions(String contentType, String id);

  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  });

  Future<DownloadJobStatus> getJobStatus(String jobId);

  Future<void> cancelJob(String jobId);

  Future<String> getDownloadUrl(String jobId);
}

/// HTTP-based implementation of [DownloadJobService].
///
/// Routes all requests through the server's REST API over HTTP.
class HttpDownloadJobService implements DownloadJobService {
  final String _baseUrl;
  final String _authToken;
  final MediaTokenService _mediaTokenService;
  final http.Client _httpClient;

  HttpDownloadJobService({
    required String baseUrl,
    required String authToken,
    required MediaTokenService mediaTokenService,
    http.Client? httpClient,
  })  : _baseUrl = baseUrl,
        _authToken = authToken,
        _mediaTokenService = mediaTokenService,
        _httpClient = httpClient ?? http.Client();

  @override
  Future<DownloadOptionsResponse> getOptions(
      String contentType, String id) async {
    final url = Uri.parse('$_baseUrl/api/v1/download/$contentType/$id/options');

    final response = await _httpClient.get(
      url,
      headers: {
        'Authorization': 'Bearer $_authToken',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return DownloadOptionsResponse.fromJson(json);
    } else if (response.statusCode == 404) {
      throw DownloadServiceException('Media not found', statusCode: 404);
    } else {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final errorMsg = json['error'] as String? ?? 'Unknown error';
      throw DownloadServiceException(errorMsg, statusCode: response.statusCode);
    }
  }

  @override
  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  }) async {
    final url = Uri.parse('$_baseUrl/api/v1/download/$contentType/$id/prepare');

    final response = await _httpClient.post(
      url,
      headers: {
        'Authorization': 'Bearer $_authToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'resolution': resolution}),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return DownloadJobStatus.fromJson(json);
    } else if (response.statusCode == 404) {
      throw DownloadServiceException('Media not found', statusCode: 404);
    } else if (response.statusCode == 400) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final errorMsg = json['error'] as String? ?? 'Invalid resolution';
      throw DownloadServiceException(errorMsg, statusCode: 400);
    } else {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final errorMsg = json['error'] as String? ?? 'Failed to prepare download';
      throw DownloadServiceException(errorMsg, statusCode: response.statusCode);
    }
  }

  @override
  Future<DownloadJobStatus> getJobStatus(String jobId) async {
    final url = Uri.parse('$_baseUrl/api/v1/download/job/$jobId/status');

    final response = await _httpClient.get(
      url,
      headers: {
        'Authorization': 'Bearer $_authToken',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return DownloadJobStatus.fromJson(json);
    } else if (response.statusCode == 404) {
      throw DownloadServiceException('Job not found', statusCode: 404);
    } else {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final errorMsg = json['error'] as String? ?? 'Failed to get job status';
      throw DownloadServiceException(errorMsg, statusCode: response.statusCode);
    }
  }

  @override
  Future<void> cancelJob(String jobId) async {
    final url = Uri.parse('$_baseUrl/api/v1/download/job/$jobId');

    final response = await _httpClient.delete(
      url,
      headers: {
        'Authorization': 'Bearer $_authToken',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      return;
    } else if (response.statusCode == 404) {
      throw DownloadServiceException('Job not found', statusCode: 404);
    } else {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final errorMsg = json['error'] as String? ?? 'Failed to cancel job';
      throw DownloadServiceException(errorMsg, statusCode: response.statusCode);
    }
  }

  @override
  Future<String> getDownloadUrl(String jobId) async {
    // Ensure media token is valid and refreshed if needed
    await _mediaTokenService.ensureValidToken();

    // Build authenticated URL with media token
    final downloadUrl = await _mediaTokenService.buildMediaUrl(
        _baseUrl, '/api/v1/download/job/$jobId/file');

    return downloadUrl;
  }
}

/// Exception thrown by DownloadJobService operations.
class DownloadServiceException implements Exception {
  final String message;
  final int? statusCode;

  DownloadServiceException(this.message, {this.statusCode});

  @override
  String toString() =>
      'DownloadServiceException: $message (status: $statusCode)';
}
