import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import '../../../core/auth/auth_status.dart';
import '../../../core/connection/connection_provider.dart' as conn;
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/player/progress_service.dart';
import '../../../core/utils/file_utils.dart' as file_utils;
import '../../../core/utils/web_lifecycle.dart' as web_lifecycle;
import '../../../core/player/platform_features.dart';
import '../../../core/player/duration_override.dart';
import '../../../core/player/streaming_strategy.dart';
import '../../../core/cast/cast_providers.dart';
import '../../../core/downloads/download_providers.dart';
import '../../widgets/resume_dialog.dart';
import '../../widgets/subtitle_track_selector.dart';
import '../../widgets/track_settings_overlay.dart';
import '../../widgets/hls_quality_selector.dart';
import '../../widgets/gesture_controls.dart';
import '../../widgets/cast_device_picker.dart';
import '../../widgets/airplay_button.dart';
import '../../widgets/video_controls/glassmorphic_video_controls.dart';
import '../../widgets/up_next_overlay.dart';
import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../../domain/models/cast_device.dart';
import '../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/mutations/start_streaming_session.graphql.dart';
import '../../../graphql/mutations/end_streaming_session.graphql.dart';
import '../../../graphql/queries/streaming_candidates.graphql.dart';
import '../../../graphql/schema.graphql.dart';
import '../../../core/p2p/local_proxy_service.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final String mediaId;
  final String mediaType;
  final String fileId;
  final String? title;
  final String? showId;
  final int? seasonNumber;

  const PlayerScreen({
    super.key,
    required this.mediaId,
    required this.mediaType,
    required this.fileId,
    this.title,
    this.showId,
    this.seasonNumber,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  /// Minimum position (in seconds) to show the resume dialog.
  /// If playback position is less than this, start from beginning.
  static const _minResumeThresholdSeconds = 30;

  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;
  StreamSubscription<Duration>? _positionSubscription;
  bool _isLoading = true;
  String? _error;
  String? _loadingMessage;
  int? _savedPositionSeconds;
  List<Query$SeasonEpisodes$seasonEpisodes>? _seasonEpisodes;
  int? _currentEpisodeIndex;

  // Track selection state
  List<app_models.SubtitleTrack> _subtitleTracks = [];
  app_models.SubtitleTrack? _selectedSubtitleTrack;

  // HLS quality selection (web only)
  HlsQualityLevel _selectedQuality = HlsQualityLevel.auto;

  // HLS session tracking for cleanup
  String? _hlsSessionId;
  String? _serverUrl;
  String? _authToken;

  // Total duration from server (for HLS streams where playlist duration is incomplete)
  Duration? _totalDuration;

  // Desktop feature state
  final FocusNode _focusNode = FocusNode();
  DateTime? _lastClickTime;

  // Auto-play next episode state
  bool _showUpNext = false;
  int _autoPlayCountdown = 10;
  bool _autoPlayCancelled = false;
  Timer? _upNextTimer;
  static const _autoPlayCountdownDuration = 10;

  // P2P mode state
  bool _isP2PMode = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();

    // Register beforeunload handler for web to terminate HLS session on tab close
    if (kIsWeb) {
      web_lifecycle.registerBeforeUnload(_terminateHlsSession);
    }
  }

  Future<void> _initializePlayer() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      // Check if we're in offline mode
      final authState = ref.read(authStateProvider);
      final isOfflineMode = authState.maybeWhen(
        data: (status) => status == AuthStatus.offlineMode,
        orElse: () => false,
      );

      // Check for downloaded content first (before any network operations)
      final downloadManager = await ref.read(downloadManagerProvider.future);
      final downloadedMedia =
          downloadManager.getDownloadedMediaById(widget.mediaId);

      // In offline mode, only downloaded content can be played
      if (isOfflineMode) {
        if (downloadedMedia == null || kIsWeb) {
          setState(() {
            _error =
                'This content is not available offline. Download it first to watch without a connection.';
            _isLoading = false;
          });
          return;
        }

        if (!await file_utils.fileExists(downloadedMedia.filePath)) {
          setState(() {
            _error =
                'Downloaded file not found. Please re-download the content.';
            _isLoading = false;
          });
          return;
        }

        // Play downloaded content in offline mode
        await _initializeOfflinePlayback(downloadedMedia.filePath);
        return;
      }

      // Online mode - initialize network services
      // Wait for auth to be ready using async provider
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);

      // Get server URL and token (they should be available now since client is ready)
      final serverUrl = await ref.read(serverUrlProvider.future);
      final token = await ref.read(authTokenProvider.future);

      if (serverUrl == null || token == null) {
        if (mounted) {
          setState(() {
            _error = 'Server URL or authentication token not available';
            _isLoading = false;
          });
        }
        return;
      }

      // Check if we're in P2P mode
      final connectionState = ref.read(conn.connectionProvider);
      if (connectionState.isP2PMode) {
        debugPrint(
            '[PlayerScreen] Detected P2P mode, initializing P2P playback');
        _isP2PMode = true;
        await _initializeP2PPlayback(connectionState, graphqlClient, token);
        return;
      }

      // Store for session cleanup
      _serverUrl = serverUrl;
      _authToken = token;

      // Get media token service for media access
      final mediaTokenService =
          await ref.read(asyncMediaTokenServiceProvider.future);

      // Ensure media token is valid and refreshed if needed
      await mediaTokenService.ensureValidToken();

      // Initialize progress service
      _progressService = ProgressService(graphqlClient);

      // Fetch saved progress and episode list for TV shows
      await _fetchProgressAndEpisodes(graphqlClient);

      // Create media_kit player
      _player = Player();
      _videoController = VideoController(_player!);

      String mediaSource;
      Map<String, String> httpHeaders = {};

      if (downloadedMedia != null && !kIsWeb) {
        // Use local file for offline playback (not supported on web)
        if (await file_utils.fileExists(downloadedMedia.filePath)) {
          debugPrint('Playing from local file: ${downloadedMedia.filePath}');
          mediaSource = downloadedMedia.filePath;
        } else {
          // File doesn't exist, fall back to streaming
          debugPrint('Downloaded file not found, falling back to streaming');
          final streamUrl =
              '$serverUrl/api/v1/stream/file/${widget.fileId}?strategy=DIRECT_PLAY';
          mediaSource = streamUrl;
          httpHeaders = {
            'Authorization': 'Bearer $token',
          };
        }
      } else {
        // Determine optimal streaming strategy based on platform
        final strategy = StreamingStrategyService.getOptimalStrategy();

        // Get media token for URL (if available)
        final mediaToken = await mediaTokenService.getToken();

        final streamUrl = StreamingStrategyService.buildStreamUrl(
          serverUrl: serverUrl,
          fileId: widget.fileId,
          strategy: strategy,
          mediaToken: mediaToken,
        );

        debugPrint(
            'Initializing video player with URL: $streamUrl (strategy: ${strategy.value})');

        // For HLS strategies, follow redirect and wait for playlist to be ready
        if (strategy == StreamingStrategy.hlsCopy ||
            strategy == StreamingStrategy.transcode) {
          if (mounted) {
            setState(() {
              _loadingMessage = 'Starting stream...';
            });
          }

          // Get the HLS playlist URL from the server
          final hlsUrl = await _getHlsPlaylistUrl(
            streamUrl,
            mediaToken != null ? {} : {'Authorization': 'Bearer $token'},
          );

          if (hlsUrl != null && hlsUrl.contains('.m3u8')) {
            debugPrint('HLS playlist URL: $hlsUrl');

            // Extract session ID for cleanup (URL format: /api/v1/hls/{session_id}/index.m3u8)
            _hlsSessionId = _extractSessionIdFromHlsUrl(hlsUrl);
            if (_hlsSessionId != null) {
              debugPrint('HLS session ID: $_hlsSessionId');
            }

            // Wait for playlist to be ready with enough segments
            await _waitForPlaylist(hlsUrl, token);

            mediaSource = hlsUrl;
            // HLS URLs don't need auth headers - token is in URL or handled by cookies
          } else {
            // Server didn't redirect to HLS, use original URL
            debugPrint('No HLS redirect, using original URL');
            mediaSource = streamUrl;
            if (mediaToken == null) {
              httpHeaders = {'Authorization': 'Bearer $token'};
            }
          }
        } else {
          mediaSource = streamUrl;

          // Only set Authorization header if no media token (direct mode)
          if (mediaToken == null) {
            httpHeaders = {
              'Authorization': 'Bearer $token',
            };
          }
        }
      }

      if (mounted) {
        setState(() {
          _loadingMessage = null;
        });
      }

      // Open media with media_kit
      await _player!.open(
        Media(mediaSource, httpHeaders: httpHeaders),
        play: false,
      );

      // Wait for player to be ready (get duration info)
      // In media_kit, we listen to the stream for duration updates
      await Future.delayed(const Duration(milliseconds: 500));

      // Check if we should show resume dialog
      // Only show if we have valid duration and saved position
      final duration = _player!.state.duration.inSeconds;
      final savedPosition = _savedPositionSeconds;
      if (mounted &&
          savedPosition != null &&
          savedPosition > _minResumeThresholdSeconds &&
          duration > 0) {
        final shouldResume = await showResumeDialog(
          context,
          savedPosition,
          duration,
        );

        if (shouldResume == true) {
          await _player!.seek(Duration(seconds: savedPosition));
        }
      }

      // Start playback
      await _player!.play();

      // Start progress tracking
      if (widget.mediaType == 'movie') {
        _progressService!.startMovieSync(_player!, widget.mediaId);
      } else if (widget.mediaType == 'episode') {
        _progressService!.startEpisodeSync(_player!, widget.mediaId);
      }

      // Listen for playback completion to mark as watched
      // Cancel any existing subscription before creating a new one
      await _positionSubscription?.cancel();
      _positionSubscription = _player!.stream.position.listen((_) {
        _onPlaybackProgress();
      });

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      // Subtitle tracks are now extracted from GraphQL in _fetchProgressAndEpisodes
      debugPrint(
          'Loaded ${_subtitleTracks.length} subtitle tracks from GraphQL');
    } catch (e) {
      debugPrint('Error initializing player: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// Initialize P2P playback using iroh and local proxy.
  ///
  /// Uses the candidates API to determine the optimal strategy:
  /// - Direct play (DIRECT_PLAY/REMUX/HLS_COPY on native): stream raw file over P2P
  /// - Transcode: fall back to HLS transcoding over P2P
  Future<void> _initializeP2PPlayback(
    conn.ConnectionState connectionState,
    GraphQLClient graphqlClient,
    String token,
  ) async {
    try {
      // Get server node address from connection state
      final serverNodeAddr = connectionState.serverNodeAddr;
      if (serverNodeAddr == null) {
        throw Exception('Server node address not available for P2P connection');
      }

      // Store auth token for session cleanup
      _authToken = token;

      // Start local proxy service
      if (mounted) {
        setState(() {
          _loadingMessage = 'Connecting via P2P...';
        });
      }

      final localProxyService = ref.read(localProxyServiceProvider);
      await localProxyService.start(
        targetPeer: serverNodeAddr,
        authToken: token,
      );

      debugPrint(
          '[PlayerScreen] Local proxy started on port ${localProxyService.port}');

      // Fetch streaming candidates to determine optimal strategy
      if (mounted) {
        setState(() {
          _loadingMessage = 'Checking file compatibility...';
        });
      }

      final contentType = widget.mediaType == 'movie' ? 'movie' : 'episode';
      final candidatesResult = await _fetchStreamingCandidates(
        graphqlClient,
        contentType,
        widget.mediaId,
      );

      if (candidatesResult != null &&
          _canDirectPlay(candidatesResult.candidates)) {
        // Direct play: stream the raw file over P2P (no HLS session needed)
        await _initializeP2PDirectPlayback(
          localProxyService,
          graphqlClient,
          candidatesResult,
        );
      } else {
        // Fall back to HLS transcoding over P2P
        debugPrint('[PlayerScreen] Using HLS fallback for P2P playback');
        await _initializeP2PHlsPlayback(
          localProxyService,
          graphqlClient,
        );
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Error initializing P2P playback: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to start P2P playback: $e';
          _isLoading = false;
          _loadingMessage = null;
        });
      }
    }
  }

  /// Check if the first candidate supports direct play on native.
  ///
  /// On native desktop, FFmpeg handles virtually all codecs/containers,
  /// so DIRECT_PLAY, REMUX, and HLS_COPY are all direct-playable.
  bool _canDirectPlay(
    List<Query$StreamingCandidates$streamingCandidates$candidates> candidates,
  ) {
    if (candidates.isEmpty) return false;

    final first = candidates.first;
    // On native desktop, FFmpeg can handle any format directly
    return first.strategy == Enum$StreamingCandidateStrategy.DIRECT_PLAY ||
        first.strategy == Enum$StreamingCandidateStrategy.REMUX ||
        first.strategy == Enum$StreamingCandidateStrategy.HLS_COPY;
  }

  /// Fetch streaming candidates from the server via GraphQL.
  Future<Query$StreamingCandidates$streamingCandidates?>
      _fetchStreamingCandidates(
    GraphQLClient graphqlClient,
    String contentType,
    String id,
  ) async {
    try {
      final result = await graphqlClient.query(
        QueryOptions(
          document: documentNodeQueryStreamingCandidates,
          variables: Variables$Query$StreamingCandidates(
            contentType: contentType,
            id: id,
          ).toJson(),
        ),
      );

      if (result.hasException) {
        debugPrint(
            '[PlayerScreen] Failed to fetch candidates: ${result.exception}');
        return null;
      }

      final data = Query$StreamingCandidates.fromJson(result.data!);
      return data.streamingCandidates;
    } catch (e) {
      debugPrint('[PlayerScreen] Error fetching streaming candidates: $e');
      return null;
    }
  }

  /// Initialize direct P2P playback (no HLS transcoding).
  ///
  /// Streams the raw file over the P2P connection via the local proxy.
  Future<void> _initializeP2PDirectPlayback(
    LocalProxyService localProxyService,
    GraphQLClient graphqlClient,
    Query$StreamingCandidates$streamingCandidates candidatesResult,
  ) async {
    if (mounted) {
      setState(() {
        _loadingMessage = 'Starting direct playback...';
      });
    }

    final fileId = candidatesResult.fileId;
    debugPrint('[PlayerScreen] P2P direct play for file_id=$fileId');

    // Set total duration from candidates metadata
    final duration = candidatesResult.metadata.duration;
    if (duration != null) {
      _totalDuration = Duration(
        milliseconds: (duration * 1000).round(),
      );
      DurationOverride.value = _totalDuration;
      debugPrint(
          '[PlayerScreen] Total duration from candidates: $_totalDuration');
    }

    // Build direct stream URL via local proxy
    // No HLS session ID needed — the "direct:{fileId}" convention handles it
    final directUrl = localProxyService.buildDirectStreamUrl(fileId);
    debugPrint('[PlayerScreen] P2P direct URL: $directUrl');

    // Initialize progress service
    _progressService = ProgressService(graphqlClient);

    // Fetch saved progress and episode list for TV shows
    await _fetchProgressAndEpisodes(graphqlClient);

    // Create media_kit player
    _player = Player();
    _videoController = VideoController(_player!);

    // Open media with media_kit (no auth headers needed for local proxy)
    await _player!.open(
      Media(directUrl),
      play: false,
    );

    // Wait for player to be ready
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if we should show resume dialog
    final playerDuration = _player!.state.duration.inSeconds;
    final savedPosition = _savedPositionSeconds;
    if (mounted &&
        savedPosition != null &&
        savedPosition > _minResumeThresholdSeconds &&
        playerDuration > 0) {
      final shouldResume = await showResumeDialog(
        context,
        savedPosition,
        playerDuration,
      );

      if (shouldResume == true) {
        await _player!.seek(Duration(seconds: savedPosition));
      }
    }

    // Start playback
    await _player!.play();

    // Start progress tracking
    if (widget.mediaType == 'movie') {
      _progressService!.startMovieSync(_player!, widget.mediaId);
    } else if (widget.mediaType == 'episode') {
      _progressService!.startEpisodeSync(_player!, widget.mediaId);
    }

    // Listen for playback completion
    await _positionSubscription?.cancel();
    _positionSubscription = _player!.stream.position.listen((_) {
      _onPlaybackProgress();
    });

    if (mounted) {
      setState(() {
        _isLoading = false;
        _loadingMessage = null;
      });
    }

    debugPrint('[PlayerScreen] P2P direct playback initialized successfully');
  }

  /// Initialize HLS P2P playback (transcoding fallback).
  Future<void> _initializeP2PHlsPlayback(
    LocalProxyService localProxyService,
    GraphQLClient graphqlClient,
  ) async {
    if (mounted) {
      setState(() {
        _loadingMessage = 'Starting stream...';
      });
    }

    // Start HLS streaming session via GraphQL
    final result = await graphqlClient.mutate(
      MutationOptions(
        document: documentNodeMutationStartStreamingSession,
        variables: Variables$Mutation$StartStreamingSession(
          fileId: widget.fileId,
          strategy: Enum$StreamingStrategy.TRANSCODE,
        ).toJson(),
      ),
    );

    if (result.hasException) {
      throw Exception('Failed to start streaming session: ${result.exception}');
    }

    final sessionData = Mutation$StartStreamingSession.fromJson(result.data!);
    final sessionResult = sessionData.startStreamingSession;
    if (sessionResult == null) {
      throw Exception('No session data returned from server');
    }

    _hlsSessionId = sessionResult.sessionId;
    debugPrint('[PlayerScreen] P2P HLS session started: $_hlsSessionId');

    // Set total duration if provided
    if (sessionResult.duration != null) {
      _totalDuration = Duration(
        milliseconds: (sessionResult.duration! * 1000).round(),
      );
      DurationOverride.value = _totalDuration;
      debugPrint('[PlayerScreen] Total duration from server: $_totalDuration');
    }

    // Build HLS URL via local proxy
    final hlsUrl = localProxyService.buildHlsUrl(_hlsSessionId!);
    debugPrint('[PlayerScreen] P2P HLS URL: $hlsUrl');

    // Wait for playlist to be ready
    await _waitForP2PPlaylist(hlsUrl);

    // Initialize progress service
    _progressService = ProgressService(graphqlClient);

    // Fetch saved progress and episode list for TV shows
    await _fetchProgressAndEpisodes(graphqlClient);

    // Create media_kit player
    _player = Player();
    _videoController = VideoController(_player!);

    // Open media with media_kit (no auth headers needed for local proxy)
    await _player!.open(
      Media(hlsUrl),
      play: false,
    );

    // Wait for player to be ready
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if we should show resume dialog
    final duration = _player!.state.duration.inSeconds;
    final savedPosition = _savedPositionSeconds;
    if (mounted &&
        savedPosition != null &&
        savedPosition > _minResumeThresholdSeconds &&
        duration > 0) {
      final shouldResume = await showResumeDialog(
        context,
        savedPosition,
        duration,
      );

      if (shouldResume == true) {
        await _player!.seek(Duration(seconds: savedPosition));
      }
    }

    // Start playback
    await _player!.play();

    // Start progress tracking
    if (widget.mediaType == 'movie') {
      _progressService!.startMovieSync(_player!, widget.mediaId);
    } else if (widget.mediaType == 'episode') {
      _progressService!.startEpisodeSync(_player!, widget.mediaId);
    }

    // Listen for playback completion
    await _positionSubscription?.cancel();
    _positionSubscription = _player!.stream.position.listen((_) {
      _onPlaybackProgress();
    });

    if (mounted) {
      setState(() {
        _isLoading = false;
        _loadingMessage = null;
      });
    }

    debugPrint('[PlayerScreen] P2P HLS playback initialized successfully');
  }

  /// Wait for P2P HLS playlist to be ready with enough segments.
  Future<void> _waitForP2PPlaylist(String playlistUrl) async {
    const maxRetries = 20;
    const minSegments = 3;
    const baseDelay = Duration(milliseconds: 500);
    const maxDelay = Duration(milliseconds: 3000);

    for (var i = 0; i < maxRetries; i++) {
      try {
        // Request via local proxy (no auth needed)
        final response = await http.get(Uri.parse(playlistUrl));

        if (response.statusCode == 200) {
          final playlistText = response.body;
          // Count .ts segments in playlist
          final segmentCount = '.ts'.allMatches(playlistText).length;

          if (segmentCount >= minSegments) {
            if (i > 0) {
              debugPrint(
                  '[PlayerScreen] P2P playlist ready after ${i + 1} attempt(s) with $segmentCount segments');
            }
            return;
          }

          final percentage = (segmentCount / minSegments * 100).round();
          debugPrint(
              '[PlayerScreen] P2P playlist has $segmentCount/$minSegments segments ($percentage%)');
          if (mounted) {
            setState(() {
              _loadingMessage = 'Preparing stream... $percentage%';
            });
          }
        } else {
          debugPrint(
              '[PlayerScreen] P2P playlist not ready (${response.statusCode}), retrying...');
          if (mounted) {
            setState(() {
              _loadingMessage =
                  'Starting transcoding... (${i + 1}/$maxRetries)';
            });
          }
        }

        // Exponential backoff with max cap
        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
              .clamp(
                baseDelay.inMilliseconds,
                maxDelay.inMilliseconds,
              )
              .toInt(),
        );
        await Future.delayed(delay);
      } catch (e) {
        debugPrint(
            '[PlayerScreen] Error checking P2P playlist (attempt ${i + 1}/$maxRetries): $e');
        if (mounted) {
          setState(() {
            _loadingMessage = 'Starting transcoding... (${i + 1}/$maxRetries)';
          });
        }

        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
              .clamp(
                baseDelay.inMilliseconds,
                maxDelay.inMilliseconds,
              )
              .toInt(),
        );
        await Future.delayed(delay);
      }
    }

    throw Exception('P2P playlist not ready after maximum retry attempts');
  }

  /// Initialize player for offline playback (no network services required).
  Future<void> _initializeOfflinePlayback(String filePath) async {
    try {
      debugPrint('Initializing offline playback from: $filePath');

      // Create media_kit player
      _player = Player();
      _videoController = VideoController(_player!);

      // Open local file
      await _player!.open(
        Media(filePath),
        play: false,
      );

      // Wait for player to be ready
      await Future.delayed(const Duration(milliseconds: 500));

      // Start playback
      await _player!.play();

      // Listen for playback progress (but don't sync - we're offline)
      // Cancel any existing subscription before creating a new one
      await _positionSubscription?.cancel();
      _positionSubscription = _player!.stream.position.listen((_) {
        _onPlaybackProgress();
      });

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      debugPrint('Offline playback initialized successfully');
    } catch (e) {
      debugPrint('Error initializing offline playback: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to play downloaded content: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchProgressAndEpisodes(GraphQLClient client) async {
    try {
      if (widget.mediaType == 'movie') {
        // Fetch movie progress
        final result = await client.query(
          QueryOptions(
            document: documentNodeQueryMovieDetail,
            variables: Variables$Query$MovieDetail(id: widget.mediaId).toJson(),
          ),
        );

        if (result.data != null) {
          final movie = Query$MovieDetail.fromJson(result.data!).movie;
          _savedPositionSeconds = movie?.progress?.positionSeconds;

          // Extract subtitle tracks from files
          _extractSubtitlesFromFiles(movie?.files);
        }
      } else if (widget.mediaType == 'episode') {
        // Fetch episode progress
        final result = await client.query(
          QueryOptions(
            document: documentNodeQueryEpisodeDetail,
            variables:
                Variables$Query$EpisodeDetail(id: widget.mediaId).toJson(),
          ),
        );

        if (result.data != null) {
          final episode = Query$EpisodeDetail.fromJson(result.data!).episode;
          _savedPositionSeconds = episode?.progress?.positionSeconds;

          // Extract subtitle tracks from files
          _extractSubtitlesFromFiles(episode?.files);

          // If we have show and season info, fetch episode list for navigation
          if (widget.showId != null && widget.seasonNumber != null) {
            await _fetchSeasonEpisodes(client);
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching progress: $e');
    }
  }

  /// Extract subtitle tracks from media files returned by GraphQL
  void _extractSubtitlesFromFiles(List<Fragment$MediaFileFragment?>? files) {
    if (files == null || files.isEmpty) return;

    // Find the file matching the current fileId
    for (final file in files) {
      if (file == null) continue;
      if (file.id == widget.fileId) {
        final subtitles = file.subtitles;
        if (subtitles != null) {
          _subtitleTracks = subtitles
              .whereType<Fragment$MediaFileFragment$subtitles>()
              .map((sub) => app_models.SubtitleTrack.fromGraphQL(sub))
              .toList();
          debugPrint(
              'Extracted ${_subtitleTracks.length} subtitle tracks from GraphQL');
        }
        break;
      }
    }
  }

  Future<void> _fetchSeasonEpisodes(GraphQLClient client) async {
    if (widget.showId == null || widget.seasonNumber == null) return;

    try {
      final result = await client.query(
        QueryOptions(
          document: documentNodeQuerySeasonEpisodes,
          variables: Variables$Query$SeasonEpisodes(
            showId: widget.showId!,
            seasonNumber: widget.seasonNumber!,
          ).toJson(),
        ),
      );

      if (result.data != null) {
        final episodes =
            Query$SeasonEpisodes.fromJson(result.data!).seasonEpisodes;
        if (episodes != null && mounted) {
          setState(() {
            _seasonEpisodes = episodes
                .whereType<Query$SeasonEpisodes$seasonEpisodes>()
                .toList();
            _currentEpisodeIndex =
                _seasonEpisodes?.indexWhere((ep) => ep.id == widget.mediaId);
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching season episodes: $e');
    }
  }

  void _onPlaybackProgress() {
    final player = _player;
    if (player == null || !mounted) return;

    // Check if video is near completion (90%)
    final isWatched = _progressService?.isWatched(player) == true;
    if (isWatched) {
      debugPrint('Content is considered watched (90% complete)');
      // Trigger "Up Next" overlay for episodes with a next episode available
      _maybeShowUpNext();
    }
  }

  /// Show the "Up Next" overlay if conditions are met.
  void _maybeShowUpNext() {
    // Don't show if already showing, cancelled, or not an episode
    if (_showUpNext || _autoPlayCancelled || widget.mediaType != 'episode') {
      return;
    }

    // Check if there's a next episode
    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return;
    }

    final hasNext = _currentEpisodeIndex! < _seasonEpisodes!.length - 1;
    if (!hasNext) {
      return;
    }

    // Show the overlay and start countdown
    setState(() {
      _showUpNext = true;
      _autoPlayCountdown = _autoPlayCountdownDuration;
    });

    _startAutoPlayCountdown();
  }

  /// Start the auto-play countdown timer.
  void _startAutoPlayCountdown() {
    _upNextTimer?.cancel();
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Check if player is paused - pause the countdown
      if (_player != null && !_player!.state.playing) {
        return;
      }

      setState(() {
        _autoPlayCountdown--;
      });

      if (_autoPlayCountdown <= 0) {
        timer.cancel();
        _playNextEpisode();
      }
    });
  }

  /// Cancel the auto-play overlay and countdown.
  void _cancelAutoPlay() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    if (mounted) {
      setState(() {
        _showUpNext = false;
        _autoPlayCancelled = true;
      });
    }
  }

  /// Play the next episode immediately.
  void _playNextEpisode() {
    _upNextTimer?.cancel();
    _upNextTimer = null;

    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return;
    }

    final nextIndex = _currentEpisodeIndex! + 1;
    if (nextIndex >= _seasonEpisodes!.length) {
      return;
    }

    final nextEpisode = _seasonEpisodes![nextIndex];
    final files = nextEpisode.files;
    if (files == null || files.isEmpty) {
      return;
    }

    final firstFile = files.first;
    if (firstFile == null) {
      return;
    }

    final title =
        'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
    _navigateToEpisode(nextEpisode.id, firstFile.id, title);
  }

  /// Get the title for the next episode (for display in Up Next overlay).
  String? _getNextEpisodeTitle() {
    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return null;
    }

    final nextIndex = _currentEpisodeIndex! + 1;
    if (nextIndex >= _seasonEpisodes!.length) {
      return null;
    }

    final nextEpisode = _seasonEpisodes![nextIndex];
    return 'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
  }

  /// Get the HLS playlist URL from the stream endpoint.
  /// On web, uses JSON response (browsers can't reliably follow redirects).
  /// On native, follows redirects manually.
  Future<String?> _getHlsPlaylistUrl(
      String streamUrl, Map<String, String> headers) async {
    try {
      final client = http.Client();
      try {
        if (kIsWeb) {
          // On web, request JSON response instead of redirect
          final uri = Uri.parse(streamUrl);
          final resolveUri = uri.replace(
            queryParameters: {...uri.queryParameters, 'resolve': 'json'},
          );

          debugPrint('Requesting HLS URL via JSON: $resolveUri');
          final response = await client.get(resolveUri, headers: headers);

          if (response.statusCode == 200) {
            final json = jsonDecode(response.body) as Map<String, dynamic>;
            final hlsPath = json['hls_url'] as String?;

            // Extract total duration from server (HLS live playlists don't include it)
            final durationSeconds = json['duration'] as num?;
            if (durationSeconds != null) {
              _totalDuration =
                  Duration(milliseconds: (durationSeconds * 1000).round());
              DurationOverride.value = _totalDuration;
              debugPrint('Total duration from server: $_totalDuration');
            }

            if (hlsPath != null) {
              // Convert relative path to absolute URL
              if (hlsPath.startsWith('/')) {
                return '${uri.scheme}://${uri.host}:${uri.port}$hlsPath';
              }
              return hlsPath;
            }
          }
          debugPrint(
              'Failed to get HLS URL from JSON response: ${response.statusCode}');
          return null;
        } else {
          // On native, follow redirects manually
          final request = http.Request('HEAD', Uri.parse(streamUrl));
          request.headers.addAll(headers);
          request.followRedirects = false;

          var response = await client.send(request);
          var currentUrl = streamUrl;

          // Follow redirects manually (up to 10 times)
          int redirectCount = 0;
          while (response.isRedirect && redirectCount < 10) {
            final location = response.headers['location'];
            if (location == null) break;

            // Handle relative URLs
            if (location.startsWith('/')) {
              final uri = Uri.parse(currentUrl);
              currentUrl = '${uri.scheme}://${uri.host}:${uri.port}$location';
            } else if (!location.startsWith('http')) {
              final uri = Uri.parse(currentUrl);
              final basePath =
                  uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
              currentUrl =
                  '${uri.scheme}://${uri.host}:${uri.port}$basePath$location';
            } else {
              currentUrl = location;
            }

            debugPrint('Following redirect to: $currentUrl');

            final nextRequest = http.Request('HEAD', Uri.parse(currentUrl));
            nextRequest.headers.addAll(headers);
            nextRequest.followRedirects = false;
            response = await client.send(nextRequest);
            redirectCount++;
          }

          return currentUrl;
        }
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('Error getting HLS URL: $e');
      return null;
    }
  }

  /// Wait for HLS playlist to be ready with enough segments.
  /// Polls the playlist URL with exponential backoff until it has at least 3 segments.
  Future<void> _waitForPlaylist(String playlistUrl, String token) async {
    const maxRetries = 15;
    const minSegments = 3;
    const baseDelay = Duration(milliseconds: 500);
    const maxDelay = Duration(milliseconds: 3000);

    for (var i = 0; i < maxRetries; i++) {
      try {
        final response = await http.get(
          Uri.parse(playlistUrl),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (response.statusCode == 200) {
          final playlistText = response.body;
          // Count .ts segments in playlist
          final segmentCount = '.ts'.allMatches(playlistText).length;

          if (segmentCount >= minSegments) {
            if (i > 0) {
              debugPrint(
                  'Playlist ready after ${i + 1} attempt(s) with $segmentCount segments');
            }
            return;
          }

          final percentage = (segmentCount / minSegments * 100).round();
          debugPrint(
              'Playlist has $segmentCount/$minSegments segments ($percentage%), waiting for more...');
          if (mounted) {
            setState(() {
              _loadingMessage = 'Preparing stream... $percentage%';
            });
          }
        } else {
          debugPrint(
              'Playlist not ready (${response.statusCode}), retrying...');
          if (mounted) {
            setState(() {
              _loadingMessage =
                  'Starting transcoding... (${i + 1}/$maxRetries)';
            });
          }
        }

        // Exponential backoff with max cap
        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
              .clamp(
                baseDelay.inMilliseconds,
                maxDelay.inMilliseconds,
              )
              .toInt(),
        );
        await Future.delayed(delay);
      } catch (e) {
        debugPrint(
            'Error checking playlist (attempt ${i + 1}/$maxRetries): $e');
        if (mounted) {
          setState(() {
            _loadingMessage = 'Starting transcoding... (${i + 1}/$maxRetries)';
          });
        }

        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1))
              .clamp(
                baseDelay.inMilliseconds,
                maxDelay.inMilliseconds,
              )
              .toInt(),
        );
        await Future.delayed(delay);
      }
    }

    throw Exception('Playlist not ready after maximum retry attempts');
  }

  Future<void> _navigateToEpisode(
      String episodeId, String fileId, String title) async {
    // Save current progress before navigating
    await _saveProgress();

    if (!mounted) return;

    // Navigate to new episode
    context.go(
      '/player/$episodeId/episode/$fileId?title=${Uri.encodeComponent(title)}&showId=${widget.showId}&seasonNumber=${widget.seasonNumber}',
    );
  }

  Future<void> _saveProgress() async {
    if (_player == null || _progressService == null) return;

    if (widget.mediaType == 'movie') {
      await _progressService!.saveMovieProgress(_player!, widget.mediaId);
    } else if (widget.mediaType == 'episode') {
      await _progressService!.saveEpisodeProgress(_player!, widget.mediaId);
    }
  }

  /// Extract session ID from HLS URL.
  /// URL format: /api/v1/hls/{session_id}/index.m3u8
  String? _extractSessionIdFromHlsUrl(String hlsUrl) {
    try {
      final uri = Uri.parse(hlsUrl);
      final segments = uri.pathSegments;
      // Find 'hls' in path and get the next segment (session_id)
      final hlsIndex = segments.indexOf('hls');
      if (hlsIndex != -1 && hlsIndex + 1 < segments.length) {
        return segments[hlsIndex + 1];
      }
    } catch (e) {
      debugPrint('Error extracting session ID from HLS URL: $e');
    }
    return null;
  }

  /// Terminate the HLS session on the server and clean up P2P resources.
  /// This stops FFmpeg and cleans up server-side resources.
  Future<void> _terminateHlsSession() async {
    final sessionId = _hlsSessionId;
    final token = _authToken;

    if (_isP2PMode) {
      // In P2P mode, always stop the local proxy
      try {
        final localProxyService = ref.read(localProxyServiceProvider);
        await localProxyService.stop();
        debugPrint('Local proxy stopped');
      } catch (e) {
        debugPrint('Error stopping local proxy: $e');
      }

      // Only terminate HLS session if one was started (not for direct play)
      if (sessionId != null && token != null) {
        debugPrint('Terminating P2P HLS session: $sessionId');
        try {
          final graphqlClient =
              await ref.read(asyncGraphqlClientProvider.future);
          final result = await graphqlClient.mutate(
            MutationOptions(
              document: documentNodeMutationEndStreamingSession,
              variables: Variables$Mutation$EndStreamingSession(
                sessionId: sessionId,
              ).toJson(),
            ),
          );

          if (result.hasException) {
            debugPrint(
                'Failed to terminate HLS session via GraphQL: ${result.exception}');
          } else {
            debugPrint('HLS session terminated successfully via GraphQL');
          }
        } catch (e) {
          debugPrint('Error terminating HLS session: $e');
        }
      }
    } else {
      // Non-P2P mode: use HTTP DELETE
      if (sessionId == null || token == null) {
        return;
      }

      final serverUrl = _serverUrl;
      if (serverUrl == null) {
        return;
      }

      debugPrint('Terminating HLS session: $sessionId');

      try {
        final response = await http.delete(
          Uri.parse('$serverUrl/api/v1/hls/$sessionId'),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (response.statusCode == 200) {
          debugPrint('HLS session terminated successfully');
        } else {
          debugPrint('Failed to terminate HLS session: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Error terminating HLS session: $e');
      }
    }
  }

  // Note: Subtitle tracks are now loaded via GraphQL in _fetchProgressAndEpisodes
  // The _loadSubtitleTracks method has been removed.

  /// Show subtitle track selector
  Future<void> _showSubtitleSelector() async {
    final selected = await showSubtitleTrackSelector(
      context,
      _subtitleTracks,
      _selectedSubtitleTrack,
    );

    // Note: selected can be null if user chose "Off"
    // This is handled by the selector returning null explicitly
    if (selected != _selectedSubtitleTrack && mounted) {
      setState(() {
        _selectedSubtitleTrack = selected;
      });

      if (selected != null) {
        debugPrint('Selected subtitle: ${selected.displayName}');
        // TODO: Apply subtitle track to video player
        // Note: Chewie/video_player has limited subtitle support on web
        _showSubtitleNotSupported();
      } else {
        debugPrint('Subtitles turned off');
      }
    }
  }

  /// Show a message that subtitle selection is not yet fully supported
  void _showSubtitleNotSupported() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Subtitle selection is coming soon for web. '
          'External subtitle support is in development.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// Show HLS quality selector (web only)
  Future<void> _showQualitySelector() async {
    final selected = await showHlsQualitySelector(
      context,
      _selectedQuality,
    );

    if (selected != null && selected != _selectedQuality && mounted) {
      setState(() {
        _selectedQuality = selected;
      });

      debugPrint('Selected quality: ${selected.label}');

      // Note: media_kit on web with hls.js handles quality selection automatically
      // The HLS.js library manages adaptive bitrate switching based on network conditions
      // For manual quality selection, we would need to access the hls.js instance
      // which is not directly exposed by media_kit's web implementation
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Quality preference set to ${selected.label}. '
            'Note: HLS adaptive streaming is handled automatically by the player.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Show track settings bottom sheet
  Future<void> _showTrackSettings() async {
    await showTrackSettingsSheet(
      context,
      onSubtitleTap: _showSubtitleSelector,
      selectedSubtitleTrack: _selectedSubtitleTrack,
      subtitleTrackCount: _subtitleTracks.length,
      onQualityTap: PlatformFeatures.isWeb ? _showQualitySelector : null,
      selectedQuality: _selectedQuality,
    );
  }

  /// Handle keyboard shortcuts (desktop only)
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final player = _player;
    if (player == null) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        // Play/Pause
        player.playOrPause();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        // Seek backward 10 seconds
        final currentPosition = player.state.position;
        final newPosition = currentPosition - const Duration(seconds: 10);
        final targetPosition =
            newPosition < Duration.zero ? Duration.zero : newPosition;
        player.seek(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        // Seek forward 10 seconds
        final currentPosition = player.state.position;
        final duration = player.state.duration;
        final newPosition = currentPosition + const Duration(seconds: 10);
        final targetPosition = newPosition > duration ? duration : newPosition;
        player.seek(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        // Volume up
        final currentVolume = player.state.volume;
        final newVolume = (currentVolume + 10.0).clamp(0.0, 100.0);
        player.setVolume(newVolume);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        // Volume down
        final currentVolume = player.state.volume;
        final newVolume = (currentVolume - 10.0).clamp(0.0, 100.0);
        player.setVolume(newVolume);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyF:
        // Toggle fullscreen
        // Note: media_kit fullscreen is handled by the Video widget controls
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyM:
        // Toggle mute
        if (player.state.volume > 0) {
          player.setVolume(0.0);
        } else {
          player.setVolume(100.0);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.escape:
        // Exit fullscreen - handled by video controller
        // Note: media_kit fullscreen is handled by the Video widget controls
        return KeyEventResult.handled;

      default:
        return KeyEventResult.ignored;
    }
  }

  /// Handle double-click for fullscreen toggle (desktop only)
  void _handleTap() {
    if (!PlatformFeatures.isDesktop) return;

    final now = DateTime.now();
    if (_lastClickTime != null &&
        now.difference(_lastClickTime!) < const Duration(milliseconds: 300)) {
      // Double click detected
      // Note: media_kit fullscreen is handled by the Video widget controls
      _lastClickTime = null;
    } else {
      // First click
      _lastClickTime = now;
    }
  }

  @override
  void dispose() {
    // Save progress before disposing (fire and forget - can't await in dispose)
    _saveProgress();

    // Terminate HLS session on server to stop FFmpeg (fire and forget)
    _terminateHlsSession();

    // Clear duration override
    DurationOverride.clear();

    // Unregister beforeunload handler on web
    if (kIsWeb) {
      web_lifecycle.unregisterBeforeUnload();
    }

    // Cancel stream subscription to prevent memory leak
    _positionSubscription?.cancel();

    // Cancel auto-play timer
    _upNextTimer?.cancel();

    // Stop progress tracking
    _progressService?.stopSync();
    _progressService?.dispose();

    // Dispose player (VideoController is automatically disposed when player is disposed)
    _player?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCasting = ref.watch(isCastingProvider);
    Widget body = isCasting ? _buildCastRemoteControlUI() : _buildBody();

    // Wrap with keyboard listener for desktop
    if (PlatformFeatures.supportsKeyboardShortcuts && !isCasting) {
      body = Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: body,
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: Colors.red,
            ),
            if (_loadingMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                _loadingMessage!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[400],
                    ),
              ),
            ],
          ],
        ),
      );
    }

    if (_error != null) {
      return _buildError();
    }

    if (_videoController == null) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.red,
        ),
      );
    }

    // Video widget fills available space with black background
    // Using SizedBox.expand ensures proper sizing on all platforms
    Widget videoPlayer = SizedBox.expand(
      child: Video(
        controller: _videoController!,
        controls: glassmorphicVideoControlsBuilder,
        fill: Colors.black,
      ),
    );

    // Wrap with gesture controls for mobile
    final player = _player;
    if (PlatformFeatures.supportsGestureControls && player != null) {
      videoPlayer = GestureControls(
        player: player,
        child: videoPlayer,
      );
    }

    // Add double-click handler for desktop
    if (PlatformFeatures.isDesktop) {
      videoPlayer = GestureDetector(
        onTap: _handleTap,
        child: videoPlayer,
      );
    }

    return Stack(
      children: [
        videoPlayer,
        Positioned(
          top: 8,
          left: 8,
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.5),
            ),
          ),
        ),
        if (widget.title != null)
          Positioned(
            top: 8,
            left: 56,
            right: 64,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.title!,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        // Track settings overlay (settings button + subtitle indicator)
        TrackSettingsOverlay(
          onSettingsTap: _showTrackSettings,
          selectedSubtitleTrack: _selectedSubtitleTrack,
        ),
        // Cast button
        Positioned(
          top: 8,
          right: 8,
          child: _buildCastButton(),
        ),
        // AirPlay button (iOS only)
        const Positioned(
          top: 8,
          right: 64,
          child: AirPlayButton(),
        ),
        // Episode navigation buttons
        if (_seasonEpisodes != null && _currentEpisodeIndex != null)
          _buildEpisodeNavigation(),
        // Up Next overlay for auto-play
        if (_showUpNext && _getNextEpisodeTitle() != null)
          UpNextOverlay(
            nextEpisodeTitle: _getNextEpisodeTitle()!,
            countdownSeconds: _autoPlayCountdown,
            onPlayNow: _playNextEpisode,
            onCancel: _cancelAutoPlay,
          ),
      ],
    );
  }

  Widget _buildEpisodeNavigation() {
    if (_seasonEpisodes == null || _currentEpisodeIndex == null) {
      return const SizedBox.shrink();
    }

    final hasPrevious = _currentEpisodeIndex! > 0;
    final hasNext = _currentEpisodeIndex! < _seasonEpisodes!.length - 1;

    return Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (hasPrevious)
            IconButton(
              icon: const Icon(Icons.skip_previous,
                  color: Colors.white, size: 32),
              onPressed: () {
                final prevEpisode = _seasonEpisodes![_currentEpisodeIndex! - 1];
                final files = prevEpisode.files;
                if (files != null && files.isNotEmpty) {
                  final firstFile = files.first;
                  if (firstFile != null) {
                    final title =
                        'S${prevEpisode.seasonNumber}E${prevEpisode.episodeNumber}${prevEpisode.title != null ? ' - ${prevEpisode.title}' : ''}';
                    _navigateToEpisode(prevEpisode.id, firstFile.id, title);
                  }
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(12),
              ),
              tooltip: 'Previous Episode',
            ),
          if (hasPrevious && hasNext) const SizedBox(width: 24),
          if (hasNext)
            IconButton(
              icon: const Icon(Icons.skip_next, color: Colors.white, size: 32),
              onPressed: () {
                final nextEpisode = _seasonEpisodes![_currentEpisodeIndex! + 1];
                final files = nextEpisode.files;
                if (files != null && files.isNotEmpty) {
                  final firstFile = files.first;
                  if (firstFile != null) {
                    final title =
                        'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
                    _navigateToEpisode(nextEpisode.id, firstFile.id, title);
                  }
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(12),
              ),
              tooltip: 'Next Episode',
            ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.red,
          ),
          const SizedBox(height: 16),
          Text(
            'Failed to load video',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[400],
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _initializePlayer,
            child: const Text('Retry'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  /// Build the cast button that opens device picker.
  Widget _buildCastButton() {
    final isCasting = ref.watch(isCastingProvider);
    final castDevice = ref.watch(currentCastDeviceProvider);

    return IconButton(
      icon: Icon(
        isCasting ? Icons.cast_connected : Icons.cast,
        color: isCasting ? Colors.blue : Colors.white,
      ),
      onPressed: _showCastDevicePicker,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.5),
      ),
      tooltip: isCasting && castDevice != null
          ? 'Casting to ${castDevice.name}'
          : 'Cast to device',
    );
  }

  /// Show the cast device picker dialog.
  Future<void> _showCastDevicePicker() async {
    final device = await showCastDevicePicker(context);

    if (device != null && mounted) {
      // Device was connected, now load the media
      await _startCasting(device);
    }
  }

  /// Start casting the current media to the selected device.
  Future<void> _startCasting(CastDevice device) async {
    final castService = ref.read(castServiceProvider);
    final serverUrlAsync = ref.read(serverUrlProvider);
    final authTokenAsync = ref.read(authTokenProvider);

    final serverUrl = serverUrlAsync.when(
      data: (url) => url,
      loading: () => null,
      error: (_, __) => null,
    );

    final token = authTokenAsync.when(
      data: (t) => t,
      loading: () => null,
      error: (_, __) => null,
    );

    if (serverUrl == null || token == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot start casting: server URL or token missing'),
          ),
        );
      }
      return;
    }

    try {
      // Get media token service for media access
      final mediaTokenService =
          await ref.read(asyncMediaTokenServiceProvider.future);
      await mediaTokenService.ensureValidToken();
      final mediaToken = await mediaTokenService.getToken();

      // Determine optimal streaming strategy
      final strategy = StreamingStrategyService.getOptimalStrategy();

      final streamUrl = StreamingStrategyService.buildStreamUrl(
        serverUrl: serverUrl,
        fileId: widget.fileId,
        strategy: strategy,
        mediaToken: mediaToken,
      );

      // Get current playback position if available
      Duration? startPosition;
      if (_player != null) {
        startPosition = _player!.state.position;
      }

      // Load media into cast session
      await castService.loadMedia(
        mediaUrl: streamUrl,
        title: widget.title ?? 'Untitled',
        subtitle: widget.mediaType == 'episode' ? 'Episode' : 'Movie',
        startPosition: startPosition,
      );

      // Pause local player
      if (_player != null && _player!.state.playing) {
        await _player!.pause();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Casting to ${device.name}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error starting cast: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start casting: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Build the remote control UI when casting.
  Widget _buildCastRemoteControlUI() {
    final mediaInfo = ref.watch(castMediaInfoProvider);
    final playbackState = ref.watch(castPlaybackStateProvider);
    final castDevice = ref.watch(currentCastDeviceProvider);
    final castService = ref.read(castServiceProvider);

    if (mediaInfo == null || castDevice == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.red),
      );
    }

    final isPlaying = playbackState == CastPlaybackState.playing;
    final isBuffering = playbackState == CastPlaybackState.buffering;
    final progress = mediaInfo.duration.inSeconds > 0
        ? mediaInfo.position.inSeconds / mediaInfo.duration.inSeconds
        : 0.0;

    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Cast icon
                const Icon(
                  Icons.cast_connected,
                  size: 120,
                  color: Colors.blue,
                ),
                const SizedBox(height: 32),
                // Device name
                Text(
                  'Casting to',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.grey[400],
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  castDevice.name,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 48),
                // Media title
                Text(
                  mediaInfo.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                      ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (mediaInfo.subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    mediaInfo.subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[400],
                        ),
                  ),
                ],
                const SizedBox(height: 48),
                // Progress bar
                Column(
                  children: [
                    Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (value) async {
                        final newPosition = Duration(
                          seconds:
                              (value * mediaInfo.duration.inSeconds).round(),
                        );
                        await castService.seek(newPosition);
                      },
                      activeColor: Colors.red,
                      inactiveColor: Colors.grey[800],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(mediaInfo.position),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[400],
                                    ),
                          ),
                          Text(
                            _formatDuration(mediaInfo.duration),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[400],
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Playback controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Rewind 10s
                    IconButton(
                      icon: const Icon(Icons.replay_10, color: Colors.white),
                      iconSize: 40,
                      onPressed: () async {
                        final newPosition =
                            mediaInfo.position - const Duration(seconds: 10);
                        await castService.seek(
                          newPosition.isNegative ? Duration.zero : newPosition,
                        );
                      },
                    ),
                    const SizedBox(width: 24),
                    // Play/Pause
                    if (isBuffering)
                      const SizedBox(
                        width: 64,
                        height: 64,
                        child: CircularProgressIndicator(
                          color: Colors.red,
                          strokeWidth: 4,
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                        ),
                        iconSize: 64,
                        onPressed: () async {
                          if (isPlaying) {
                            await castService.pause();
                          } else {
                            await castService.play();
                          }
                        },
                      ),
                    const SizedBox(width: 24),
                    // Forward 10s
                    IconButton(
                      icon: const Icon(Icons.forward_10, color: Colors.white),
                      iconSize: 40,
                      onPressed: () async {
                        final newPosition =
                            mediaInfo.position + const Duration(seconds: 10);
                        final maxPosition = mediaInfo.duration;
                        await castService.seek(
                          newPosition > maxPosition ? maxPosition : newPosition,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Stop casting button
                OutlinedButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Casting'),
                  onPressed: () async {
                    await castService.disconnect();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Back button
        Positioned(
          top: 8,
          left: 8,
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }

  /// Format duration as HH:MM:SS or MM:SS.
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}
