/// Stub implementation for device info - should never be called.
library;

Future<String> getDeviceName() async {
  throw UnsupportedError('Device info not supported on this platform');
}

String getPlatform() {
  throw UnsupportedError('Device info not supported on this platform');
}
