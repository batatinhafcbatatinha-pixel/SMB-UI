import 'dart:typed_data';
import 'smb_client.dart';
import 'mp4_duration.dart';

Future<double?> readRemoteMp4Duration({
  required String ip,
  required String share,
  required String path,
  String username = '',
  String password = '',
  int? fileSize,
}) async {
  try {
    fileSize ??= SMBClient.getCachedFileSize(ip, share, path);
    if (fileSize == null || fileSize <= 0) {
      final info = await SMBClient.getSmbFileInfo(
        ip,
        share,
        path,
        username: username,
        password: password,
      );
      fileSize = (info.data?['size'] as num?)?.toInt();
    }
    if (fileSize == null || fileSize <= 0) return null;
    return await readMp4Duration(fileSize, (offset, length) async {
      final result = await SMBClient.readSmbFileChunk(
        ip,
        share,
        path,
        offset: offset,
        length: length,
        username: username,
        password: password,
      );
      if (!result.success) throw StateError('Metadata read failed');
      return result.data?['bytes'] as Uint8List? ?? Uint8List(0);
    });
  } catch (_) {
    return null;
  }
}
