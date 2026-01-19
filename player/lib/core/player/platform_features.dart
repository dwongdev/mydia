import 'package:flutter/foundation.dart' show kIsWeb;

import 'platform_features_stub.dart'
    if (dart.library.io) 'platform_features_native.dart' as platform;

/// Service to detect platform-specific capabilities and features
class PlatformFeatures {
  /// Check if running on mobile (iOS or Android)
  static bool get isMobile {
    if (kIsWeb) return false;
    return platform.isIOS || platform.isAndroid;
  }

  /// Check if running on desktop (macOS, Windows, or Linux)
  static bool get isDesktop {
    if (kIsWeb) return false;
    return platform.isMacOS || platform.isWindows || platform.isLinux;
  }

  /// Check if running on iOS
  static bool get isIOS {
    if (kIsWeb) return false;
    return platform.isIOS;
  }

  /// Check if running on Android
  static bool get isAndroid {
    if (kIsWeb) return false;
    return platform.isAndroid;
  }

  /// Check if running on macOS
  static bool get isMacOS {
    if (kIsWeb) return false;
    return platform.isMacOS;
  }

  /// Check if running on Windows
  static bool get isWindows {
    if (kIsWeb) return false;
    return platform.isWindows;
  }

  /// Check if running on Linux
  static bool get isLinux {
    if (kIsWeb) return false;
    return platform.isLinux;
  }

  /// Check if running on web
  static bool get isWeb => kIsWeb;

  /// Check if gesture controls should be enabled (mobile only)
  static bool get supportsGestureControls => isMobile;

  /// Check if keyboard shortcuts should be enabled (desktop only)
  static bool get supportsKeyboardShortcuts => isDesktop;

  /// Check if Picture-in-Picture is supported (mobile only)
  static bool get supportsPiP => isMobile;

  /// Check if background audio is supported (mobile only)
  static bool get supportsBackgroundAudio => isMobile;

  /// Get a human-readable platform name
  static String get platformName {
    if (kIsWeb) return 'Web';
    return platform.platformName;
  }
}
