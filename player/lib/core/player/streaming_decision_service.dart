import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/streaming_candidate.dart';
import 'codec_support.dart';
import 'streaming_strategy.dart';

/// Result of a streaming decision
class StreamingDecision {
  /// Whether the decision was successful
  final bool success;

  /// The selected streaming strategy
  final StreamingStrategy? strategy;

  /// The selected candidate with full codec info
  final StreamingCandidate? candidate;

  /// Metadata about the source media
  final StreamingMetadata? metadata;

  /// Error message if unsuccessful
  final String? error;

  const StreamingDecision._({
    required this.success,
    this.strategy,
    this.candidate,
    this.metadata,
    this.error,
  });

  /// Create a successful decision
  factory StreamingDecision.success({
    required StreamingStrategy strategy,
    required StreamingCandidate candidate,
    required StreamingMetadata metadata,
  }) {
    return StreamingDecision._(
      success: true,
      strategy: strategy,
      candidate: candidate,
      metadata: metadata,
    );
  }

  /// Create an error decision
  factory StreamingDecision.error(String error) {
    return StreamingDecision._(
      success: false,
      error: error,
    );
  }

  @override
  String toString() {
    if (success) {
      return 'StreamingDecision.success(strategy: $strategy)';
    }
    return 'StreamingDecision.error($error)';
  }
}

/// Service to determine the optimal streaming strategy for a media file.
///
/// This service:
/// 1. Fetches streaming candidates from the server
/// 2. Tests each candidate for codec support on the current platform
/// 3. Returns the best supported strategy
///
/// Usage:
/// ```dart
/// final service = StreamingDecisionService(
///   serverUrl: 'https://mydia.example.com',
///   authToken: 'bearer-token',
/// );
///
/// final decision = await service.decideStrategy(
///   contentType: 'movie',
///   contentId: '123',
/// );
///
/// if (decision.success) {
///   final url = StreamingStrategyService.buildStreamUrl(
///     serverUrl: serverUrl,
///     fileId: fileId,
///     strategy: decision.strategy!,
///   );
///   // Use url for playback
/// }
/// ```
class StreamingDecisionService {
  final String serverUrl;
  final String authToken;
  final String? mediaToken;

  const StreamingDecisionService({
    required this.serverUrl,
    required this.authToken,
    this.mediaToken,
  });

  /// Fetch streaming candidates from the server.
  ///
  /// Parameters:
  ///   - contentType: 'movie', 'episode', or 'file'
  ///   - contentId: The ID of the content
  ///
  /// Returns the candidates response or throws on error.
  Future<StreamingCandidatesResponse> fetchCandidates({
    required String contentType,
    required String contentId,
  }) async {
    final url = '$serverUrl/api/v1/stream/$contentType/$contentId/candidates';
    debugPrint('Fetching streaming candidates from: $url');

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer $authToken',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      final jsonData = json.decode(response.body) as Map<String, dynamic>;
      return StreamingCandidatesResponse.fromJson(jsonData);
    } else {
      throw Exception(
        'Failed to fetch candidates: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Test if a streaming candidate is supported on this platform.
  ///
  /// Uses the candidate's MIME type to check browser/platform support.
  bool isCandidateSupported(StreamingCandidate candidate) {
    // TRANSCODE is always supported (guaranteed H.264/AAC output)
    if (candidate.strategy == StreamingStrategy.transcode) {
      return true;
    }

    // On native platforms, most formats are supported via FFmpeg
    if (CodecSupport.isNative) {
      return true;
    }

    // On web, check browser support for the MIME type
    return CodecSupport.isTypeSupported(candidate.mime);
  }

  /// Select the best streaming strategy from a list of candidates.
  ///
  /// Returns the first candidate that is supported on this platform.
  /// Candidates should already be in priority order from the server.
  StreamingCandidate? selectBestCandidate(List<StreamingCandidate> candidates) {
    for (final candidate in candidates) {
      if (isCandidateSupported(candidate)) {
        debugPrint(
          'Selected candidate: ${candidate.strategy.value} '
          '(mime: ${candidate.mime})',
        );
        return candidate;
      }
      debugPrint(
        'Candidate not supported: ${candidate.strategy.value} '
        '(mime: ${candidate.mime})',
      );
    }
    return null;
  }

  /// Decide the optimal streaming strategy for content.
  ///
  /// This fetches candidates from the server and selects the best one
  /// based on platform codec support.
  ///
  /// Parameters:
  ///   - contentType: 'movie', 'episode', or 'file'
  ///   - contentId: The ID of the content
  ///
  /// Returns a [StreamingDecision] with the selected strategy.
  Future<StreamingDecision> decideStrategy({
    required String contentType,
    required String contentId,
  }) async {
    try {
      // Fetch candidates from server
      final response = await fetchCandidates(
        contentType: contentType,
        contentId: contentId,
      );

      debugPrint(
        'Received ${response.candidates.length} streaming candidates',
      );

      // Select the best supported candidate
      final candidate = selectBestCandidate(response.candidates);

      if (candidate == null) {
        return StreamingDecision.error(
          'No supported streaming format found',
        );
      }

      return StreamingDecision.success(
        strategy: candidate.strategy,
        candidate: candidate,
        metadata: response.metadata,
      );
    } catch (e) {
      debugPrint('Error deciding streaming strategy: $e');
      return StreamingDecision.error(e.toString());
    }
  }

  /// Build the stream URL for the selected strategy.
  ///
  /// Convenience method that combines strategy selection with URL building.
  String buildStreamUrl({
    required String fileId,
    required StreamingStrategy strategy,
  }) {
    return StreamingStrategyService.buildStreamUrl(
      serverUrl: serverUrl,
      fileId: fileId,
      strategy: strategy,
      mediaToken: mediaToken,
    );
  }
}
