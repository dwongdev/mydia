import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/downloads/download_service.dart';

import 'package:player/native/frb_generated.dart';

void main() async {
  // Add error logging for debugging
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('Flutter error: ${details.exception}');
    debugPrint('Stack trace: ${details.stack}');
  };

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Initialize Rust Bridge
      try {
        await RustLib.init();
      } catch (e) {
        debugPrint('Failed to initialize Rust bridge: $e');
      }

      // Initialize media_kit for video playback
      MediaKit.ensureInitialized();

      // TODO: Chromecast support temporarily disabled due to API incompatibility
      // with flutter_chrome_cast package. See backlog task for fix.
      // await _initializeCastSdk();

      // Initialize GraphQL Hive cache for offline support
      await initHiveForFlutter();

      // Initialize download database (only on native platforms)
      if (isDownloadSupported) {
        final downloadDb = getDownloadDatabase();
        await downloadDb.initialize();
      }

      runApp(
        const ProviderScope(
          child: MyApp(),
        ),
      );
    },
    (error, stack) {
      debugPrint('Caught error: $error');
      debugPrint('Stack trace: $stack');
    },
  );
}
