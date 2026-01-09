/// Background direct URL probing for relay-first connection strategy.
///
/// This service probes direct URLs in the background after relay connection
/// is established, enabling transparent upgrade to direct connection when
/// available.
///
/// ## Probe Sequence
///
/// 1. TCP connection established
/// 2. TLS handshake completes (verify certificate fingerprint)
/// 3. Phoenix channel join succeeds
///
/// ## Probe Frequency
///
/// - First probe: Immediately after pairing/reconnection completes
/// - On failure: Exponential backoff (5s, 10s, 30s, 60s, max 5min)
/// - On network change: Immediate re-probe
/// - On app foreground: Re-probe if currently on relay
///
/// ## Usage
///
/// ```dart
/// final prober = DirectProber(
///   directUrls: ['https://mydia.local', 'https://192.168.1.5:4000'],
///   certFingerprint: 'aa:bb:cc:...',
///   channelService: channelService,
/// );
///
/// prober.results.listen((result) {
///   if (result.success) {
///     // Trigger hot swap to direct connection
///   }
/// });
///
/// prober.startProbing();
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../auth/auth_storage.dart';
import '../channels/channel_service.dart';

/// Storage keys for probe diagnostics.
abstract class _ProbeStorageKeys {
  static const lastProbeTime = 'diagnostics_last_direct_attempt';
  static const urlResults = 'diagnostics_direct_url_errors';
}

/// Result of a single URL probe attempt.
class UrlProbeResult {
  /// The URL that was probed.
  final String url;

  /// Whether the probe was successful.
  final bool success;

  /// Error message if the probe failed.
  final String? error;

  /// When this probe was attempted.
  final DateTime timestamp;

  const UrlProbeResult({
    required this.url,
    required this.success,
    this.error,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'success': success,
        'error': error,
        'timestamp': timestamp.toIso8601String(),
      };

  factory UrlProbeResult.fromJson(Map<String, dynamic> json) {
    return UrlProbeResult(
      url: json['url'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

/// Result of a direct URL probe attempt.
class ProbeResult {
  /// Whether the probe was successful.
  final bool success;

  /// The URL that was successfully probed (null if failed).
  final String? successfulUrl;

  /// Error message (null if successful).
  final String? error;

  /// Number of URLs that were attempted.
  final int urlsAttempted;

  /// Current failure count (for backoff calculation).
  final int failureCount;

  /// Individual results for each URL probed.
  final List<UrlProbeResult> urlResults;

  const ProbeResult._({
    required this.success,
    this.successfulUrl,
    this.error,
    required this.urlsAttempted,
    required this.failureCount,
    this.urlResults = const [],
  });

  factory ProbeResult.success({
    required String url,
    required int urlsAttempted,
    List<UrlProbeResult> urlResults = const [],
  }) {
    return ProbeResult._(
      success: true,
      successfulUrl: url,
      urlsAttempted: urlsAttempted,
      failureCount: 0,
      urlResults: urlResults,
    );
  }

  factory ProbeResult.failure({
    required String error,
    required int urlsAttempted,
    required int failureCount,
    List<UrlProbeResult> urlResults = const [],
  }) {
    return ProbeResult._(
      success: false,
      error: error,
      urlsAttempted: urlsAttempted,
      failureCount: failureCount,
      urlResults: urlResults,
    );
  }
}

/// Background prober for testing direct URL connectivity.
///
/// This class implements the probing logic for the relay-first connection
/// strategy, testing direct URLs in the background and reporting results
/// via a stream.
class DirectProber {
  DirectProber({
    required List<String> directUrls,
    String? certFingerprint,
    ChannelService? channelService,
    Duration probeTimeout = const Duration(seconds: 5),
  })  : _directUrls = List.unmodifiable(directUrls),
        _certFingerprint = certFingerprint,
        _channelService = channelService ?? ChannelService(),
        _probeTimeout = probeTimeout;

  final List<String> _directUrls;
  final String? _certFingerprint;
  final ChannelService _channelService;
  final Duration _probeTimeout;

  /// Stream controller for probe results.
  final _resultController = StreamController<ProbeResult>.broadcast();

  /// Exponential backoff delays.
  static const _backoffDelays = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 5),
  ];

  /// Current probe timer.
  Timer? _probeTimer;

  /// Current failure count for backoff calculation.
  int _failureCount = 0;

  /// Whether probing is currently active.
  bool _isProbing = false;

  /// Whether a probe is currently in progress.
  bool _probeInProgress = false;

  /// App lifecycle listener for foreground detection.
  AppLifecycleListener? _lifecycleListener;

  /// Stream of probe results.
  ///
  /// Listen to this stream to receive notifications when probe attempts
  /// complete, either successfully or with failure.
  Stream<ProbeResult> get results => _resultController.stream;

  /// Whether probing is currently active.
  bool get isProbing => _isProbing;

  /// Current failure count.
  int get failureCount => _failureCount;

  /// Starts background probing.
  ///
  /// This begins the probing cycle:
  /// 1. Performs immediate probe
  /// 2. Schedules retries with exponential backoff on failure
  /// 3. Listens for app lifecycle changes to re-probe on foreground
  ///
  /// Call [stopProbing] to cancel.
  void startProbing() {
    if (_isProbing) return;
    if (_directUrls.isEmpty) {
      debugPrint('[DirectProber] No direct URLs to probe');
      return;
    }

    _isProbing = true;
    _failureCount = 0;
    debugPrint('[DirectProber] Starting background probing for ${_directUrls.length} URLs');

    // Start lifecycle listener for foreground detection
    _startLifecycleListener();

    // Perform immediate probe
    _performProbe();
  }

  /// Stops background probing.
  ///
  /// Cancels any pending probe timers and cleans up resources.
  void stopProbing() {
    if (!_isProbing) return;

    _isProbing = false;
    _probeTimer?.cancel();
    _probeTimer = null;
    _stopLifecycleListener();
    debugPrint('[DirectProber] Stopped background probing');
  }

  /// Triggers an immediate probe attempt.
  ///
  /// Use this when network conditions change or when returning
  /// to the app from background.
  void probeNow() {
    if (!_isProbing) {
      debugPrint('[DirectProber] Cannot probe - not active');
      return;
    }

    if (_probeInProgress) {
      debugPrint('[DirectProber] Probe already in progress, skipping');
      return;
    }

    // Cancel any pending scheduled probe
    _probeTimer?.cancel();
    _probeTimer = null;

    // Reset backoff on manual trigger
    _failureCount = 0;

    _performProbe();
  }

  /// Resets the failure count and restarts probing.
  ///
  /// Use this when network connectivity is restored.
  void resetAndProbe() {
    _failureCount = 0;
    probeNow();
  }

  /// Performs a single probe attempt.
  Future<void> _performProbe() async {
    if (!_isProbing || _probeInProgress) return;

    _probeInProgress = true;
    debugPrint('[DirectProber] Probing ${_directUrls.length} direct URLs...');

    try {
      final result = await _probeDirectUrls();

      if (!_isProbing) {
        // Probing was stopped during the probe
        return;
      }

      _resultController.add(result);

      if (result.success) {
        debugPrint('[DirectProber] Probe successful: ${result.successfulUrl}');
        // Success - stop probing, caller will handle hot swap
        _isProbing = false;
      } else {
        debugPrint('[DirectProber] Probe failed: ${result.error}');
        _failureCount = result.failureCount;
        _scheduleNextProbe();
      }
    } finally {
      _probeInProgress = false;
    }
  }

  /// Probes all direct URLs and returns the result.
  Future<ProbeResult> _probeDirectUrls() async {
    final urlResults = <UrlProbeResult>[];
    final now = DateTime.now();

    for (var i = 0; i < _directUrls.length; i++) {
      final url = _directUrls[i];
      debugPrint('[DirectProber] Probing URL ${i + 1}/${_directUrls.length}: $url');

      final probeResult = await _probeUrl(url);
      urlResults.add(probeResult);

      if (probeResult.success) {
        // Persist results to storage
        await _persistProbeResults(urlResults, now);

        return ProbeResult.success(
          url: url,
          urlsAttempted: i + 1,
          urlResults: urlResults,
        );
      }
    }

    // Persist results to storage
    await _persistProbeResults(urlResults, now);

    return ProbeResult.failure(
      error: 'All ${_directUrls.length} direct URLs failed',
      urlsAttempted: _directUrls.length,
      failureCount: _failureCount + 1,
      urlResults: urlResults,
    );
  }

  /// Persists probe results to storage for display in settings.
  Future<void> _persistProbeResults(List<UrlProbeResult> results, DateTime timestamp) async {
    try {
      final storage = getAuthStorage();

      // Save last probe time
      await storage.write(
        _ProbeStorageKeys.lastProbeTime,
        timestamp.toIso8601String(),
      );

      // Save URL results as a map keyed by URL
      final resultsMap = <String, Map<String, dynamic>>{};
      for (final result in results) {
        resultsMap[result.url] = result.toJson();
      }
      await storage.write(
        _ProbeStorageKeys.urlResults,
        jsonEncode(resultsMap),
      );

      debugPrint('[DirectProber] Persisted probe results for ${results.length} URLs');
    } catch (e) {
      debugPrint('[DirectProber] Failed to persist probe results: $e');
    }
  }

  /// Probes a single URL.
  ///
  /// Returns a [UrlProbeResult] with success/failure status and error message.
  Future<UrlProbeResult> _probeUrl(String url) async {
    final timestamp = DateTime.now();

    try {
      // Create a dedicated channel service for probing to avoid
      // interfering with any active connections
      final probeService = ChannelService();

      try {
        // Step 1: TCP connection + TLS handshake
        final connectResult = await probeService
            .connect(url)
            .timeout(_probeTimeout, onTimeout: () {
          return ChannelResult.error('Connection timeout');
        });

        if (!connectResult.success) {
          final error = connectResult.error ?? 'Connection failed';
          debugPrint('[DirectProber] Connection failed for $url: $error');
          return UrlProbeResult(
            url: url,
            success: false,
            error: error,
            timestamp: timestamp,
          );
        }

        // TODO: Step 2 - Verify certificate fingerprint
        // This requires implementing certificate pinning in the HTTP client.
        // For now, we skip this check.
        // if (_certFingerprint != null) {
        //   final verified = await _verifyCertificate(url, _certFingerprint!);
        //   if (!verified) {
        //     debugPrint('[DirectProber] Certificate verification failed for $url');
        //     await probeService.disconnect();
        //     return UrlProbeResult(...);
        //   }
        // }

        // Step 3: Phoenix channel join (probe channel)
        // We join a lightweight "probe" topic just to verify the connection works
        // The server should have a "probe:ping" channel or similar
        final joinResult = await probeService
            .joinProbeChannel()
            .timeout(_probeTimeout, onTimeout: () {
          return ChannelResult.error('Channel join timeout');
        });

        // Disconnect probe service - we don't need it anymore
        await probeService.disconnect();

        if (!joinResult.success) {
          final error = joinResult.error ?? 'Channel join failed';
          debugPrint('[DirectProber] Channel join failed for $url: $error');
          return UrlProbeResult(
            url: url,
            success: false,
            error: error,
            timestamp: timestamp,
          );
        }

        debugPrint('[DirectProber] Probe successful for $url');
        return UrlProbeResult(
          url: url,
          success: true,
          timestamp: timestamp,
        );
      } catch (e) {
        debugPrint('[DirectProber] Probe error for $url: $e');
        await probeService.disconnect();
        return UrlProbeResult(
          url: url,
          success: false,
          error: e.toString(),
          timestamp: timestamp,
        );
      }
    } catch (e) {
      debugPrint('[DirectProber] Unexpected error probing $url: $e');
      return UrlProbeResult(
        url: url,
        success: false,
        error: e.toString(),
        timestamp: timestamp,
      );
    }
  }

  /// Schedules the next probe attempt with exponential backoff.
  void _scheduleNextProbe() {
    if (!_isProbing) return;

    final delayIndex = _failureCount.clamp(0, _backoffDelays.length - 1);
    final delay = _backoffDelays[delayIndex];

    debugPrint('[DirectProber] Scheduling next probe in ${delay.inSeconds}s (failure count: $_failureCount)');

    _probeTimer?.cancel();
    _probeTimer = Timer(delay, () {
      if (_isProbing) {
        _performProbe();
      }
    });
  }

  /// Starts the app lifecycle listener.
  void _startLifecycleListener() {
    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        debugPrint('[DirectProber] App resumed, triggering probe');
        probeNow();
      },
    );
  }

  /// Stops the app lifecycle listener.
  void _stopLifecycleListener() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
  }

  /// Disposes of resources.
  void dispose() {
    stopProbing();
    _resultController.close();
  }
}
