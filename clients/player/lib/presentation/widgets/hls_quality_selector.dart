import 'package:flutter/material.dart';

/// Represents a quality/bitrate level for HLS adaptive streaming
class HlsQualityLevel {
  final String label;
  final int? height;
  final int? bitrate;
  final bool isAuto;

  const HlsQualityLevel({
    required this.label,
    this.height,
    this.bitrate,
    this.isAuto = false,
  });

  /// Auto quality - lets HLS automatically select based on bandwidth
  static const auto = HlsQualityLevel(
    label: 'Auto',
    isAuto: true,
  );

  /// Predefined quality levels that match common HLS variants
  static const List<HlsQualityLevel> standardLevels = [
    auto,
    HlsQualityLevel(label: '1080p', height: 1080),
    HlsQualityLevel(label: '720p', height: 720),
    HlsQualityLevel(label: '480p', height: 480),
    HlsQualityLevel(label: '360p', height: 360),
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HlsQualityLevel &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          height == other.height &&
          bitrate == other.bitrate &&
          isAuto == other.isAuto;

  @override
  int get hashCode =>
      label.hashCode ^ height.hashCode ^ bitrate.hashCode ^ isAuto.hashCode;
}

/// Shows a quality selector dialog for HLS adaptive streaming
Future<HlsQualityLevel?> showHlsQualitySelector(
  BuildContext context,
  HlsQualityLevel currentQuality,
) async {
  return showDialog<HlsQualityLevel>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Colors.grey[900],
      title: const Text(
        'Video Quality',
        style: TextStyle(color: Colors.white),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: HlsQualityLevel.standardLevels.map((level) {
            final isSelected = level == currentQuality;
            return ListTile(
              leading: Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected ? Colors.red : Colors.grey,
              ),
              title: Text(
                level.label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[300],
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              subtitle: level.isAuto
                  ? const Text(
                      'Adapts to your connection',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    )
                  : null,
              onTap: () {
                Navigator.of(context).pop(level);
              },
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      ],
    ),
  );
}
