import 'dart:convert';
import 'dart:io';
import 'package:smb_media_viewer/utils/mp4_duration.dart';

// Read-only Windows SMB benchmark. Run with a UNC folder and a video path.
Future<void> main(List<String> args) async {
  if (args.length != 2) throw ArgumentError('Pass a UNC folder and video path');
  final watch = Stopwatch()..start();
  final entries = await Directory(
    args[0],
  ).list().where((f) => f is File).toList();
  final listingMs = watch.elapsedMilliseconds;
  watch.reset();
  final records = <Map<String, dynamic>>[];
  for (final entry in entries) {
    final stat = await entry.stat();
    records.add({
      'name': entry.uri.pathSegments.last,
      'size': stat.size,
      'modified': stat.modified.millisecondsSinceEpoch,
    });
  }
  final statMs = watch.elapsedMilliseconds;
  final sorts = <String, num>{};
  for (final key in ['name', 'size', 'modified']) {
    final copy = [...records];
    watch.reset();
    copy.sort(
      (a, b) => key == 'name'
          ? (a[key] as String).compareTo(b[key] as String)
          : (b[key] as int).compareTo(a[key] as int),
    );
    sorts[key] = watch.elapsedMicroseconds / 1000;
  }
  final file = await File(args[1]).open();
  var readBytes = 0;
  var requests = 0;
  watch.reset();
  double? duration;
  try {
    duration = await readMp4Duration(await file.length(), (
      offset,
      length,
    ) async {
      requests++;
      await file.setPosition(offset);
      final bytes = await file.read(length);
      readBytes += bytes.length;
      return bytes;
    });
  } finally {
    await file.close();
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'transport': 'Windows SMB loopback (not Android or Wi-Fi)',
      'files': records.length,
      'listingMs': listingMs,
      'statMs': statMs,
      'sortMs': sorts,
      'durationSeconds': duration,
      'durationReadBytes': readBytes,
      'durationRequests': requests,
      'durationMs': watch.elapsedMicroseconds / 1000,
    }),
  );
}
