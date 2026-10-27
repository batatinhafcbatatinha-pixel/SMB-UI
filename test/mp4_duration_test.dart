import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_media_viewer/utils/mp4_duration.dart';

Uint8List box(String type, List<int> data, {bool extended = false}) {
  final header = Uint8List(extended ? 16 : 8);
  final view = ByteData.sublistView(header);
  view.setUint32(0, extended ? 1 : header.length + data.length);
  header.setRange(4, 8, type.codeUnits);
  if (extended) view.setUint64(8, header.length + data.length);
  return Uint8List.fromList([...header, ...data]);
}

Uint8List movie({int version = 0, bool extended = false}) {
  final data = Uint8List(100);
  data[0] = version;
  final view = ByteData.sublistView(data);
  view.setUint32(version == 0 ? 12 : 20, 1000);
  if (version == 0) {
    view.setUint32(16, 51083);
  } else {
    view.setUint64(24, 51083);
  }
  return box('moov', box('mvhd', data), extended: extended);
}

void main() {
  for (final version in [0, 1]) {
    test('reads v$version mvhd inside extended movie box', () async {
      final bytes = movie(version: version, extended: true);
      expect(
        await readMp4Duration(
          bytes.length,
          (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        ),
        closeTo(51.083, .0001),
      );
    });
  }
  test(
    'seeks past a 2GB mdat; large tail moov need not fit in a read',
    () async {
      const mediaSize = 2 * 1024 * 1024 * 1024;
      final mediaHeader = box('mdat', []);
      ByteData.sublistView(mediaHeader).setUint32(0, mediaSize);
      final tail = movie();
      ByteData.sublistView(tail).setUint32(0, 1000000);
      var bytesRead = 0;
      final offsets = <int>[];
      final duration = await readMp4Duration(mediaSize + 1000000, (
        offset,
        length,
      ) async {
        offsets.add(offset);
        bytesRead += length;
        final result = Uint8List(length);
        final source = offset == 0 ? mediaHeader : tail;
        result.setRange(0, source.length, source);
        return result;
      });
      expect(duration, closeTo(51.083, .0001));
      expect(offsets, [0, mediaSize]);
      expect(bytesRead, 8192);
    },
  );
  test('malformed, truncated and unsupported input returns null', () async {
    for (final bytes in [
      Uint8List(4),
      box('mdat', []),
      Uint8List(16),
      movie(version: 2),
    ]) {
      expect(
        await readMp4Duration(
          bytes.length,
          (offset, length) async =>
              Uint8List.sublistView(bytes, offset, offset + length),
        ),
        isNull,
      );
    }
  });
}
