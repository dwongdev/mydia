import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../../../domain/models/app_update.dart';
import '../platform_updater.dart';

/// macOS updater: delegates to Sparkle 2 via a method channel.
///
/// Sparkle handles the entire update lifecycle natively: checking for updates,
/// showing UI, downloading, verifying EdDSA signatures, replacing the app
/// bundle, and relaunching.
class MacOSUpdater extends PlatformUpdater {
  static const _channel = MethodChannel('dev.mydia.player/sparkle');

  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    await checkForUpdates();
  }

  /// Triggers Sparkle's "Check for Updates" flow, which shows its own native
  /// macOS UI for download progress, release notes, and restart prompt.
  static Future<void> checkForUpdates() async {
    try {
      await _channel.invokeMethod('checkForUpdates');
    } on PlatformException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle checkForUpdates failed: $e');
    }
  }
}
