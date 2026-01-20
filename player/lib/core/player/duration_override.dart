import 'package:flutter/foundation.dart';

/// Provides a way to override the reported duration from the player.
/// This is useful for HLS live-style playlists where the total duration
/// isn't known until transcoding completes.
///
/// Usage:
/// - Set `DurationOverride.value` when you know the total duration
/// - Clear it (set to null) when the player disposes
/// - Use `DurationOverride.getDuration(playerDuration)` to get the best duration
class DurationOverride {
  static Duration? _value;

  /// The override duration, or null if no override is set.
  static Duration? get value => _value;

  /// Set the override duration.
  static set value(Duration? duration) {
    _value = duration;
    debugPrint('DurationOverride set to: $duration');
  }

  /// Clear the override duration.
  static void clear() {
    _value = null;
    debugPrint('DurationOverride cleared');
  }

  /// Get the best available duration.
  /// Returns the override if set and greater than the player duration,
  /// otherwise returns the player duration.
  static Duration getDuration(Duration playerDuration) {
    final override = _value;
    if (override != null && override > playerDuration) {
      return override;
    }
    return playerDuration;
  }
}
