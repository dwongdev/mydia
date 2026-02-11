import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// A large centered play/pause button with animated icon transition.
///
/// Subscribes to the player's playing state stream and displays
/// the appropriate icon with a smooth animation between states.
class CenterPlayButton extends StatelessWidget {
  /// The media_kit player instance.
  final Player player;

  /// The size of the button.
  final double size;

  /// The size of the icon.
  final double iconSize;

  const CenterPlayButton({
    super.key,
    required this.player,
    this.size = 72,
    this.iconSize = 48,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;

        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                if (isPlaying) {
                  player.pause();
                } else {
                  player.play();
                }
              },
              borderRadius: BorderRadius.circular(size / 2),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: FadeTransition(
                        opacity: animation,
                        child: child,
                      ),
                    );
                  },
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(isPlaying),
                    size: iconSize,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
