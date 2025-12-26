/// Web configuration for the Mydia player.
///
/// On web platform, Phoenix injects auth configuration into window.mydiaConfig.
/// This allows the Flutter web player to auto-authenticate without manual login.
library;

import 'web_config_stub.dart'
    if (dart.library.js_interop) 'web_config_web.dart' as impl;

/// Configuration injected by Phoenix for web auto-authentication.
class MydiaWebConfig {
  final bool authenticated;
  final String? token;
  final String? userId;
  final String? username;
  final String? serverUrl;

  const MydiaWebConfig({
    required this.authenticated,
    this.token,
    this.userId,
    this.username,
    this.serverUrl,
  });

  /// Check if this config has valid auth data.
  bool get hasValidAuth =>
      authenticated && token != null && token!.isNotEmpty && serverUrl != null;
}

/// Get the web configuration injected by Phoenix.
///
/// Returns null on non-web platforms or if no config was injected.
MydiaWebConfig? getWebConfig() => impl.getWebConfig();

/// Check if running on web platform.
bool get isWebPlatform => impl.isWebPlatform;

/// Get the current origin URL (for web platform).
///
/// Returns null on non-web platforms.
String? getOriginUrl() => impl.getOriginUrl();
