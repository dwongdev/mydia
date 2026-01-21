// Stub implementation for web platform where Rust/iroh is not available.
// This file is conditionally imported on web to avoid loading the WASM module.

/// Stub RustLib class for web platform.
/// The real implementation is in frb_generated.dart (native only).
class RustLib {
  static Future<void> init() async {
    // No-op on web - Rust/iroh is not available
  }
}
