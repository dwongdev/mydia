part of 'storage_settings.dart';

/// Hive adapter for StorageSettings.
class StorageSettingsAdapter extends TypeAdapter<StorageSettings> {
  @override
  final int typeId = 2;

  @override
  StorageSettings read(BinaryReader reader) {
    final numFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numFields; i++) {
      final key = reader.readByte();
      final value = reader.read();
      fields[key] = value;
    }
    return StorageSettings(
      maxStorageBytes: fields[0] as int?,
      warningThreshold: (fields[1] as double?) ?? 0.9,
      autoCleanupEnabled: (fields[2] as bool?) ?? false,
      cleanupPolicyValue: (fields[3] as String?) ?? 'byDate',
    );
  }

  @override
  void write(BinaryWriter writer, StorageSettings obj) {
    writer.writeByte(4);
    writer.writeByte(0);
    writer.write(obj.maxStorageBytes);
    writer.writeByte(1);
    writer.write(obj.warningThreshold);
    writer.writeByte(2);
    writer.write(obj.autoCleanupEnabled);
    writer.writeByte(3);
    writer.write(obj.cleanupPolicyValue);
  }
}
