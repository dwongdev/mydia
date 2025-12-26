/// Native platform detection using dart:io.
library;

import 'dart:io' show Platform;

bool get isIOS => Platform.isIOS;
bool get isAndroid => Platform.isAndroid;
bool get isMacOS => Platform.isMacOS;
bool get isWindows => Platform.isWindows;
bool get isLinux => Platform.isLinux;

String get platformName {
  if (Platform.isIOS) return 'iOS';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  return 'Unknown';
}
