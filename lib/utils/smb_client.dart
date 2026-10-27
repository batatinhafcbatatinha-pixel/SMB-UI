import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'smb_connection_manager.dart';

String _normalizeSmbPath(String path) {
  if (path.isEmpty) return '/';
  var p = path.replaceAll('\\', '/');
  p = p.replaceAll(RegExp('/+'), '/');
  if (!p.startsWith('/')) p = '/$p';
  if (path.endsWith('/') || path.endsWith('\\')) {
    if (!p.endsWith('/')) p = '$p/';
  }
  return p;
}

/// Global semaphore to limit concurrent SMB operations
/// This prevents overwhelming the SMB server with too many simultaneous connections
class _SMBSemaphore {
  static final _SMBSemaphore _instance = _SMBSemaphore._internal();
  factory _SMBSemaphore() => _instance;
  _SMBSemaphore._internal();

  // Keep the SMB operation count conservative. Overloaded SMB sessions under slow
  // networks can stall and trigger connection timeouts that kill the app.
  int _maxConcurrent = 1;
  int _current = 0;
  final Queue<Completer<void>> _queue = Queue<Completer<void>>();

  int get current => _current;
  int get maxConcurrent => _maxConcurrent;

  void setMaxConcurrent(int value) {
    final clamped = value.clamp(1, 64);
    _maxConcurrent = clamped;
    while (_queue.isNotEmpty && _current < _maxConcurrent) {
      final completer = _queue.removeFirst();
      _current++;
      completer.complete();
    }
  }

  Future<void> acquire() async {
    if (_current < _maxConcurrent) {
      _current++;
      return;
    }

    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
  }

  void release() {
    _current--;
    if (_queue.isNotEmpty && _current < _maxConcurrent) {
      final completer = _queue.removeFirst();
      _current++;
      completer.complete();
    }
  }
}

final _smbSemaphore = _SMBSemaphore();

/// Result wrapper for SMB operations
class SMBResult<T> {
  final T? data;
  final String? error;
  final bool success;
  final int retryCount;

  SMBResult({
    this.data,
    this.error,
    required this.success,
    this.retryCount = 0,
  });

  factory SMBResult.success(T data, {int retryCount = 0}) {
    return SMBResult(data: data, success: true, retryCount: retryCount);
  }

  factory SMBResult.error(String error, {int retryCount = 0}) {
    return SMBResult(error: error, success: false, retryCount: retryCount);
  }
}

/// SMB API client with automatic retry and connection management
class SMBClient {
  static const platform = MethodChannel('smb_channel');

  static final Map<String, int> _fileSizeCache = {};

  static void _cacheFileSize(String key, int size) {
    _fileSizeCache.remove(key);
    _fileSizeCache[key] = size;
    while (_fileSizeCache.length > 512) {
      _fileSizeCache.remove(_fileSizeCache.keys.first);
    }
  }

  static void configureParallelism(int maxConcurrent) {
    _smbSemaphore.setMaxConcurrent(maxConcurrent);
    if (kDebugMode) {
      debugPrint('SMB parallelism configured to $maxConcurrent');
    }
  }

  /// Execute operation with automatic retry
  static Future<SMBResult<T>> executeWithRetry<T>(
    Future<T> Function() operation, {
    String? connectionKey,
    int maxAttempts = 3,
    Duration operationTimeout = const Duration(seconds: 60),
    Duration initialDelay = const Duration(milliseconds: 500),
    double backoffMultiplier = 1.5,
    bool bypassSemaphore = false,
  }) async {
    // Acquire semaphore to limit concurrent SMB operations
    if (!bypassSemaphore) await _smbSemaphore.acquire();
    if (kDebugMode && _smbSemaphore.current <= 1) {}

    try {
      int attempt = 0;
      Duration currentDelay = initialDelay;

      while (attempt < maxAttempts) {
        try {
          final result = await operation().timeout(operationTimeout);

          // Record success
          if (connectionKey != null) {
            smbConnectionManager.recordActivity(connectionKey);
          }

          return SMBResult.success(result, retryCount: attempt);
        } on TimeoutException catch (e) {
          attempt++;
          if (kDebugMode) {
            debugPrint(
              'SMB operation timeout (attempt $attempt/$maxAttempts): $e',
            );
          }

          if (attempt < maxAttempts) {
            await Future.delayed(currentDelay);
            currentDelay = Duration(
              milliseconds: (currentDelay.inMilliseconds * backoffMultiplier)
                  .toInt(),
            );
          }
        } on PlatformException catch (e) {
          attempt++;
          if (kDebugMode) {
            debugPrint(
              'SMB operation failed (attempt $attempt/$maxAttempts): ${e.code} ${e.message}',
            );
          }

          // Longer delay on authentication errors
          if (e.code.contains('AUTHENTICATION') ||
              e.message?.contains('DiskShare') == true) {
            currentDelay = const Duration(seconds: 2);
          }

          if (attempt < maxAttempts) {
            await Future.delayed(currentDelay);
            currentDelay = Duration(
              milliseconds: (currentDelay.inMilliseconds * backoffMultiplier)
                  .toInt(),
            );
          }
        } catch (e) {
          attempt++;
          if (kDebugMode) {
            debugPrint(
              'Unexpected error in SMB operation (attempt $attempt/$maxAttempts): $e',
            );
          }

          if (attempt < maxAttempts) {
            await Future.delayed(currentDelay);
            currentDelay = Duration(
              milliseconds: (currentDelay.inMilliseconds * backoffMultiplier)
                  .toInt(),
            );
          }
        }
      }

      return SMBResult.error(
        'Operation failed after $maxAttempts attempts',
        retryCount: maxAttempts,
      );
    } finally {
      // Always release semaphore
      if (!bypassSemaphore) _smbSemaphore.release();
      if (kDebugMode && _smbSemaphore.current <= 1) {
        debugPrint('SMB semaphore released');
      }
    }
  }

  /// List network servers
  static Future<SMBResult<List<dynamic>>> discoverNetwork() {
    return executeWithRetry<List<dynamic>>(() async {
      final result = await platform.invokeMethod('discoverNetwork');
      return result ?? [];
    }, maxAttempts: 2);
  }

  /// List shares on server
  static Future<SMBResult<List<dynamic>>> listShares(
    String ip, {
    String username = '',
    String password = '',
  }) {
    final connectionKey = '$ip:shares';
    return executeWithRetry<List<dynamic>>(
      () async {
        final result = await platform.invokeMethod('listShares', {
          'ip': ip,
          'username': username,
          'password': password,
        });
        return result ?? [];
      },
      connectionKey: connectionKey,
      maxAttempts: 3,
    );
  }

  /// List directory contents
  static Future<SMBResult<List<dynamic>>> listDirectory(
    String ip,
    String share,
    String path, {
    String username = '',
    String password = '',
  }) {
    final connectionKey = '$ip:$share';
    final normPath = _normalizeSmbPath(path);
    return executeWithRetry<List<dynamic>>(
      () async {
        final result = await platform.invokeMethod('listDirectory', {
          'ip': ip,
          'share': share,
          'path': normPath,
          'username': username,
          'password': password,
        });
        return result ?? [];
      },
      connectionKey: connectionKey,
      maxAttempts: 3,
    );
  }

  /// Fetch file from SMB.
  ///
  /// Pass a [requestId] to be able to stop the native download with
  /// [cancelFetch]. Cancellable fetches are not retried on timeout, since the
  /// native side would still be downloading the first attempt.
  static Future<SMBResult<String>> fetchFile(
    String ip,
    String share,
    String path, {
    String username = '',
    String password = '',
    String? requestId,
    Duration timeout = const Duration(seconds: 60),
  }) {
    final connectionKey = '$ip:$share';
    final normPath = _normalizeSmbPath(path);
    return executeWithRetry<String>(
      () async {
        final result = await platform.invokeMethod('fetchFile', {
          'ip': ip,
          'share': share,
          'path': normPath,
          'username': username,
          'password': password,
          'requestId': ?requestId,
        });
        return result ?? '';
      },
      connectionKey: connectionKey,
      maxAttempts: requestId == null ? 3 : 1,
      operationTimeout: timeout,
    );
  }

  /// Stops a [fetchFile] started with [requestId]; its partial file is deleted.
  static Future<void> cancelFetch(String requestId) async {
    try {
      await platform.invokeMethod('cancelFetch', {'requestId': requestId});
    } catch (e) {
      debugPrint('cancelFetch failed: $e');
    }
  }

  /// Reads an image over SMB and writes a JPEG thumbnail natively to [outPath].
  /// Returns [outPath], or null when the image could not be decoded.
  static Future<SMBResult<String?>> smbImageThumbnail(
    String ip,
    String share,
    String path, {
    required String outPath,
    int maxSize = 320,
  }) {
    return executeWithRetry<String?>(
      () async => await platform.invokeMethod<String>('smbImageThumbnail', {
        'ip': ip,
        'share': share,
        'path': _normalizeSmbPath(path),
        'outPath': outPath,
        'maxSize': maxSize,
      }),
      connectionKey: '$ip:$share',
      maxAttempts: 2,
    );
  }

  /// Generate thumbnail
  static Future<SMBResult<dynamic>> generateThumbnail(String localPath) {
    return executeWithRetry(
      () =>
          platform.invokeMethod('generateThumbnail', {'localPath': localPath}),
      maxAttempts: 2,
    );
  }

  /// Get video duration
  static Future<SMBResult<num?>> getVideoDuration(String localPath) {
    return executeWithRetry<num?>(() async {
      final result = await platform.invokeMethod('getVideoDuration', {
        'localPath': localPath,
      });
      return result as num?;
    }, maxAttempts: 2);
  }

  /// Delete file
  static Future<SMBResult<bool>> deleteFile(
    String ip,
    String share,
    String path, {
    String username = '',
    String password = '',
  }) {
    final connectionKey = '$ip:$share';
    final normPath = _normalizeSmbPath(path);
    return executeWithRetry<bool>(
      () async {
        await platform.invokeMethod('deleteFile', {
          'ip': ip,
          'share': share,
          'path': normPath,
          'username': username,
          'password': password,
        });
        _fileSizeCache.remove('$ip|$share|$normPath');
        return true;
      },
      connectionKey: connectionKey,
      maxAttempts: 2,
    );
  }

  /// Get SMB file information (currently size only)
  static Future<SMBResult<Map<String, dynamic>>> getSmbFileInfo(
    String ip,
    String share,
    String path, {
    String username = '',
    String password = '',
  }) {
    final connectionKey = '$ip:$share';
    final normPath = _normalizeSmbPath(path);
    return executeWithRetry<Map<String, dynamic>>(
      () async {
        final result = await platform.invokeMethod('getSmbFileInfo', {
          'ip': ip,
          'share': share,
          'path': normPath,
          'username': username,
          'password': password,
        });
        final map = Map<String, dynamic>.from(result as Map<dynamic, dynamic>);
        final size = (map['size'] as num?)?.toInt();
        if (size != null) {
          _cacheFileSize('$ip|$share|$normPath', size);
        }
        return map;
      },
      connectionKey: connectionKey,
      maxAttempts: 2,
    );
  }

  /// Read a chunk from SMB file.
  static Future<SMBResult<Map<String, dynamic>>> readSmbFileChunk(
    String ip,
    String share,
    String path, {
    required int offset,
    required int length,
    String username = '',
    String password = '',
    bool playback = false,
  }) {
    final connectionKey = '$ip:$share';
    final normPath = _normalizeSmbPath(path);
    return executeWithRetry<Map<String, dynamic>>(
      // Playback reads get their own lane (here and natively): queued behind
      // background thumbnail reads, a video's first chunk waited 20 s+.
      // The proxy already bounds how many of them are in flight.
      bypassSemaphore: playback,
      () async {
        final result = await platform.invokeMethod('readSmbFileChunk', {
          'ip': ip,
          'share': share,
          'path': normPath,
          'offset': offset,
          'length': length,
          'playback': playback,
          'username': username,
          'password': password,
        });
        final map = Map<String, dynamic>.from(result as Map<dynamic, dynamic>);
        if (map['bytes'] is! Uint8List) {
          final b64 = (map.remove('data') as String?) ?? '';
          map['bytes'] = b64.isEmpty ? Uint8List(0) : base64Decode(b64);
        }
        final fileSize = (map['fileSize'] as num?)?.toInt();
        if (fileSize != null) {
          _cacheFileSize('$ip|$share|$normPath', fileSize);
        }
        return map;
      },
      connectionKey: connectionKey,
      maxAttempts: 2,
    );
  }

  static int? getCachedFileSize(String ip, String share, String path) {
    return _fileSizeCache['$ip|$share|${_normalizeSmbPath(path)}'];
  }

  /// Copy a file within the same SMB share (server-side stream copy).
  static Future<SMBResult<bool>> copyFile(
    String ip,
    String share,
    String srcPath,
    String dstPath, {
    String username = '',
    String password = '',
  }) {
    final normSrc = _normalizeSmbPath(srcPath);
    final normDst = _normalizeSmbPath(dstPath);
    return executeWithRetry<bool>(
      () async {
        await platform.invokeMethod('copyFile', {
          'ip': ip,
          'share': share,
          'srcPath': normSrc,
          'dstPath': normDst,
          'username': username,
          'password': password,
        });
        _fileSizeCache.remove('$ip|$share|$normDst');
        return true;
      },
      connectionKey: '$ip:$share',
      maxAttempts: 2,
    );
  }

  /// Move (rename/relocate) a file within the same SMB share.
  static Future<SMBResult<bool>> moveFile(
    String ip,
    String share,
    String srcPath,
    String dstPath, {
    String username = '',
    String password = '',
  }) {
    final normSrc = _normalizeSmbPath(srcPath);
    final normDst = _normalizeSmbPath(dstPath);
    return executeWithRetry<bool>(
      () async {
        await platform.invokeMethod('moveFile', {
          'ip': ip,
          'share': share,
          'srcPath': normSrc,
          'dstPath': normDst,
          'username': username,
          'password': password,
        });
        _fileSizeCache.remove('$ip|$share|$normSrc');
        _fileSizeCache.remove('$ip|$share|$normDst');
        return true;
      },
      connectionKey: '$ip:$share',
      maxAttempts: 2,
    );
  }

  /// Fetch a file with progress callbacks and cancellation support.
  /// [onProgress] receives (bytesReceived, totalBytes) — totalBytes may be 0 if unknown.
  /// [cancelToken] — set its value to true to request cancellation.
  static Future<SMBResult<String>> fetchFileWithProgress(
    String ip,
    String share,
    String path, {
    String username = '',
    String password = '',
    void Function(int received, int total)? onProgress,
    ValueNotifier<bool>? cancelToken,
  }) async {
    // The token now really stops the native download (it used to only hide
    // the dialog while the whole file kept downloading).
    final requestId = 'edit-${DateTime.now().microsecondsSinceEpoch}';
    void onCancel() {
      if (cancelToken?.value == true) unawaited(cancelFetch(requestId));
    }

    cancelToken?.addListener(onCancel);
    try {
      return await fetchFile(
        ip,
        share,
        path,
        username: username,
        password: password,
        requestId: requestId,
        timeout: const Duration(minutes: 30),
      );
    } finally {
      try {
        cancelToken?.removeListener(onCancel);
      } catch (_) {
        // The caller may already have disposed the token.
      }
    }
  }

  /// Upload a local file to an SMB path, replacing if it exists.
  static Future<SMBResult<bool>> uploadFile(
    String ip,
    String share,
    String remotePath,
    String localPath, {
    String username = '',
    String password = '',
  }) {
    final connectionKey = '$ip:$share';
    final normRemote = _normalizeSmbPath(remotePath);
    return executeWithRetry<bool>(
      () async {
        await platform.invokeMethod('uploadFile', {
          'ip': ip,
          'share': share,
          'path': normRemote,
          'localPath': localPath,
          'username': username,
          'password': password,
        });
        _fileSizeCache.remove('$ip|$share|$normRemote');
        return true;
      },
      connectionKey: connectionKey,
      // A retry after a timeout would race the still-running native upload.
      maxAttempts: 1,
      operationTimeout: const Duration(minutes: 30),
    );
  }
}
