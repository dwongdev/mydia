// Stub implementation for non-web platforms.
// The web implementation is in web_lifecycle_web.dart.

typedef BeforeUnloadCallback = void Function();

/// Register a callback to be called before the page unloads.
/// This is a no-op on non-web platforms.
void registerBeforeUnload(BeforeUnloadCallback callback) {
  // No-op on non-web platforms
}

/// Unregister the beforeunload callback.
/// This is a no-op on non-web platforms.
void unregisterBeforeUnload() {
  // No-op on non-web platforms
}
