import 'package:flutter/material.dart';

/// Mydia Design System Colors
///
/// These colors align with the DaisyUI theme used in the Phoenix web app.
/// See docs/architecture/design.md and docs/architecture/colors.md for details.
class AppColors {
  // Base colors - Slate palette for backgrounds
  static const Color background = Color(0xFF0F172A); // Slate-900 (base-100)
  static const Color surface = Color(0xFF1E293B); // Slate-800 (base-200)
  static const Color surfaceVariant = Color(0xFF334155); // Slate-700 (base-300)

  // Primary - Blue (main actions, selected items, links)
  static const Color primary = Color(0xFF3B82F6); // Blue-500
  static const Color primaryFocus = Color(0xFF2563EB); // Blue-600

  // Secondary - Violet (premium features, secondary actions)
  static const Color secondary = Color(0xFF8B5CF6); // Violet-500
  static const Color secondaryFocus = Color(0xFF7C3AED); // Violet-600

  // Accent - Cyan (quality badges, highlights)
  static const Color accent = Color(0xFF06B6D4); // Cyan-500
  static const Color accentFocus = Color(0xFF0891B2); // Cyan-600

  // Neutral - Gray (subtle elements)
  static const Color neutral = Color(0xFF1F2937); // Gray-800
  static const Color neutralFocus = Color(0xFF111827); // Gray-900

  // Semantic colors
  static const Color error = Color(0xFFEF4444); // Red-500
  static const Color warning = Color(0xFFF59E0B); // Amber-500
  static const Color info = Color(0xFF3B82F6); // Blue-500
  static const Color success = Color(0xFF10B981); // Emerald-500

  // Text colors - Slate palette
  static const Color textPrimary = Color(0xFFF1F5F9); // Slate-100 (base-content)
  static const Color textSecondary = Color(0xFF94A3B8); // Slate-400
  static const Color textDisabled = Color(0xFF64748B); // Slate-500

  // Border colors
  static const Color divider = Color(0xFF334155); // Slate-700
  static const Color border = Color(0xFF475569); // Slate-600

  // Overlay colors (for hover states)
  static const Color overlayDark = Color(0xCC000000); // 80% opacity black
  static const Color overlayLight = Color(0x40000000); // 25% opacity black

  // Card hover color
  static const Color cardHover = Color(0xFF475569); // Slate-600

  // Shimmer colors (for loading states)
  static const Color shimmerBase = Color(0xFF334155); // Slate-700
  static const Color shimmerHighlight = Color(0xFF475569); // Slate-600

  // Content colors (text on colored backgrounds)
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color onSecondary = Color(0xFFFFFFFF);
  static const Color onAccent = Color(0xFFFFFFFF);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color onWarning = Color(0xFF000000);
  static const Color onSuccess = Color(0xFFFFFFFF);
}
