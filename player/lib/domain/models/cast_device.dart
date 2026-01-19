/// Represents a discovered Chromecast device on the network.
class CastDevice {
  final String id;
  final String name;
  final String? model;

  const CastDevice({
    required this.id,
    required this.name,
    this.model,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CastDevice && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CastDevice(id: $id, name: $name, model: $model)';
}

/// Represents the current state of casting playback.
enum CastPlaybackState {
  idle,
  buffering,
  playing,
  paused,
}

/// Information about the media being cast.
class CastMediaInfo {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Duration duration;
  final Duration position;

  const CastMediaInfo({
    required this.title,
    this.subtitle,
    this.imageUrl,
    required this.duration,
    required this.position,
  });

  CastMediaInfo copyWith({
    String? title,
    String? subtitle,
    String? imageUrl,
    Duration? duration,
    Duration? position,
  }) {
    return CastMediaInfo(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      imageUrl: imageUrl ?? this.imageUrl,
      duration: duration ?? this.duration,
      position: position ?? this.position,
    );
  }
}

/// Represents an active casting session.
class CastSession {
  final CastDevice device;
  final CastMediaInfo? mediaInfo;
  final CastPlaybackState playbackState;

  const CastSession({
    required this.device,
    this.mediaInfo,
    required this.playbackState,
  });

  CastSession copyWith({
    CastDevice? device,
    CastMediaInfo? mediaInfo,
    CastPlaybackState? playbackState,
  }) {
    return CastSession(
      device: device ?? this.device,
      mediaInfo: mediaInfo ?? this.mediaInfo,
      playbackState: playbackState ?? this.playbackState,
    );
  }
}
