import 'package:flutter/widgets.dart';

Duration videoSeekTarget(
  Duration position,
  Duration offset,
  Duration duration,
) {
  return Duration(
    milliseconds: (position + offset).inMilliseconds.clamp(
      0,
      duration.inMilliseconds.clamp(0, 1 << 53),
    ),
  );
}

class VideoGestures extends StatefulWidget {
  const VideoGestures({
    super.key,
    required this.child,
    required this.onSeek,
    required this.onShowControls,
  });
  final Widget child;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onShowControls;

  @override
  State<VideoGestures> createState() => _VideoGesturesState();
}

class _VideoGesturesState extends State<VideoGestures> {
  Offset? _doubleTapPosition;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onShowControls,
        onDoubleTapDown: (details) =>
            _doubleTapPosition = details.localPosition,
        onDoubleTapCancel: () => _doubleTapPosition = null,
        onDoubleTap: () {
          widget.onShowControls();
          final position = _doubleTapPosition;
          _doubleTapPosition = null;
          if (position == null) return;
          if (position.dx < constraints.maxWidth / 3) {
            widget.onSeek(const Duration(seconds: -10));
          } else if (position.dx > constraints.maxWidth * 2 / 3) {
            widget.onSeek(const Duration(seconds: 10));
          }
        },
        child: SizedBox.expand(child: Center(child: widget.child)),
      );
    },
  );
}
