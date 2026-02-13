import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/player/duration_override.dart';
import '../../../core/player/platform_features.dart';
import 'bottom_controls_bar.dart';
import 'center_play_button.dart';
import 'control_button.dart';
import 'video_progress_bar.dart';

/// Builder function for use with media_kit's Video widget controls parameter.
///
/// Usage:
/// ```dart
/// Video(
///   controller: videoController,
///   controls: customVideoControlsBuilder,
/// )
/// ```
Widget customVideoControlsBuilder(VideoState state) {
  return const _CustomVideoControls();
}

/// Creates a controls builder that notifies when controls visibility changes.
///
/// Usage:
/// ```dart
/// Video(
///   controller: videoController,
///   controls: customVideoControlsBuilderWithCallback(
///     onVisibilityChanged: (visible) { ... },
///   ),
/// )
/// ```
Widget Function(VideoState) customVideoControlsBuilderWithCallback({
  required ValueChanged<bool> onVisibilityChanged,
  VoidCallback? onAudioTap,
  VoidCallback? onSubtitleTap,
  VoidCallback? onQualityTap,
  VoidCallback? onFullscreenTap,
  bool isFullscreen = false,
  int audioTrackCount = 0,
  int subtitleTrackCount = 0,
  String? selectedAudioLabel,
  String? selectedSubtitleLabel,
  String? selectedQualityLabel,
}) {
  return (VideoState state) => _CustomVideoControls(
        onVisibilityChanged: onVisibilityChanged,
        onAudioTap: onAudioTap,
        onSubtitleTap: onSubtitleTap,
        onQualityTap: onQualityTap,
        onFullscreenTap: onFullscreenTap,
        isFullscreen: isFullscreen,
        audioTrackCount: audioTrackCount,
        subtitleTrackCount: subtitleTrackCount,
        selectedAudioLabel: selectedAudioLabel,
        selectedSubtitleLabel: selectedSubtitleLabel,
        selectedQualityLabel: selectedQualityLabel,
      );
}

/// Custom minimal video controls overlay with flat style.
///
/// Features:
/// - Clean minimal flat design
/// - Auto-hide after 3 seconds of inactivity
/// - Tap/mouse move to show controls
/// - Large centered play/pause button
/// - Thin seekable progress bar
/// - Time display, volume, and fullscreen controls
/// - Audio and subtitle selection in bottom bar
class _CustomVideoControls extends StatefulWidget {
  final ValueChanged<bool>? onVisibilityChanged;
  final VoidCallback? onAudioTap;
  final VoidCallback? onSubtitleTap;
  final VoidCallback? onQualityTap;
  final VoidCallback? onFullscreenTap;
  final bool isFullscreen;
  final int audioTrackCount;
  final int subtitleTrackCount;
  final String? selectedAudioLabel;
  final String? selectedSubtitleLabel;
  final String? selectedQualityLabel;

  const _CustomVideoControls({
    this.onVisibilityChanged,
    this.onAudioTap,
    this.onSubtitleTap,
    this.onQualityTap,
    this.onFullscreenTap,
    this.isFullscreen = false,
    this.audioTrackCount = 0,
    this.subtitleTrackCount = 0,
    this.selectedAudioLabel,
    this.selectedSubtitleLabel,
    this.selectedQualityLabel,
  });

  @override
  State<_CustomVideoControls> createState() => _CustomVideoControlsState();
}

class _CustomVideoControlsState extends State<_CustomVideoControls>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  Timer? _hideTimer;
  bool _isVisible = true;
  bool _isSeeking = false;

  final List<StreamSubscription> _subscriptions = [];

  static const _autoHideDuration = Duration(seconds: 3);

  /// Access the Player from the inherited widget
  Player _player(BuildContext context) =>
      VideoStateInheritedWidget.of(context).state.widget.controller.player;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0, // Start visible
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Set up subscriptions if not already done
    if (_subscriptions.isEmpty) {
      final player = _player(context);

      // Listen to playing state to manage auto-hide
      _subscriptions.add(
        player.stream.playing.listen((isPlaying) {
          if (isPlaying && _isVisible && !_isSeeking) {
            _startHideTimer();
          } else if (!isPlaying) {
            _cancelHideTimer();
          }
        }),
      );

      // Start hide timer if already playing
      if (player.state.playing) {
        _startHideTimer();
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _animationController.dispose();
    super.dispose();
  }

  void _showControls() {
    if (!_isVisible) {
      setState(() => _isVisible = true);
      _animationController.forward();
      widget.onVisibilityChanged?.call(true);
    }
    _startHideTimer();
  }

  void _hideControls() {
    if (_isVisible && !_isSeeking && _player(context).state.playing) {
      setState(() => _isVisible = false);
      _animationController.reverse();
      widget.onVisibilityChanged?.call(false);
    }
  }

  void _startHideTimer() {
    _cancelHideTimer();
    if (_player(context).state.playing && !_isSeeking) {
      _hideTimer = Timer(_autoHideDuration, _hideControls);
    }
  }

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _handleTap() {
    if (_isVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  void _handleSeekStart() {
    setState(() => _isSeeking = true);
    _cancelHideTimer();
  }

  void _handleSeekEnd() {
    setState(() => _isSeeking = false);
    _startHideTimer();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player(context);
    // Use MouseRegion for desktop/web to show on mouse move
    Widget controls = Stack(
      fit: StackFit.expand,
      children: [
        // Tap/click detector for showing/hiding controls
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          child: const SizedBox.expand(),
        ),
        // Controls overlay
        FadeTransition(
          opacity: _fadeAnimation,
          child: IgnorePointer(
            ignoring: !_isVisible,
            child: _buildControlsOverlay(player),
          ),
        ),
      ],
    );

    // On desktop/web, also show controls on mouse move
    if (!PlatformFeatures.isMobile) {
      controls = MouseRegion(
        onHover: (_) => _showControls(),
        child: controls,
      );
    }

    return controls;
  }

  Widget _buildControlsOverlay(Player player) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Top gradient for top bar readability
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.5),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Bottom gradient for bottom controls readability
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 200,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.6),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Center play button
        Center(
          child: CenterPlayButton(player: player),
        ),
        // Seek backward/forward buttons (left and right of center)
        Positioned.fill(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ControlButton(
                icon: Icons.replay_10_rounded,
                onTap: () => _seekBackward(player),
                tooltip: 'Rewind 10 seconds',
              ),
              const SizedBox(width: 120), // Space for play button
              ControlButton(
                icon: Icons.forward_10_rounded,
                onTap: () => _seekForward(player),
                tooltip: 'Forward 10 seconds',
              ),
            ],
          ),
        ),
        // Bottom controls
        Positioned(
          left: 20,
          right: 20,
          bottom: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress bar
              VideoProgressBar(
                player: player,
                onSeekStart: _handleSeekStart,
                onSeekEnd: _handleSeekEnd,
              ),
              const SizedBox(height: 8),
              // Bottom controls bar
              BottomControlsBar(
                player: player,
                onAudioTap: widget.onAudioTap,
                onSubtitleTap: widget.onSubtitleTap,
                onQualityTap: widget.onQualityTap,
                onFullscreenTap: widget.onFullscreenTap,
                isFullscreen: widget.isFullscreen,
                audioTrackCount: widget.audioTrackCount,
                subtitleTrackCount: widget.subtitleTrackCount,
                selectedAudioLabel: widget.selectedAudioLabel,
                selectedSubtitleLabel: widget.selectedSubtitleLabel,
                selectedQualityLabel: widget.selectedQualityLabel,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _seekBackward(Player player) {
    final currentPosition = player.state.position;
    final newPosition = currentPosition - const Duration(seconds: 10);
    final targetPosition =
        newPosition < Duration.zero ? Duration.zero : newPosition;
    player.seek(targetPosition);
    _showControls();
  }

  void _seekForward(Player player) {
    final currentPosition = player.state.position;
    // Use duration override if available (for HLS live playlists)
    final duration = DurationOverride.getDuration(player.state.duration);
    final newPosition = currentPosition + const Duration(seconds: 10);
    final targetPosition = newPosition > duration ? duration : newPosition;
    player.seek(targetPosition);
    _showControls();
  }
}
