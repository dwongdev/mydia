import 'package:hive/hive.dart';
import 'download.dart';

/// Manual TypeAdapter for DownloadTask (typeId: 0)
class DownloadTaskAdapter extends TypeAdapter<DownloadTask> {
  @override
  final int typeId = 0;

  @override
  DownloadTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadTask(
      id: fields[0] as String,
      mediaId: fields[1] as String,
      title: fields[2] as String,
      quality: fields[3] as String,
      progress: fields[4] as double? ?? 0.0,
      status: fields[5] as String? ?? 'pending',
      mediaType: fields[6] as String? ?? 'movie',
      filePath: fields[7] as String?,
      fileSize: fields[8] as int?,
      downloadUrl: fields[9] as String?,
      posterUrl: fields[10] as String?,
      error: fields[11] as String?,
      createdAt: fields[12] as DateTime,
      completedAt: fields[13] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadTask obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.mediaId)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.quality)
      ..writeByte(4)
      ..write(obj.progress)
      ..writeByte(5)
      ..write(obj.status)
      ..writeByte(6)
      ..write(obj.mediaType)
      ..writeByte(7)
      ..write(obj.filePath)
      ..writeByte(8)
      ..write(obj.fileSize)
      ..writeByte(9)
      ..write(obj.downloadUrl)
      ..writeByte(10)
      ..write(obj.posterUrl)
      ..writeByte(11)
      ..write(obj.error)
      ..writeByte(12)
      ..write(obj.createdAt)
      ..writeByte(13)
      ..write(obj.completedAt);
  }
}

/// Manual TypeAdapter for DownloadedMedia (typeId: 1)
class DownloadedMediaAdapter extends TypeAdapter<DownloadedMedia> {
  @override
  final int typeId = 1;

  @override
  DownloadedMedia read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadedMedia(
      id: fields[0] as String,
      mediaId: fields[1] as String,
      title: fields[2] as String,
      quality: fields[3] as String,
      filePath: fields[4] as String,
      fileSize: fields[5] as int,
      mediaType: fields[6] as String? ?? 'movie',
      posterUrl: fields[7] as String?,
      downloadedAt: fields[8] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadedMedia obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.mediaId)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.quality)
      ..writeByte(4)
      ..write(obj.filePath)
      ..writeByte(5)
      ..write(obj.fileSize)
      ..writeByte(6)
      ..write(obj.mediaType)
      ..writeByte(7)
      ..write(obj.posterUrl)
      ..writeByte(8)
      ..write(obj.downloadedAt);
  }
}
