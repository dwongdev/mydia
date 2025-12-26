import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'cast_service.dart';
import '../../domain/models/cast_device.dart';

/// Provider for the CastService singleton.
final castServiceProvider = Provider<CastService>((ref) {
  final service = CastService();

  // Start discovery when service is created
  service.startDiscovery();

  // Clean up when provider is disposed
  ref.onDispose(() {
    service.stopDiscovery();
    service.dispose();
  });

  return service;
});

/// Provider for the stream of available Chromecast devices.
final availableDevicesProvider = StreamProvider<List<CastDevice>>((ref) {
  final service = ref.watch(castServiceProvider);
  return service.devicesStream;
});

/// Provider for the current casting session.
final castSessionProvider = StreamProvider<CastSession?>((ref) {
  final service = ref.watch(castServiceProvider);
  return service.sessionStream;
});

/// Provider that returns true if actively casting.
final isCastingProvider = Provider<bool>((ref) {
  final sessionAsync = ref.watch(castSessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session != null,
    orElse: () => false,
  );
});

/// Provider that returns the current cast device, if any.
final currentCastDeviceProvider = Provider<CastDevice?>((ref) {
  final sessionAsync = ref.watch(castSessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session?.device,
    orElse: () => null,
  );
});

/// Provider for cast media info.
final castMediaInfoProvider = Provider<CastMediaInfo?>((ref) {
  final sessionAsync = ref.watch(castSessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session?.mediaInfo,
    orElse: () => null,
  );
});

/// Provider for cast playback state.
final castPlaybackStateProvider = Provider<CastPlaybackState>((ref) {
  final sessionAsync = ref.watch(castSessionProvider);
  return sessionAsync.maybeWhen(
    data: (session) => session?.playbackState ?? CastPlaybackState.idle,
    orElse: () => CastPlaybackState.idle,
  );
});
