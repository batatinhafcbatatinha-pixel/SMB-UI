import 'dart:async';

/// Event emitted when a thumbnail (or video duration) is ready.
class ThumbnailReadyEvent {
  final String smbPath; // normalized SMB path
  final String? thumbPath; // local thumb path (nullable for duration-only events)
  final double? duration; // optional duration for videos

  ThumbnailReadyEvent({
    required this.smbPath,
    this.thumbPath,
    this.duration,
  });
}

/// Global broadcast stream controller for thumbnail-ready events.
///
/// Consumers can listen with `thumbnailReadyBus.stream.listen(...)`.
final thumbnailReadyBus = StreamController<ThumbnailReadyEvent>.broadcast();

/// Convenience emitter.
void emitThumbnailReady(String smbPath, String? thumbPath, {double? duration}) {
  try {
    thumbnailReadyBus.add(ThumbnailReadyEvent(
      smbPath: smbPath,
      thumbPath: thumbPath,
      duration: duration,
    ));
  } catch (_) {}
}
