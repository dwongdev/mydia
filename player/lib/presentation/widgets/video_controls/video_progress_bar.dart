import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/theme/colors.dart';

/// A thin, seekable progress bar for video playback.
///
/// Features:
/// - Thin design (4px normally, 8px when interacting)
/// - Tap to seek to position
/// - Drag to scrub through video
/// - Shows buffered progress
/// - Position indicator circle at current position
class VideoProgressBar extends StatefulWidget {
  /// The media_kit player instance.
  final Player player;

  /// Called when seeking starts (user begins dragging).
  final VoidCallback? onSeekStart;

  /// Called when seeking ends (user releases drag).
  final VoidCallback? onSeekEnd;

  /// Called during seeking with the current seek position.
  final ValueChanged<Duration>? onSeekUpdate;

  /// The height of the progress bar when not interacting.
  final double height;

  /// The height of the progress bar when interacting.
  final double activeHeight;

  const VideoProgressBar({
    super.key,
    required this.player,
    this.onSeekStart,
    this.onSeekEnd,
    this.onSeekUpdate,
    this.height = 4,
    this.activeHeight = 8,
  });

  @override
  State<VideoProgressBar> createState() => _VideoProgressBarState();
}

class _VideoProgressBarState extends State<VideoProgressBar> {
  bool _isSeeking = false;
  double _seekPosition = 0;
  bool _isHovering = false;

  double get _currentHeight =>
      (_isSeeking || _isHovering) ? widget.activeHeight : widget.height;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durationSnapshot) {
            return StreamBuilder<Duration>(
              stream: widget.player.stream.buffer,
              initialData: widget.player.state.buffer,
              builder: (context, bufferSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final buffer = bufferSnapshot.data ?? Duration.zero;

                final durationMs = duration.inMilliseconds.toDouble();
                final positionMs = position.inMilliseconds.toDouble();
                final bufferMs = buffer.inMilliseconds.toDouble();

                final progress =
                    durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;
                final buffered =
                    durationMs > 0 ? (bufferMs / durationMs).clamp(0.0, 1.0) : 0.0;
                final displayProgress =
                    _isSeeking ? _seekPosition : progress;

                return MouseRegion(
                  onEnter: (_) => setState(() => _isHovering = true),
                  onExit: (_) => setState(() => _isHovering = false),
                  child: GestureDetector(
                    onHorizontalDragStart: (details) => _handleDragStart(
                      details,
                      context,
                      duration,
                    ),
                    onHorizontalDragUpdate: (details) => _handleDragUpdate(
                      details,
                      context,
                      duration,
                    ),
                    onHorizontalDragEnd: (details) => _handleDragEnd(
                      details,
                      duration,
                    ),
                    onTapUp: (details) => _handleTap(
                      details,
                      context,
                      duration,
                    ),
                    child: Container(
                      height: 32, // Touch target size
                      color: Colors.transparent, // Expand hit area
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          height: _currentHeight,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  // Background track
                                  Container(
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(
                                          _currentHeight / 2),
                                    ),
                                  ),
                                  // Buffered progress
                                  FractionallySizedBox(
                                    widthFactor: buffered,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: AppColors.primary
                                            .withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(
                                            _currentHeight / 2),
                                      ),
                                    ),
                                  ),
                                  // Current progress
                                  FractionallySizedBox(
                                    widthFactor: displayProgress,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: AppColors.primary,
                                        borderRadius: BorderRadius.circular(
                                            _currentHeight / 2),
                                      ),
                                    ),
                                  ),
                                  // Position indicator
                                  if (_isSeeking || _isHovering)
                                    Positioned(
                                      left: (constraints.maxWidth *
                                              displayProgress) -
                                          6,
                                      top: (_currentHeight - 12) / 2,
                                      child: Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black
                                                  .withValues(alpha: 0.3),
                                              blurRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _handleDragStart(
    DragStartDetails details,
    BuildContext context,
    Duration duration,
  ) {
    setState(() => _isSeeking = true);
    widget.onSeekStart?.call();
    _updateSeekPosition(details.localPosition.dx, context, duration);
  }

  void _handleDragUpdate(
    DragUpdateDetails details,
    BuildContext context,
    Duration duration,
  ) {
    _updateSeekPosition(details.localPosition.dx, context, duration);
  }

  void _handleDragEnd(DragEndDetails details, Duration duration) {
    final seekDuration = Duration(
      milliseconds: (duration.inMilliseconds * _seekPosition).toInt(),
    );
    widget.player.seek(seekDuration);
    setState(() => _isSeeking = false);
    widget.onSeekEnd?.call();
  }

  void _handleTap(
    TapUpDetails details,
    BuildContext context,
    Duration duration,
  ) {
    final box = context.findRenderObject() as RenderBox;
    final position = details.localPosition.dx / box.size.width;
    final clampedPosition = position.clamp(0.0, 1.0);
    final seekDuration = Duration(
      milliseconds: (duration.inMilliseconds * clampedPosition).toInt(),
    );
    widget.player.seek(seekDuration);
  }

  void _updateSeekPosition(
    double dx,
    BuildContext context,
    Duration duration,
  ) {
    final box = context.findRenderObject() as RenderBox;
    final position = dx / box.size.width;
    final clampedPosition = position.clamp(0.0, 1.0);

    setState(() => _seekPosition = clampedPosition);

    final seekDuration = Duration(
      milliseconds: (duration.inMilliseconds * clampedPosition).toInt(),
    );
    widget.onSeekUpdate?.call(seekDuration);
  }
}
