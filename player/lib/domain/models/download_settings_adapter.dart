part of 'download_settings.dart';

/// Hive adapter for DownloadSettings.
class DownloadSettingsAdapter extends TypeAdapter<DownloadSettings> {
  @override
  final int typeId = 3;

  @override
  DownloadSettings read(BinaryReader reader) {
    final numFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numFields; i++) {
      final key = reader.readByte();
      final value = reader.read();
      fields[key] = value;
    }
    return DownloadSettings(
      maxConcurrentDownloads: (fields[0] as int?) ?? 2,
      autoStartQueued: (fields[1] as bool?) ?? true,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadSettings obj) {
    writer.writeByte(2);
    writer.writeByte(0);
    writer.write(obj.maxConcurrentDownloads);
    writer.writeByte(1);
    writer.write(obj.autoStartQueued);
  }
}
