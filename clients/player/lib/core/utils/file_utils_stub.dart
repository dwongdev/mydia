/// Stub implementation for web platform.
///
/// On web, local file access is not supported.
library;

Future<bool> fileExists(String path) async => false;
