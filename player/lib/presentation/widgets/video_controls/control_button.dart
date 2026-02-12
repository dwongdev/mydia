import 'package:flutter/material.dart';

/// A reusable control button with a minimal flat style.
///
/// Used throughout the video controls for actions like play/pause,
/// seek forward/backward, fullscreen toggle, etc.
class ControlButton extends StatelessWidget {
  /// The icon to display.
  final IconData icon;

  /// Called when the button is tapped.
  final VoidCallback? onTap;

  /// The size of the button (width and height).
  final double size;

  /// The size of the icon.
  final double iconSize;

  /// The color of the icon.
  final Color iconColor;

  /// Optional tooltip text.
  final String? tooltip;

  /// Whether the button is enabled.
  final bool enabled;

  const ControlButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 48,
    this.iconSize = 28,
    this.iconColor = Colors.white,
    this.tooltip,
    this.enabled = true,
  });

  /// Creates a large control button, typically used for play/pause.
  const ControlButton.large({
    super.key,
    required this.icon,
    this.onTap,
    this.iconColor = Colors.white,
    this.tooltip,
    this.enabled = true,
  })  : size = 72,
        iconSize = 48;

  /// Creates a small control button for secondary actions.
  const ControlButton.small({
    super.key,
    required this.icon,
    this.onTap,
    this.iconColor = Colors.white,
    this.tooltip,
    this.enabled = true,
  })  : size = 40,
        iconSize = 20;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(size / 2),
          child: Center(
            child: Icon(
              icon,
              size: iconSize,
              color: enabled ? iconColor : iconColor.withValues(alpha: 0.5),
              shadows: const [
                Shadow(
                  color: Color(0x60000000),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(
        message: tooltip!,
        child: button,
      );
    }

    return button;
  }
}
