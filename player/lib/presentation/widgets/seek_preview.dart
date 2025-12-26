import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/player/thumbnail_service.dart';

/// Widget that displays a thumbnail preview above the seek bar during scrubbing.
class SeekPreview extends StatelessWidget {
  /// The thumbnail cue to display
  final ThumbnailCue cue;

  /// The sprite sheet URL
  final String spriteUrl;

  /// Current seek position in seconds
  final double seekPosition;

  /// Total duration in seconds
  final double duration;

  /// Authorization token for loading the sprite image
  final String authToken;

  const SeekPreview({
    super.key,
    required this.cue,
    required this.spriteUrl,
    required this.seekPosition,
    required this.duration,
    required this.authToken,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Thumbnail image
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            child: _buildThumbnail(),
          ),
          // Timestamp label
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              _formatTime(seekPosition),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail() {
    return SizedBox(
      width: cue.width.toDouble(),
      height: cue.height.toDouble(),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: cue.width.toDouble(),
          minHeight: cue.height.toDouble(),
          maxWidth: cue.width.toDouble(),
          maxHeight: cue.height.toDouble(),
          child: Transform.translate(
            offset: Offset(-cue.x.toDouble(), -cue.y.toDouble()),
            child: CachedNetworkImage(
              imageUrl: spriteUrl,
              httpHeaders: {
                'Authorization': 'Bearer $authToken',
              },
              fit: BoxFit.none,
              alignment: Alignment.topLeft,
              placeholder: (context, url) => Container(
                width: cue.width.toDouble(),
                height: cue.height.toDouble(),
                color: Colors.grey[900],
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              errorWidget: (context, url, error) => Container(
                width: cue.width.toDouble(),
                height: cue.height.toDouble(),
                color: Colors.grey[900],
                child: const Icon(
                  Icons.broken_image,
                  color: Colors.white54,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Format seconds to HH:MM:SS or MM:SS
  String _formatTime(double seconds) {
    final duration = Duration(seconds: seconds.toInt());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    }
  }
}

/// Wrapper widget that manages thumbnail loading and positioning
class SeekPreviewOverlay extends StatefulWidget {
  /// List of thumbnail cues from VTT
  final List<ThumbnailCue> thumbnailCues;

  /// Current seek position in seconds (null when not seeking)
  final double? seekPosition;

  /// Total duration in seconds
  final double duration;

  /// Server URL for building sprite URLs
  final String serverUrl;

  /// Authorization token
  final String authToken;

  /// Thumbnail service instance
  final ThumbnailService thumbnailService;

  const SeekPreviewOverlay({
    super.key,
    required this.thumbnailCues,
    required this.seekPosition,
    required this.duration,
    required this.serverUrl,
    required this.authToken,
    required this.thumbnailService,
  });

  @override
  State<SeekPreviewOverlay> createState() => _SeekPreviewOverlayState();
}

class _SeekPreviewOverlayState extends State<SeekPreviewOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void didUpdateWidget(SeekPreviewOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Animate in when seeking starts
    if (widget.seekPosition != null && oldWidget.seekPosition == null) {
      _animationController.forward();
    }

    // Animate out when seeking stops
    if (widget.seekPosition == null && oldWidget.seekPosition != null) {
      _animationController.reverse();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Don't show if not seeking or no thumbnails available
    if (widget.seekPosition == null || widget.thumbnailCues.isEmpty) {
      return const SizedBox.shrink();
    }

    final seekPos = widget.seekPosition!;
    final cue = widget.thumbnailService.getThumbnailForTime(
      widget.thumbnailCues,
      seekPos,
    );

    if (cue == null) {
      return const SizedBox.shrink();
    }

    final spriteUrl = widget.thumbnailService.getSpriteUrl(cue.spriteFilename);

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Positioned(
        bottom: 100, // Position above seek bar
        left: 0,
        right: 0,
        child: Center(
          child: SeekPreview(
            cue: cue,
            spriteUrl: spriteUrl,
            seekPosition: seekPos,
            duration: widget.duration,
            authToken: widget.authToken,
          ),
        ),
      ),
    );
  }
}
