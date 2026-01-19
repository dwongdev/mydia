/// Domain model for a remote device paired to a user account.
class RemoteDevice {
  final String id;
  final String deviceName;
  final String platform;
  final DateTime? lastSeenAt;
  final bool isRevoked;
  final DateTime createdAt;

  const RemoteDevice({
    required this.id,
    required this.deviceName,
    required this.platform,
    this.lastSeenAt,
    required this.isRevoked,
    required this.createdAt,
  });

  /// Check if this device was recently active (within last 24 hours).
  bool get isRecentlyActive {
    if (lastSeenAt == null) return false;
    final now = DateTime.now();
    final difference = now.difference(lastSeenAt!);
    return difference.inHours < 24;
  }

  /// Get human-readable status text.
  String get statusText {
    if (isRevoked) return 'Revoked';
    if (lastSeenAt == null) return 'Never active';
    if (isRecentlyActive) return 'Active';
    return 'Inactive';
  }

  /// Get relative time string for last seen.
  String get lastSeenRelative {
    if (lastSeenAt == null) return 'Never';

    final now = DateTime.now();
    final difference = now.difference(lastSeenAt!);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} ago';
    } else if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
    } else if (difference.inDays < 30) {
      final days = difference.inDays;
      return '$days ${days == 1 ? 'day' : 'days'} ago';
    } else if (difference.inDays < 365) {
      final months = (difference.inDays / 30).floor();
      return '$months ${months == 1 ? 'month' : 'months'} ago';
    } else {
      final years = (difference.inDays / 365).floor();
      return '$years ${years == 1 ? 'year' : 'years'} ago';
    }
  }

  /// Get platform icon name.
  String get platformIcon {
    switch (platform.toLowerCase()) {
      case 'ios':
        return 'phone_iphone';
      case 'android':
        return 'phone_android';
      case 'web':
        return 'language';
      default:
        return 'devices';
    }
  }
}
