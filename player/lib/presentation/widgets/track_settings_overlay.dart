import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../domain/models/subtitle_track.dart';
import 'hls_quality_selector.dart';

/// Shows settings button and subtitle indicator as overlay on video player
class TrackSettingsOverlay extends StatelessWidget {
  final VoidCallback onSettingsTap;
  final SubtitleTrack? selectedSubtitleTrack;

  const TrackSettingsOverlay({
    super.key,
    required this.onSettingsTap,
    this.selectedSubtitleTrack,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Settings button (top right)
        Positioned(
          top: 8,
          right: 8,
          child: IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: onSettingsTap,
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withOpacity(0.5),
            ),
            tooltip: 'Audio & Subtitles',
          ),
        ),
        // Subtitle indicator (bottom right)
        if (selectedSubtitleTrack != null)
          Positioned(
            bottom: 80,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.subtitles, color: Colors.white, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    selectedSubtitleTrack!.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Shows the track settings bottom sheet
Future<void> showTrackSettingsSheet(
  BuildContext context, {
  required VoidCallback onSubtitleTap,
  required SubtitleTrack? selectedSubtitleTrack,
  required bool loadingSubtitles,
  required int subtitleTrackCount,
  VoidCallback? onQualityTap,
  HlsQualityLevel? selectedQuality,
}) async {
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Playback Settings',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          // Quality selection (web only - HLS adaptive streaming)
          if (kIsWeb && onQualityTap != null)
            ListTile(
              leading: const Icon(Icons.high_quality, color: Colors.white),
              title: const Text(
                'Quality',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                selectedQuality?.label ?? 'Auto',
                style: const TextStyle(color: Colors.grey),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: () {
                Navigator.pop(context);
                onQualityTap();
              },
            ),
          ListTile(
            leading: const Icon(Icons.subtitles, color: Colors.white),
            title: const Text(
              'Subtitles',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              selectedSubtitleTrack?.displayName ?? 'Off',
              style: const TextStyle(color: Colors.grey),
            ),
            trailing: loadingSubtitles
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.red,
                    ),
                  )
                : const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.pop(context);
              onSubtitleTap();
            },
          ),
          ListTile(
            leading: const Icon(Icons.audiotrack, color: Colors.white),
            title: const Text(
              'Audio Track',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Coming soon',
              style: TextStyle(color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Audio track selection is coming soon. '
                    'The video player package has limited multi-audio support on web.',
                  ),
                  duration: Duration(seconds: 3),
                ),
              );
            },
          ),
          if (subtitleTrackCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '$subtitleTrackCount subtitle track(s) available',
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
