/// Stub implementation for non-web platforms.
library;

import 'web_config.dart';

/// Non-web platforms don't have injected config.
MydiaWebConfig? getWebConfig() => null;

/// Not running on web.
bool get isWebPlatform => false;

/// Non-web platforms don't have an origin URL.
String? getOriginUrl() => null;

/// No-op on non-web platforms.
void navigateToMydiaApp() {}
