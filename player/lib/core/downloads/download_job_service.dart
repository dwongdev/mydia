import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/models/download_option.dart';
import '../auth/media_token_service.dart';

/// Service for managing download jobs and transcode operations.
///
/// Provides methods to:
/// - Query available download quality options
/// - Prepare/start download transcode jobs
/// - Monitor job status and progress
/// - Cancel ongoing jobs
/// - Get authenticated download URLs
class DownloadJobService {
  final String _baseUrl;
  final String _authToken;
  final MediaTokenService _mediaTokenService;
  final http.Client _httpClient;

  DownloadJobService({
    required String baseUrl,
    required String authToken,
    required MediaTokenService mediaTokenService,
    http.Client? httpClient,
  })  : _baseUrl = baseUrl,
        _authToken = authToken,
        _mediaTokenService = mediaTokenService,
        _httpClient = httpClient ?? http.Client();

  /// Get available download quality options for a media item.
  ///
  /// [contentType] must be either "movie" or "episode"
  /// [id] is the media item ID (movie ID or episode ID)
  ///
  /// Returns a list of available quality options with estimated file sizes.
  Future<DownloadOptionsResponse> getOptions(String contentType, String id) async {
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

  /// Prepare a download by creating a transcode job.
  ///
  /// [contentType] must be either "movie" or "episode"
  /// [id] is the media item ID (movie ID or episode ID)
  /// [resolution] is the desired quality (e.g., "1080p", "720p", "480p")
  ///
  /// Returns the job status including job ID for tracking.
  /// If a job already exists for this media/resolution, returns existing job status.
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

  /// Get the current status of a transcode job.
  ///
  /// [jobId] is the unique job identifier returned from prepareDownload.
  ///
  /// Returns the current job status including progress, status, and any errors.
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

  /// Cancel a transcode job.
  ///
  /// [jobId] is the unique job identifier to cancel.
  ///
  /// This will stop the transcode process and delete the job record.
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

  /// Get the authenticated download URL for a completed job.
  ///
  /// [jobId] is the unique job identifier.
  ///
  /// Returns a URL that includes the media authentication token for downloading
  /// the transcoded file. The URL is valid for the lifetime of the media token.
  Future<String> getDownloadUrl(String jobId) async {
    // Ensure media token is valid and refreshed if needed
    await _mediaTokenService.ensureValidToken();

    // Build authenticated URL with media token
    final downloadUrl = await _mediaTokenService.buildMediaUrl(_baseUrl, '/api/v1/download/job/$jobId/file');

    return downloadUrl;
  }
}

/// Exception thrown by DownloadJobService operations.
class DownloadServiceException implements Exception {
  final String message;
  final int? statusCode;

  DownloadServiceException(this.message, {this.statusCode});

  @override
  String toString() => 'DownloadServiceException: $message (status: $statusCode)';
}
