import 'dart:ui';

import 'package:flutter/material.dart';

/// A container with a frosted glass (glassmorphism) effect.
///
/// Uses BackdropFilter to create a blur effect with a semi-transparent
/// dark background and subtle white border for a modern, sleek appearance.
class GlassContainer extends StatelessWidget {
  /// The child widget to display inside the container.
  final Widget child;

  /// The border radius of the container.
  final BorderRadius borderRadius;

  /// The padding inside the container.
  final EdgeInsetsGeometry padding;

  /// The blur intensity (sigma value for both X and Y).
  final double blurSigma;

  /// The background color opacity (0.0 - 1.0).
  final double backgroundOpacity;

  /// Whether to show the border.
  final bool showBorder;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.padding = const EdgeInsets.all(12),
    this.blurSigma = 10.0,
    this.backgroundOpacity = 0.3,
    this.showBorder = true,
  });

  /// Creates a circular glass container, useful for buttons.
  GlassContainer.circular({
    super.key,
    required this.child,
    double radius = 28,
    this.padding = EdgeInsets.zero,
    this.blurSigma = 10.0,
    this.backgroundOpacity = 0.3,
    this.showBorder = true,
  }) : borderRadius = BorderRadius.all(Radius.circular(radius));

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: backgroundOpacity),
            borderRadius: borderRadius,
            border: showBorder
                ? Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  )
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
