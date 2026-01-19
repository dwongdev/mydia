// Stub implementation for web platform where Rust/libp2p is not available.
// This file is conditionally imported on web to avoid loading the WASM module.

/// Stub RustLib class for web platform.
/// The real implementation is in frb_generated.dart (native only).
class RustLib {
  static Future<void> init() async {
    // No-op on web - Rust/libp2p is not available
  }
}
