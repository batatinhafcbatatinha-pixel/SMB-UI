import 'dart:math' as math;
import 'dart:typed_data';

typedef RangeReader = Future<Uint8List> Function(int offset, int length);

/// Bounded ISO BMFF traversal, including extended sizes and tail moov atoms.
/// Skips mdat and never requires a whole moov to fit in memory.
Future<double?> readMp4Duration(int fileSize, RangeReader read) async {
  var offset = 0;
  var end = fileSize;
  var insideMovie = false;
  var window = Uint8List(0);
  var windowStart = -1;
  Future<Uint8List> bytesAt(int position, int count) async {
    if (position < windowStart ||
        position + count > windowStart + window.length) {
      windowStart = position;
      window = await read(position, math.min(4096, fileSize - position));
    }
    final start = position - windowStart;
    if (start < 0 || start + count > window.length) return Uint8List(0);
    return Uint8List.sublistView(window, start, start + count);
  }

  for (var boxes = 0; boxes < 128 && offset + 8 <= end; boxes++) {
    final header = await bytesAt(offset, 8);
    if (header.length < 8) return null;
    final data = ByteData.sublistView(header);
    var size = data.getUint32(0);
    var headerSize = 8;
    final type = String.fromCharCodes(header.sublist(4));
    if (size == 1) {
      final extended = await bytesAt(offset + 8, 8);
      if (extended.length < 8) return null;
      size = ByteData.sublistView(extended).getUint64(0);
      headerSize = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < headerSize || size > end - offset) return null;
    if (type == 'moov' && !insideMovie) {
      insideMovie = true;
      end = offset + size;
      offset += headerSize;
      continue;
    }
    if (type == 'mvhd' && insideMovie) {
      final payloadSize = size - headerSize;
      if (payloadSize < 20) return null;
      final payload = await bytesAt(
        offset + headerSize,
        math.min(32, payloadSize),
      );
      if (payload.length < 20) return null;
      final version = payload[0];
      if (version != 0 && version != 1) return null;
      if (version == 1 && payload.length < 32) return null;
      final mvhd = ByteData.sublistView(payload);
      final timescale = mvhd.getUint32(version == 1 ? 20 : 12);
      final duration = version == 1 ? mvhd.getUint64(24) : mvhd.getUint32(16);
      if (timescale == 0 ||
          duration == 0 ||
          duration == (version == 1 ? 0xffffffffffffffff : 0xffffffff)) {
        return null;
      }
      return duration / timescale;
    }
    offset += size;
  }
  return null;
}
