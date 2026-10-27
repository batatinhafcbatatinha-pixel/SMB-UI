import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'smb_client.dart';

class _SmbVideoSource {
  final String ip;
  final String share;
  final String path;
  final String username;
  final String password;
  final int fileSize;
  final bool lowLatency;
  final int chunkSize;
  final int maxChunks;
  final int prefetchChunks;
  final int warmupChunks;
  final _SlidingChunkBuffer chunkBuffer;
  final bool thumbnailOnly;

  /// Bumped by every body request; older streams stop when they see a newer
  /// one (the player seeked and is no longer reading them).
  int streamGeneration = 0;

  _SmbVideoSource({
    required this.ip,
    required this.share,
    required this.path,
    required this.username,
    required this.password,
    required this.fileSize,
    required this.lowLatency,
    required this.chunkSize,
    required this.maxChunks,
    required this.prefetchChunks,
    required this.warmupChunks,
    required this.chunkBuffer,
    this.thumbnailOnly = false,
  });
}

class _SlidingChunkBuffer {
  final int chunkSize;
  final int maxChunks;
  final int prefetchChunks;
  final Future<Uint8List> Function(int chunkStart, int chunkLength) fetchChunk;

  final LinkedHashMap<int, Uint8List> _chunks = LinkedHashMap<int, Uint8List>();
  final Map<int, Future<Uint8List>> _inFlight = <int, Future<Uint8List>>{};
  bool _disposed = false;

  // Speculative reads are capped so the read the player is blocked on (e.g. a
  // seek to a tail moov) never queues behind the whole prefetch window. Each
  // SMB read is latency-bound, so a few in parallel are needed to fill the
  // link: one at a time delivered ~0.6 MB/s on a 2.5 MB/s link and stalled
  // 8-10 Mbps video about half the time.
  static const int _maxSpeculative = 3;
  int _speculativeInFlight = 0;
  final LinkedHashSet<int> _pending = LinkedHashSet<int>();

  _SlidingChunkBuffer({
    required this.fetchChunk,
    this.chunkSize = 1024 * 1024,
    this.maxChunks = 12,
    this.prefetchChunks = 6,
  });

  /// Foreground read: what the player is blocked on.
  Future<Uint8List> getChunk(int chunkIndex, int fileSize) async {
    if (_disposed) throw StateError('Video source was closed');
    if (!_chunks.containsKey(chunkIndex) &&
        !_inFlight.containsKey(chunkIndex)) {
      // The player moved somewhere not prefetched: drop stale speculation.
      _pending.removeWhere(
        (i) => i < chunkIndex || i > chunkIndex + prefetchChunks,
      );
    }
    _pending.remove(chunkIndex);
    return _fetch(chunkIndex, fileSize);
  }

  Future<Uint8List> _fetch(int chunkIndex, int fileSize) {
    final existing = _chunks[chunkIndex];
    if (existing != null) {
      _chunks.remove(chunkIndex);
      _chunks[chunkIndex] = existing;
      return Future.value(existing);
    }

    final inFlight = _inFlight[chunkIndex];
    if (inFlight != null) {
      return inFlight;
    }

    final start = chunkIndex * chunkSize;
    if (start >= fileSize) return Future.value(Uint8List(0));
    final length = ((fileSize - start) > chunkSize)
        ? chunkSize
        : (fileSize - start);

    final future = fetchChunk(start, length)
        .then((bytes) {
          if (_disposed) throw StateError('Video source was closed');
          if (bytes.length != length) {
            throw const HttpException('Incomplete SMB chunk');
          }
          _chunks[chunkIndex] = bytes;
          _evictIfNeeded();
          return bytes;
        })
        .whenComplete(() {
          _inFlight.remove(chunkIndex);
        });

    _inFlight[chunkIndex] = future;
    return future;
  }

  void prefetchAhead(int currentChunkIndex, int fileSize) {
    for (var i = 1; i <= prefetchChunks; i++) {
      final nextChunkIndex = currentChunkIndex + i;
      final nextStart = nextChunkIndex * chunkSize;
      if (nextStart >= fileSize) return;
      if (_chunks.containsKey(nextChunkIndex) ||
          _inFlight.containsKey(nextChunkIndex)) {
        continue;
      }

      warmChunk(nextChunkIndex, fileSize);
    }
  }

  /// Speculative read, queued behind foreground reads.
  void warmChunk(int chunkIndex, int fileSize) {
    if (_disposed ||
        _chunks.containsKey(chunkIndex) ||
        _inFlight.containsKey(chunkIndex)) {
      return;
    }
    _pending.add(chunkIndex);
    _pumpSpeculative(fileSize);
  }

  void _pumpSpeculative(int fileSize) {
    while (!_disposed && _speculativeInFlight < _maxSpeculative) {
      if (_pending.isEmpty) return;
      final next = _pending.first;
      _pending.remove(next);
      if (_chunks.containsKey(next) || _inFlight.containsKey(next)) continue;
      _speculativeInFlight++;
      unawaited(
        _fetch(next, fileSize)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                // Speculative reads may fail; the foreground read retries.
              },
            )
            .whenComplete(() {
              _speculativeInFlight--;
              _pumpSpeculative(fileSize);
            }),
      );
    }
  }

  void clear() {
    _disposed = true;
    _chunks.clear();
    _pending.clear();
    _inFlight.clear();
  }

  void _evictIfNeeded() {
    while (_chunks.length > maxChunks) {
      _chunks.remove(_chunks.keys.first);
    }
  }
}

class SmbVideoProxyServer {
  static final SmbVideoProxyServer _instance = SmbVideoProxyServer._internal();
  factory SmbVideoProxyServer() => _instance;
  SmbVideoProxyServer._internal();

  HttpServer? _server;
  Future<void>? _starting;
  final Map<String, _SmbVideoSource> _sources = {};

  // 1 MB chunks: a start or seek waits for one whole chunk (4 MB took 2+ s
  // on slower links, 2 MB chunks were slower overall in testing).
  int _resolveChunkSize(int fileSize, bool lowLatency) => 1024 * 1024;

  // Up to 48 MB buffered per video, 16 MB read ahead of the playhead
  // (~13 s at 10 Mbps) to ride out throughput dips without stalling.
  int _resolveMaxChunks(bool lowLatency, int chunkSize) => lowLatency ? 16 : 48;

  int _resolvePrefetchChunks(bool lowLatency, int chunkSize) =>
      lowLatency ? 6 : 16;

  int _resolveWarmupChunks(bool lowLatency, int chunkSize) => 1;

  Future<void> _ensureServer() {
    if (_server != null) return Future.value();
    return _starting ??= _startServer().whenComplete(() => _starting = null);
  }

  Future<void> _startServer() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
    debugPrint(
      '[SmbVideoProxy] Started on ${_server!.address.address}:${_server!.port}',
    );
  }

  Future<Uri> registerSource({
    required String ip,
    required String share,
    required String path,
    required String username,
    required String password,
    int? fileSizeOverride,
    bool lowLatency = false,
    bool thumbnailOnly = false,
  }) async {
    await _ensureServer();

    int fileSize = (fileSizeOverride ?? 0);
    if (fileSize <= 0) {
      final info = await SMBClient.getSmbFileInfo(
        ip,
        share,
        path,
        username: username,
        password: password,
      );
      if (!info.success || info.data == null) {
        throw Exception('Failed to get SMB file info: ${info.error}');
      }
      fileSize = (info.data!['size'] as num?)?.toInt() ?? 0;
    }
    final chunkSize = thumbnailOnly
        ? 256 * 1024
        : _resolveChunkSize(fileSize, lowLatency);
    final maxChunks = thumbnailOnly
        ? 4
        : _resolveMaxChunks(lowLatency, chunkSize);
    final prefetchChunks = thumbnailOnly
        ? 0
        : _resolvePrefetchChunks(lowLatency, chunkSize);
    final warmupChunks = thumbnailOnly
        ? 0
        : _resolveWarmupChunks(lowLatency, chunkSize);
    final token = base64Url
        .encode(
          utf8.encode(
            '${DateTime.now().microsecondsSinceEpoch}|$ip|$share|$path',
          ),
        )
        .replaceAll('=', '');

    _sources[token] = _SmbVideoSource(
      ip: ip,
      share: share,
      path: path,
      username: username,
      password: password,
      fileSize: fileSize,
      lowLatency: lowLatency,
      chunkSize: chunkSize,
      maxChunks: maxChunks,
      prefetchChunks: prefetchChunks,
      warmupChunks: warmupChunks,
      thumbnailOnly: thumbnailOnly,
      chunkBuffer: _SlidingChunkBuffer(
        chunkSize: chunkSize,
        maxChunks: maxChunks,
        prefetchChunks: prefetchChunks,
        fetchChunk: (chunkStart, chunkLength) async {
          final watch = Stopwatch()..start();
          final chunkResult = await SMBClient.readSmbFileChunk(
            ip,
            share,
            path,
            offset: chunkStart,
            length: chunkLength,
            username: username,
            password: password,
            playback: !thumbnailOnly,
          );

          if (!chunkResult.success || chunkResult.data == null) {
            throw Exception(
              'Failed SMB chunk at $chunkStart: ${chunkResult.error}',
            );
          }

          final bytes =
              (chunkResult.data!['bytes'] as Uint8List?) ?? Uint8List(0);
          if (kDebugMode && !thumbnailOnly) {
            debugPrint(
              '[SmbVideoProxy] chunk @${chunkStart ~/ (1024 * 1024)}MB '
              '${bytes.length ~/ 1024}KB in ${watch.elapsedMilliseconds}ms',
            );
          }
          return bytes;
        },
      ),
    );

    // Warm only the start: the player may jump to a tail index right away,
    // and read-ahead begins once it actually streams (in _streamRange).
    for (var i = 0; i < warmupChunks; i++) {
      _sources[token]!.chunkBuffer.warmChunk(i, fileSize);
    }
    debugPrint(
      '[SmbVideoProxy] Registered source lowLatency=$lowLatency '
      'chunk=${(chunkSize / (1024 * 1024)).toStringAsFixed(chunkSize >= 4 * 1024 * 1024 ? 0 : 1)}MB '
      'maxChunks=$maxChunks prefetch=$prefetchChunks warmup=$warmupChunks fileSize=$fileSize',
    );

    // libvlc is running inside the same Android app process, so the correct target is the
    // device loopback: 127.0.0.1. 10.0.2.2 is only for host-to-emulator traffic, and it
    // fails when the server is an in-app Dart HttpServer.
    const loopbackAddr = '127.0.0.1';
    return Uri.parse(
      'http://$loopbackAddr:${_server!.port}/video?token=$token',
    );
  }

  /// Aborts sources opened for thumbnail extraction. Their extractor keeps
  /// issuing range reads after the loader cancels; failing them fast frees
  /// the SMB link for whatever the user opened next.
  void closeThumbnailSources() {
    final tokens = [
      for (final e in _sources.entries)
        if (e.value.thumbnailOnly) e.key,
    ];
    tokens.forEach(unregisterSource);
  }

  void unregisterSource(String? token) {
    if (token == null || token.isEmpty) return;
    final source = _sources.remove(token);
    source?.chunkBuffer.clear();
  }

  Future<void> _serve() async {
    final server = _server;
    if (server == null) return;

    await for (final req in server) {
      unawaited(_handleRequest(req));
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (req.method != 'GET' && req.method != 'HEAD') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        req.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await req.response.close();
        return;
      }
      if (req.uri.path != '/video') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final token = req.uri.queryParameters['token'];
      final source = token != null ? _sources[token] : null;
      if (source == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final totalSize = source.fileSize;
      if (totalSize <= 0) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers.contentType = ContentType('video', 'mp4');

      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (kDebugMode) {
        debugPrint(
          '[SmbVideoProxy] ${req.method} range=$rangeHeader '
          'ua=${req.headers.value(HttpHeaders.userAgentHeader)}',
        );
      }
      if (req.method == 'HEAD' ||
          rangeHeader == null ||
          !rangeHeader.startsWith('bytes=')) {
        await _streamRange(req, source, 0, totalSize - 1, partial: false);
        return;
      }

      final rangePart = rangeHeader.substring('bytes='.length).trim();
      final match = RegExp(r'^(\d*)-(\d*)$').firstMatch(rangePart);
      final first = match == null ? null : int.tryParse(match.group(1)!);
      final last = match == null ? null : int.tryParse(match.group(2)!);
      final suffix = match != null && match.group(1)!.isEmpty;
      if (match == null ||
          (suffix
              ? (last == null || last <= 0)
              : (first == null ||
                    first >= totalSize ||
                    (match.group(2)!.isNotEmpty &&
                        (last == null || last < first))))) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$totalSize',
        );
        await req.response.close();
        return;
      }

      final safeStart = suffix
          ? (totalSize - last!).clamp(0, totalSize - 1)
          : first!;
      final safeEnd = suffix
          ? totalSize - 1
          : (last ?? totalSize - 1).clamp(safeStart, totalSize - 1);

      await _streamRange(req, source, safeStart, safeEnd, partial: true);
    } catch (e) {
      debugPrint('[SmbVideoProxy] request failed: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write('Video stream unavailable');
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _streamRange(
    HttpRequest req,
    _SmbVideoSource source,
    int start,
    int end, {
    required bool partial,
  }) async {
    final totalSize = source.fileSize;
    final contentLength = end - start + 1;

    req.response.statusCode = partial
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    req.response.bufferOutput = false;
    req.response.headers.set(HttpHeaders.contentLengthHeader, contentLength);
    if (partial) {
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$totalSize',
      );
    }
    if (req.method == 'HEAD') {
      await req.response.close();
      return;
    }
    await req.response.flush();

    // Players drop a connection whenever they seek. Stop reading SMB for it
    // instead of streaming the rest of a multi-GB file into a closed socket.
    var clientGone = false;
    unawaited(
      req.response.done.then(
        (_) => clientGone = true,
        onError: (Object _) => clientGone = true,
      ),
    );

    final generation = ++source.streamGeneration;
    bool superseded() => generation != source.streamGeneration;

    final chunkSize = source.chunkBuffer.chunkSize;
    int cursor = start;

    while (cursor <= end && !clientGone && !superseded()) {
      final chunkIndex = cursor ~/ chunkSize;
      final chunkOffset = cursor % chunkSize;
      final bytes = await source.chunkBuffer.getChunk(chunkIndex, totalSize);
      if (bytes.isEmpty) {
        break;
      }

      final available = bytes.length - chunkOffset;
      if (available <= 0) {
        cursor = (chunkIndex + 1) * chunkSize;
        continue;
      }

      final remainingInRange = end - cursor + 1;
      final toSend = available < remainingInRange
          ? available
          : remainingInRange;

      req.response.add(
        Uint8List.sublistView(bytes, chunkOffset, chunkOffset + toSend),
      );
      await req.response.flush();
      cursor += toSend;

      if (clientGone || superseded()) break;
      // No pruning here: players read the start, jump to a tail index and come
      // back, so earlier chunks stay until the LRU limit evicts them.
      source.chunkBuffer.prefetchAhead(chunkIndex, totalSize);
    }

    if (superseded()) {
      // Close without waiting: the player may never drain this socket.
      unawaited(req.response.close().catchError((Object _) {}));
    } else if (!clientGone) {
      await req.response.close();
    }
  }

  Future<void> dispose() async {
    await _starting;
    for (final source in _sources.values) {
      source.chunkBuffer.clear();
    }
    _sources.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

final smbVideoProxyServer = SmbVideoProxyServer();
