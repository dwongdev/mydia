import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../domain/models/audio_track.dart';
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
  required int subtitleTrackCount,
  VoidCallback? onAudioTap,
  AudioTrack? selectedAudioTrack,
  int audioTrackCount = 0,
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
          // Audio track selection
          ListTile(
            leading: const Icon(Icons.audiotrack, color: Colors.white),
            title: const Text(
              'Audio',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              audioTrackCount > 0
                  ? (selectedAudioTrack?.displayName ?? 'Default')
                  : 'Default',
              style: const TextStyle(color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: audioTrackCount > 0 && onAudioTap != null
                ? () {
                    Navigator.pop(context);
                    onAudioTap();
                  }
                : null,
          ),
          // Subtitle selection
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
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.pop(context);
              onSubtitleTap();
            },
          ),
          // Track count summary
          if (audioTrackCount > 0 || subtitleTrackCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                [
                  if (audioTrackCount > 0) '$audioTrackCount audio track(s)',
                  if (subtitleTrackCount > 0)
                    '$subtitleTrackCount subtitle track(s)',
                ].join(', '),
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
