import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/player/duration_override.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/theme/colors.dart';
import 'glass_container.dart';

/// Bottom controls bar with time display, volume control, and fullscreen toggle.
///
/// Adapts to platform:
/// - Mobile: mute toggle button for volume
/// - Desktop/Web: volume slider on hover
class BottomControlsBar extends StatefulWidget {
  /// The media_kit player instance.
  final Player player;

  /// The video controller for fullscreen operations.
  final VideoController videoController;

  const BottomControlsBar({
    super.key,
    required this.player,
    required this.videoController,
  });

  @override
  State<BottomControlsBar> createState() => _BottomControlsBarState();
}

class _BottomControlsBarState extends State<BottomControlsBar> {
  bool _showVolumeSlider = false;
  double _lastVolume = 100.0;

  @override
  void initState() {
    super.initState();
    _lastVolume = widget.player.state.volume;
    if (_lastVolume == 0) {
      _lastVolume = 100.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // Time display
          _buildTimeDisplay(),
          const Spacer(),
          // Volume control
          _buildVolumeControl(),
          const SizedBox(width: 8),
          // Fullscreen button
          _buildFullscreenButton(),
        ],
      ),
    );
  }

  Widget _buildTimeDisplay() {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            // Use duration override if available (for HLS live playlists)
            final playerDuration = durationSnapshot.data ?? Duration.zero;
            final duration = DurationOverride.getDuration(playerDuration);

            return Text(
              '${_formatDuration(position)} / ${_formatDuration(duration)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildVolumeControl() {
    return StreamBuilder<double>(
      stream: widget.player.stream.volume,
      initialData: widget.player.state.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 100.0;
        final isMuted = volume == 0;

        // On mobile, show just a mute toggle
        if (PlatformFeatures.isMobile) {
          return _buildMuteButton(isMuted);
        }

        // On desktop/web, show volume slider on hover
        return MouseRegion(
          onEnter: (_) => setState(() => _showVolumeSlider = true),
          onExit: (_) => setState(() => _showVolumeSlider = false),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMuteButton(isMuted),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _showVolumeSlider ? 80 : 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _showVolumeSlider ? 1.0 : 0.0,
                  child: _showVolumeSlider
                      ? SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                            activeTrackColor: AppColors.primary,
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.3),
                            thumbColor: Colors.white,
                            overlayColor:
                                AppColors.primary.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: volume / 100.0,
                            onChanged: (value) {
                              widget.player.setVolume(value * 100.0);
                              if (value > 0) {
                                _lastVolume = value * 100.0;
                              }
                            },
                          ),
                        )
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMuteButton(bool isMuted) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (isMuted) {
            widget.player.setVolume(_lastVolume);
          } else {
            _lastVolume = widget.player.state.volume;
            widget.player.setVolume(0);
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            _getVolumeIcon(isMuted ? 0 : widget.player.state.volume),
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenButton() {
    return StreamBuilder<bool>(
      stream: widget.videoController.player.stream.playing,
      initialData: false,
      builder: (context, _) {
        // Note: media_kit doesn't expose fullscreen state through streams
        // We track it locally or check document.fullscreenElement on web
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              // Toggle fullscreen using media_kit's built-in method
              defaultEnterNativeFullscreen();
            },
            borderRadius: BorderRadius.circular(16),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.fullscreen_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _getVolumeIcon(double volume) {
    if (volume == 0) {
      return Icons.volume_off_rounded;
    } else if (volume < 50) {
      return Icons.volume_down_rounded;
    } else {
      return Icons.volume_up_rounded;
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
  }
}
