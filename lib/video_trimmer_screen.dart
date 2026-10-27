import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_trimmer/video_trimmer.dart';
import 'package:path_provider/path_provider.dart';

class VideoTrimmerScreen extends StatefulWidget {
  final String path;
  const VideoTrimmerScreen({required this.path, super.key});

  @override
  State<VideoTrimmerScreen> createState() => _VideoTrimmerScreenState();
}

class _VideoTrimmerScreenState extends State<VideoTrimmerScreen> {
  Trimmer _trimmer = Trimmer();
  bool _loading = true;
  String? _errorMessage;
  Timer? _watchdogTimer;
  double _startValue = 0.0;
  double _endValue = 0.0;
  Duration _videoDuration = Duration.zero;
  Duration? _lastPlaybackPosition;
  bool _watchdogSeeking = false;
  Size? _lastVideoSize;

  // Save state & errors
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final trimmer = _trimmer;
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }

    try {
      // Timeout in case loading hangs for some video files/inputs
      await trimmer
          .loadVideo(videoFile: File(widget.path))
          .timeout(const Duration(seconds: 10));
      if (!mounted || !identical(trimmer, _trimmer)) return;

      // Initialize end value from video duration (seconds)
      final d = _trimmer.videoPlayerController?.value.duration;
      _videoDuration = d ?? Duration.zero;
      _startValue = 0;
      _endValue = d != null ? d.inMilliseconds / 1000.0 : 0.0;

      // Add a listener to force UI updates when the controller changes (prevents the UI from sticking on a static thumbnail)
      final controller = _trimmer.videoPlayerController;
      controller?.addListener(_onVideoChanged);

      // Try seeking to current position to force a frame render in case the video texture is stuck
      try {
        final pos = controller?.value.position ?? Duration.zero;
        await controller?.seekTo(pos);
      } catch (_) {}

      // Start a light watchdog that nudges the video (seek to current position) while playing to refresh the texture
      if (mounted && identical(trimmer, _trimmer)) _startWatchdog();
    } on TimeoutException catch (_) {
      _errorMessage = 'Timed out while loading video.';
    } on Exception catch (e) {
      _errorMessage = 'Failed to load video: $e';
    } catch (e) {
      _errorMessage = 'Unexpected error while loading video.';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _saveTrimmed() async {
    if (_saving || _loading || _errorMessage != null) return;
    // Basic validation
    if (_endValue <= _startValue) {
      if (mounted) {
        setState(() => _saveError = 'Invalid trim range.');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid trim range')));
      }
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _saving = true;
          _saveError = null;
        });
      }

      // Note: the trimmer writes the trimmed file and returns the path via onSave.
      await _trimmer.saveTrimmedVideo(
        startValue: _startValue * 1000,
        endValue: _endValue * 1000,
        onSave: (outPath) async {
          if (!mounted) return;
          try {
            if (outPath == null || outPath.isEmpty) {
              setState(
                () =>
                    _saveError = 'Trimmer did not return a valid output path.',
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Trim produced no output')),
              );
              return;
            }

            debugPrint('Trimmer saved temporary file at: $outPath');

            // Copy trimmed output into app temporary directory with a unique name so it remains available.
            try {
              final tmpDir = await getTemporaryDirectory();
              if (!mounted) return;
              final destPath =
                  '${tmpDir.path}/trim_${DateTime.now().millisecondsSinceEpoch}.mp4';
              final src = File(outPath);
              if (await src.exists()) {
                // Move rather than copy: the trimmer's own output folder is
                // never cleaned and kept a full copy of every trimmed video.
                await src.copy(destPath);
                unawaited(src.delete().then((_) {}, onError: (Object _) {}));
                debugPrint('Trimmed file moved to $destPath');
                if (!mounted) return;
                Navigator.pop(context, destPath);
              } else {
                if (!mounted) return;
                setState(() => _saveError = 'Trimmed file missing at $outPath');
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(_saveError!)));
              }
            } catch (e) {
              if (!mounted) return;
              setState(() => _saveError = 'Failed to copy trimmed file: $e');
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(_saveError!)));
            }
          } catch (e) {
            if (mounted) {
              setState(() {
                _saving = false;
                _saveError = 'Unexpected error during save callback: $e';
              });
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(_saveError!)));
            }
          } finally {
            if (mounted) setState(() => _saving = false);
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = 'Failed to save trimmed video: $e';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_saveError!)));
      }
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _lastPlaybackPosition = null;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || _watchdogSeeking) return;
      final c = _trimmer.videoPlayerController;
      try {
        if (c != null && c.value.isPlaying && !c.value.isBuffering) {
          final pos = c.value.position;
          if (pos == _lastPlaybackPosition && pos < c.value.duration) {
            _watchdogSeeking = true;
            await c.seekTo(pos);
          }
          _lastPlaybackPosition = pos;
        } else {
          _lastPlaybackPosition = null;
        }
      } catch (_) {
      } finally {
        _watchdogSeeking = false;
      }
    });
  }

  void _stopWatchdog() {
    try {
      _watchdogTimer?.cancel();
    } catch (_) {}
    _watchdogTimer = null;
  }

  @override
  void dispose() {
    try {
      _trimmer.videoPlayerController?.removeListener(_onVideoChanged);
    } catch (_) {}
    _stopWatchdog();
    _trimmer.dispose();
    super.dispose();
  }

  void _onVideoChanged() {
    if (!mounted) return;
    final size = _trimmer.videoPlayerController?.value.size;
    // The player paints frames itself; rebuild only when layout changes.
    if (size == _lastVideoSize) return;
    _lastVideoSize = size;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trim Video'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.0),
                ),
              ),
            )
          else
            IconButton(
              onPressed: _loading || _errorMessage != null
                  ? null
                  : _saveTrimmed,
              icon: const Icon(Icons.check),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_errorMessage!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () async {
                      // recreate trimmer and retry
                      _stopWatchdog();
                      try {
                        _trimmer.videoPlayerController?.removeListener(
                          _onVideoChanged,
                        );
                        _trimmer.dispose();
                      } catch (_) {}
                      _trimmer = Trimmer();
                      await _load();
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (_saveError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8.0,
                      horizontal: 12.0,
                    ),
                    child: Container(
                      color: Colors.redAccent.withValues(alpha: 0.85),
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.white),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _saveError!,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: VideoViewer(trimmer: _trimmer)),
                // Compute sizes based on the video's natural dimensions so visuals scale like images
                Builder(
                  builder: (context) {
                    final controller = _trimmer.videoPlayerController;
                    final videoSize = controller?.value.size;
                    final screenW = MediaQuery.of(context).size.width;

                    // Derive a sensible thumbnail strip height from the video's aspect ratio,
                    // but keep it within reasonable bounds so it doesn't become too small/large.
                    final double computedViewerHeight =
                        videoSize != null && videoSize.width > 0
                        ? (screenW *
                                  (videoSize.height / videoSize.width) *
                                  0.12)
                              .clamp(60.0, 140.0)
                        : (screenW / 6).clamp(60.0, 140.0);

                    final double borderWidth = math.max(
                      3.0,
                      computedViewerHeight * 0.04,
                    );
                    // Increase minimum circle size and use a high-contrast color so handles are visible on bright videos
                    final double circleSize = math.max(
                      12.0,
                      computedViewerHeight * 0.16,
                    );
                    final double circleSizeOnDrag = circleSize * 1.6;

                    return SizedBox(
                      height: computedViewerHeight + 20,
                      child: Material(
                        color: Colors.black,
                        child: TrimViewer(
                          trimmer: _trimmer,
                          viewerHeight: computedViewerHeight,
                          viewerWidth: screenW,
                          // Ensure the trimmer knows the max video length so UI renders correctly
                          maxVideoLength: _videoDuration,
                          areaProperties: TrimAreaProperties.edgeBlur(
                            blurEdges: true,
                            blurColor: Colors.black54,
                          ),
                          editorProperties: TrimEditorProperties(
                            borderPaintColor: Colors.white,
                            borderWidth: borderWidth,
                            // Use a high-contrast accent color for the draggable dots
                            circlePaintColor: Colors.redAccent,
                            circleSize: circleSize,
                            circleSizeOnDrag: circleSizeOnDrag,
                            scrubberPaintColor: Colors.red,
                          ),
                          // The TrimViewer callbacks deliver values in milliseconds; convert to seconds
                          onChangeStart: (value) =>
                              setState(() => _startValue = value / 1000.0),
                          onChangeEnd: (value) =>
                              setState(() => _endValue = value / 1000.0),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }
}
