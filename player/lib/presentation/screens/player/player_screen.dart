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
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/player/progress_service.dart';
import '../../../core/utils/file_utils.dart' as file_utils;
import '../../../core/player/platform_features.dart';
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
import '../../../domain/models/subtitle_track.dart' as app_models;
import '../../../domain/models/cast_device.dart';
import '../../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';

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
  Player? _player;
  VideoController? _videoController;
  ProgressService? _progressService;
  bool _isLoading = true;
  String? _error;
  String? _loadingMessage;
  int? _savedPositionSeconds;
  List<Query$SeasonEpisodes$seasonEpisodes>? _seasonEpisodes;
  int? _currentEpisodeIndex;

  // Track selection state
  List<app_models.SubtitleTrack> _subtitleTracks = [];
  app_models.SubtitleTrack? _selectedSubtitleTrack;
  bool _loadingSubtitles = false;

  // HLS quality selection (web only)
  HlsQualityLevel _selectedQuality = HlsQualityLevel.auto;

  // Desktop feature state
  final FocusNode _focusNode = FocusNode();
  int _clickCount = 0;
  DateTime? _lastClickTime;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      // Wait for auth to be ready using async provider
      final graphqlClient = await ref.read(asyncGraphqlClientProvider.future);

      // Get server URL and token (they should be available now since client is ready)
      final serverUrl = await ref.read(serverUrlProvider.future);
      final token = await ref.read(authTokenProvider.future);

      if (serverUrl == null || token == null) {
        setState(() {
          _error = 'Server URL or authentication token not available';
          _isLoading = false;
        });
        return;
      }

      // Get media token service for media access
      final mediaTokenService = await ref.read(asyncMediaTokenServiceProvider.future);

      // Ensure media token is valid and refreshed if needed
      await mediaTokenService.ensureValidToken();

      // Initialize progress service
      _progressService = ProgressService(graphqlClient);

      // Fetch saved progress and episode list for TV shows
      await _fetchProgressAndEpisodes(graphqlClient);

      // Create media_kit player
      _player = Player();
      _videoController = VideoController(_player!);

      // Check if media is downloaded for offline playback
      final downloadManager = ref.read(downloadManagerProvider);
      final downloadedMedia = downloadManager.getDownloadedMediaById(widget.mediaId);

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

        debugPrint('Initializing video player with URL: $streamUrl (strategy: ${strategy.value})');

        // For HLS strategies, follow redirect and wait for playlist to be ready
        if (strategy == StreamingStrategy.hlsCopy || strategy == StreamingStrategy.transcode) {
          setState(() {
            _loadingMessage = 'Starting stream...';
          });

          // Get the HLS playlist URL from the server
          final hlsUrl = await _getHlsPlaylistUrl(
            streamUrl,
            mediaToken != null ? {} : {'Authorization': 'Bearer $token'},
          );

          if (hlsUrl != null && hlsUrl.contains('.m3u8')) {
            debugPrint('HLS playlist URL: $hlsUrl');

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

      setState(() {
        _loadingMessage = null;
      });

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
      if (mounted &&
          _savedPositionSeconds != null &&
          _savedPositionSeconds! > 30 &&
          duration > 0) {
        final shouldResume = await showResumeDialog(
          context,
          _savedPositionSeconds!,
          duration,
        );

        if (shouldResume == true) {
          await _player!.seek(Duration(seconds: _savedPositionSeconds!));
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
      _player!.stream.position.listen((_) {
        _onPlaybackProgress();
      });

      setState(() {
        _isLoading = false;
      });

      // Subtitle tracks are now extracted from GraphQL in _fetchProgressAndEpisodes
      debugPrint('Loaded ${_subtitleTracks.length} subtitle tracks from GraphQL');
    } catch (e) {
      debugPrint('Error initializing player: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
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
            variables: Variables$Query$EpisodeDetail(id: widget.mediaId).toJson(),
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
          debugPrint('Extracted ${_subtitleTracks.length} subtitle tracks from GraphQL');
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
        final episodes = Query$SeasonEpisodes.fromJson(result.data!).seasonEpisodes;
        if (episodes != null) {
          setState(() {
            _seasonEpisodes = episodes.whereType<Query$SeasonEpisodes$seasonEpisodes>().toList();
            _currentEpisodeIndex = _seasonEpisodes?.indexWhere((ep) => ep.id == widget.mediaId);
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching season episodes: $e');
    }
  }

  void _onPlaybackProgress() {
    if (_player == null || !mounted) return;

    // Check if video is near completion (90%)
    if (_progressService?.isWatched(_player!) == true) {
      // Could trigger mark as watched here if desired
      debugPrint('Content is considered watched (90% complete)');
    }
  }

  /// Get the HLS playlist URL from the stream endpoint.
  /// On web, uses JSON response (browsers can't reliably follow redirects).
  /// On native, follows redirects manually.
  Future<String?> _getHlsPlaylistUrl(String streamUrl, Map<String, String> headers) async {
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
            if (hlsPath != null) {
              // Convert relative path to absolute URL
              if (hlsPath.startsWith('/')) {
                return '${uri.scheme}://${uri.host}:${uri.port}$hlsPath';
              }
              return hlsPath;
            }
          }
          debugPrint('Failed to get HLS URL from JSON response: ${response.statusCode}');
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
              final basePath = uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
              currentUrl = '${uri.scheme}://${uri.host}:${uri.port}$basePath$location';
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
              debugPrint('Playlist ready after ${i + 1} attempt(s) with $segmentCount segments');
            }
            return;
          }

          debugPrint('Playlist has $segmentCount/$minSegments segments, waiting for more...');
          if (mounted) {
            setState(() {
              _loadingMessage = 'Preparing stream... ($segmentCount/$minSegments segments)';
            });
          }
        } else {
          debugPrint('Playlist not ready (${response.statusCode}), retrying...');
          if (mounted) {
            setState(() {
              _loadingMessage = 'Starting transcoding... (${i + 1}/$maxRetries)';
            });
          }
        }

        // Exponential backoff with max cap
        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1)).clamp(
            baseDelay.inMilliseconds,
            maxDelay.inMilliseconds,
          ).toInt(),
        );
        await Future.delayed(delay);
      } catch (e) {
        debugPrint('Error checking playlist (attempt ${i + 1}/$maxRetries): $e');
        if (mounted) {
          setState(() {
            _loadingMessage = 'Starting transcoding... (${i + 1}/$maxRetries)';
          });
        }

        final delay = Duration(
          milliseconds: (baseDelay.inMilliseconds * (1.5 * i + 1)).clamp(
            baseDelay.inMilliseconds,
            maxDelay.inMilliseconds,
          ).toInt(),
        );
        await Future.delayed(delay);
      }
    }

    throw Exception('Playlist not ready after maximum retry attempts');
  }

  Future<void> _navigateToEpisode(String episodeId, String fileId, String title) async {
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
    if (selected != _selectedSubtitleTrack) {
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

    if (selected != null && selected != _selectedQuality) {
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
      loadingSubtitles: _loadingSubtitles,
      subtitleTrackCount: _subtitleTracks.length,
      onQualityTap: PlatformFeatures.isWeb ? _showQualitySelector : null,
      selectedQuality: _selectedQuality,
    );
  }

  /// Handle keyboard shortcuts (desktop only)
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_player == null) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        // Play/Pause
        _player!.playOrPause();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        // Seek backward 10 seconds
        final currentPosition = _player!.state.position;
        final newPosition = currentPosition - const Duration(seconds: 10);
        final targetPosition = newPosition < Duration.zero ? Duration.zero : newPosition;
        _player!.seek(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        // Seek forward 10 seconds
        final currentPosition = _player!.state.position;
        final duration = _player!.state.duration;
        final newPosition = currentPosition + const Duration(seconds: 10);
        final targetPosition = newPosition > duration ? duration : newPosition;
        _player!.seek(targetPosition);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        // Volume up
        final currentVolume = _player!.state.volume;
        final newVolume = (currentVolume + 10.0).clamp(0.0, 100.0);
        _player!.setVolume(newVolume);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        // Volume down
        final currentVolume = _player!.state.volume;
        final newVolume = (currentVolume - 10.0).clamp(0.0, 100.0);
        _player!.setVolume(newVolume);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyF:
        // Toggle fullscreen
        // Note: media_kit fullscreen is handled by the Video widget controls
        return KeyEventResult.handled;

      case LogicalKeyboardKey.keyM:
        // Toggle mute
        if (_player!.state.volume > 0) {
          _player!.setVolume(0.0);
        } else {
          _player!.setVolume(100.0);
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
      _clickCount = 0;
      _lastClickTime = null;
    } else {
      // First click
      _clickCount = 1;
      _lastClickTime = now;
    }
  }

  @override
  void dispose() {
    // Save progress before disposing
    _saveProgress();

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
        controls: MaterialVideoControls,
        fill: Colors.black,
      ),
    );

    // Wrap with gesture controls for mobile
    if (PlatformFeatures.supportsGestureControls && _player != null) {
      videoPlayer = GestureControls(
        player: _player!,
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
              icon: const Icon(Icons.skip_previous, color: Colors.white, size: 32),
              onPressed: () {
                final prevEpisode = _seasonEpisodes![_currentEpisodeIndex! - 1];
                final files = prevEpisode.files;
                if (files != null && files.isNotEmpty) {
                  final firstFile = files.first;
                  if (firstFile != null) {
                    final title = 'S${prevEpisode.seasonNumber}E${prevEpisode.episodeNumber}${prevEpisode.title != null ? ' - ${prevEpisode.title}' : ''}';
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
                    final title = 'S${nextEpisode.seasonNumber}E${nextEpisode.episodeNumber}${nextEpisode.title != null ? ' - ${nextEpisode.title}' : ''}';
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
      final mediaTokenService = await ref.read(asyncMediaTokenServiceProvider.future);
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
                          seconds: (value * mediaInfo.duration.inSeconds).round(),
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
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.grey[400],
                                ),
                          ),
                          Text(
                            _formatDuration(mediaInfo.duration),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                        final newPosition = mediaInfo.position - const Duration(seconds: 10);
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
                          isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
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
                        final newPosition = mediaInfo.position + const Duration(seconds: 10);
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
