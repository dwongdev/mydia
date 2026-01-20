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
///   controls: glassmorphicVideoControlsBuilder,
/// )
/// ```
Widget glassmorphicVideoControlsBuilder(VideoState state) {
  return const _GlassmorphicVideoControls();
}

/// Custom glassmorphism-styled video controls overlay.
///
/// Features:
/// - Frosted glass effect on control elements
/// - Auto-hide after 3 seconds of inactivity
/// - Tap/mouse move to show controls
/// - Large centered play/pause button
/// - Thin seekable progress bar
/// - Time display, volume, and fullscreen controls
class _GlassmorphicVideoControls extends StatefulWidget {
  const _GlassmorphicVideoControls();

  @override
  State<_GlassmorphicVideoControls> createState() =>
      _GlassmorphicVideoControlsState();
}

class _GlassmorphicVideoControlsState extends State<_GlassmorphicVideoControls>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  Timer? _hideTimer;
  bool _isVisible = true;
  bool _isSeeking = false;

  final List<StreamSubscription> _subscriptions = [];

  static const _autoHideDuration = Duration(seconds: 3);

  /// Access the VideoController from the inherited widget
  VideoController _controller(BuildContext context) =>
      VideoStateInheritedWidget.of(context).state.widget.controller;

  /// Access the Player from the inherited widget
  Player _player(BuildContext context) => _controller(context).player;

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
    }
    _startHideTimer();
  }

  void _hideControls() {
    if (_isVisible && !_isSeeking && _player(context).state.playing) {
      setState(() => _isVisible = false);
      _animationController.reverse();
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
    final controller = _controller(context);

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
            child: _buildControlsOverlay(player, controller),
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

  Widget _buildControlsOverlay(Player player, VideoController controller) {
    return Container(
      decoration: BoxDecoration(
        // Subtle gradient for better visibility of controls
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.4),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: Stack(
        children: [
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
                const SizedBox(width: 100), // Space for play button
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
            left: 16,
            right: 16,
            bottom: 16,
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
                  videoController: controller,
                ),
              ],
            ),
          ),
        ],
      ),
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
