/// Stub implementation for web platform.
///
/// On web, all platform checks return false since dart:io is not available.
library;

bool get isIOS => false;
bool get isAndroid => false;
bool get isMacOS => false;
bool get isWindows => false;
bool get isLinux => false;
String get platformName => 'Unknown';
