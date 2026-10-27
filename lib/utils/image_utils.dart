import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui' as ui;

/// Decode within both bounds without distorting the source or upscaling it.
Future<ui.Codec> decodeImageToFit(String path, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  return ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      final scale = (width / w).clamp(0.0, 1.0);
      final boundedScale = scale.clamp(0.0, height / h);
      return ui.TargetImageSize(
        width: (w * boundedScale).round().clamp(1, w),
        height: (h * boundedScale).round().clamp(1, h),
      );
    },
  );
}

Future<String?> generateImageThumbnailNative(
  String localPath,
  String outPath,
  int targetWidth,
) async {
  try {
    final codec = await decodeImageToFit(localPath, targetWidth, targetWidth);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        await File(outPath).writeAsBytes(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
        );
        return outPath;
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (e) {
    debugPrint('Native thumbnail generation failed: $e');
    return null;
  }
}

Future<void> adjustImageCacheSizeFromPrefs() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final override = prefs.getInt('imageCacheMaxBytes');
    final int computed = override ?? (150 * 1024 * 1024); // default 150MB
    final clampVal = computed.clamp(50 * 1024 * 1024, 200 * 1024 * 1024);
    PaintingBinding.instance.imageCache.maximumSizeBytes = clampVal;
    debugPrint('Adjusted imageCache.maximumSizeBytes = $clampVal');
  } catch (e) {
    debugPrint('Failed to adjust image cache size: $e');
  }
}
