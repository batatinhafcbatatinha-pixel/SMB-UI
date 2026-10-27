import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'thumbnail_events.dart';

/// Entrada no cache persistente
class ThumbCacheEntry {
  final String filePath; // Caminho SMB original (chave)
  final String thumbPath; // Caminho local do thumb gerado
  final double? duration; // Duração em segundos (só vídeos)
  DateTime lastUsed; // Para LRU

  ThumbCacheEntry({
    required this.filePath,
    required this.thumbPath,
    this.duration,
    required this.lastUsed,
  });

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'thumbPath': thumbPath,
    if (duration != null) 'duration': duration,
    'lastUsed': lastUsed.millisecondsSinceEpoch,
  };

  factory ThumbCacheEntry.fromJson(Map<String, dynamic> j) => ThumbCacheEntry(
    filePath: j['filePath'] as String,
    thumbPath: j['thumbPath'] as String,
    duration: (j['duration'] as num?)?.toDouble(),
    lastUsed: DateTime.fromMillisecondsSinceEpoch(j['lastUsed'] as int),
  );
}

/// Cache persistente de thumbnails e metadata.
///
/// - Sobrevive entre sessões e trocas de pasta.
/// - Limita o total de thumbs a [maxCacheBytes] (default 512 MB).
/// - Evicção LRU: apaga os thumbs menos usados quando o limite é atingido.
/// - Nunca apaga um thumb se o arquivo SMB original ainda existir —
///   só o remove do índice se o arquivo de thumb no disco sumiu.
class ThumbnailCache {
  static final ThumbnailCache _instance = ThumbnailCache._internal();
  factory ThumbnailCache() => _instance;
  ThumbnailCache._internal();

  static const int _defaultMaxBytes = 512 * 1024 * 1024; // 512 MB

  final Map<String, ThumbCacheEntry> _entries = {};
  final Map<String, int> _sizes = {};
  int _totalBytes = 0;
  File? _indexFile;
  Directory? _thumbDir;
  bool _loaded = false;
  bool _dirty = false;
  Timer? _flushDebounceTimer;

  int maxCacheBytes = _defaultMaxBytes;
  Future<void> _writeChain = Future.value();

  Future<T> _enqueueWrite<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeChain = _writeChain.then((_) async {
      try {
        final value = await action();
        completer.complete(value);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ─── Inicialização ────────────────────────────────────────────────────────

  Future<void> initialize(Directory cacheDir) async {
    return _enqueueWrite(() => _initialize(cacheDir));
  }

  Future<void> _initialize(Directory cacheDir) async {
    if (_loaded) return;
    _thumbDir = Directory('${cacheDir.path}/thumb_store');
    if (!await _thumbDir!.exists()) {
      await _thumbDir!.create(recursive: true);
    }
    _indexFile = File('${_thumbDir!.path}/thumb_index.json');
    await _load();
    _loaded = true;
    debugPrint('[ThumbnailCache] Loaded ${_entries.length} entries');
  }

  String normalizeKey(String smbPath) {
    if (smbPath.isEmpty) return '/';
    // Fast path for already-normalized keys (called per item on folder load).
    if (smbPath.startsWith('/') &&
        !smbPath.contains('\\') &&
        !smbPath.contains('//') &&
        (smbPath.length == 1 || !smbPath.endsWith('/')) &&
        smbPath.trim().length == smbPath.length) {
      return smbPath;
    }
    var p = smbPath.replaceAll('\\', '/').trim();
    if (p.isEmpty) return '/';

    p = p.replaceAll(RegExp('/+'), '/');
    if (!p.startsWith('/')) p = '/$p';
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String getThumbOutputPath(String smbPath) {
    final normalized = normalizeKey(smbPath);
    final digest = base64Url
        .encode(utf8.encode(normalized))
        .replaceAll('=', '');
    final dir = _thumbDir;
    if (dir == null) {
      throw StateError('ThumbnailCache not initialized');
    }
    return '${dir.path}/thumb_$digest.jpg';
  }

  Future<void> _load() async {
    _entries.clear();
    _sizes.clear();
    _totalBytes = 0;
    try {
      if (!await _indexFile!.exists()) return;
      final raw = await _indexFile!.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final parsed = ThumbCacheEntry.fromJson(item as Map<String, dynamic>);
        final normalizedPath = normalizeKey(parsed.filePath);
        final entry = ThumbCacheEntry(
          filePath: normalizedPath,
          thumbPath: parsed.thumbPath,
          duration: parsed.duration,
          lastUsed: parsed.lastUsed,
        );
        _entries[normalizedPath] = entry;
      }
      // Remove entradas cujo arquivo de thumb não existe mais
      final stale = <String>[];
      final snapshot = _entries.values.toList(growable: false);
      for (final e in snapshot) {
        if (e.thumbPath.isEmpty) continue;
        final stat = await File(e.thumbPath).stat();
        if (stat.type != FileSystemEntityType.file) {
          stale.add(e.filePath);
        } else {
          _sizes[e.filePath] = stat.size;
          _totalBytes += stat.size;
        }
      }
      for (final k in stale) {
        _entries.remove(k);
      }
      if (stale.isNotEmpty) {
        debugPrint('[ThumbnailCache] Removed ${stale.length} stale entries');
        _dirty = true;
      }
    } catch (e) {
      debugPrint('[ThumbnailCache] Error loading index: $e');
    }
  }

  // ─── Acesso público ───────────────────────────────────────────────────────

  /// Retorna a entrada para [smbPath] se existir e o thumb estiver no disco.
  Future<ThumbCacheEntry?> get(String smbPath) async {
    return _enqueueWrite(() async {
      final key = normalizeKey(smbPath);
      final entry = _entries[key];
      if (entry == null) return null;

      // Verifica se o arquivo ainda existe
      if (entry.thumbPath.isNotEmpty && !await File(entry.thumbPath).exists()) {
        _totalBytes -= _sizes.remove(key) ?? 0;
        _entries.remove(key);
        _dirty = true;
        return null;
      }

      entry.lastUsed = DateTime.now();
      _dirty = true;
      return entry;
    });
  }

  /// Salva/atualiza uma entrada. Persiste no disco de forma assíncrona.
  Future<void> put({
    required String smbPath,
    required String thumbPath,
    double? duration,
  }) async {
    await _enqueueWrite(() async {
      final key = normalizeKey(smbPath);
      // Se já existe, mantém duration se não foi fornecida
      final existing = _entries[key];
      final stat = thumbPath.isEmpty ? null : await File(thumbPath).stat();
      _totalBytes -= _sizes.remove(key) ?? 0;
      if (stat != null && stat.type == FileSystemEntityType.file) {
        _sizes[key] = stat.size;
        _totalBytes += stat.size;
      }
      _entries[key] = ThumbCacheEntry(
        filePath: key,
        thumbPath: thumbPath,
        duration: duration ?? existing?.duration,
        lastUsed: DateTime.now(),
      );
      _dirty = true;
      await _evictIfNeededUnlocked();
      _scheduleFlush();
    });
  }

  /// Atualiza só a duration de uma entrada existente.
  Future<void> putDuration(String smbPath, double duration) async {
    await _enqueueWrite(() async {
      final key = normalizeKey(smbPath);
      final existing = _entries[key];
      if (existing != null) {
        _entries[key] = ThumbCacheEntry(
          filePath: existing.filePath,
          thumbPath: existing.thumbPath,
          duration: duration,
          lastUsed: existing.lastUsed,
        );
      } else {
        // Sem thumb ainda, salva só a duration com thumbPath vazio
        // (será atualizado quando o thumb for gerado)
        _entries[key] = ThumbCacheEntry(
          filePath: key,
          thumbPath: '',
          duration: duration,
          lastUsed: DateTime.now(),
        );
      }
      _dirty = true;
      _scheduleFlush();
    });
  }

  /// Entrada em cache sem checar o disco (o widget de imagem trata arquivo ausente).
  ThumbCacheEntry? peek(String smbPath) => _entries[normalizeKey(smbPath)];

  /// Retorna só a duration em cache, sem precisar do thumb.
  double? getDuration(String smbPath) =>
      _entries[normalizeKey(smbPath)]?.duration;

  // ─── Restauração em lote ──────────────────────────────────────────────────

  /// Restaura thumbs e durations nos [items] a partir do cache.
  /// Retorna o número de itens restaurados.
  Future<int> restoreItems(List<Map<dynamic, dynamic>> items) async {
    int restored = 0;
    for (final item in items) {
      final path = item['path'] as String?;
      if (path == null) continue;

      final entry = _entries[normalizeKey(path)];
      if (entry == null) continue;

      bool changed = false;

      // Emit events to restore duration and/or thumb instead of mutating
      if (entry.duration != null && item['duration'] == null) {
        emitThumbnailReady(normalizeKey(path), null, duration: entry.duration);
        changed = true;
      }

      if (entry.thumbPath.isNotEmpty && item['thumb'] == null) {
        if (await File(entry.thumbPath).exists()) {
          emitThumbnailReady(
            normalizeKey(path),
            entry.thumbPath,
            duration: entry.duration,
          );
          changed = true;
        }
      }

      if (changed) restored++;
    }
    debugPrint(
      '[ThumbnailCache] Restored $restored / ${items.length} items from cache',
    );
    return restored;
  }

  // ─── Evicção LRU ──────────────────────────────────────────────────────────

  Future<void> _evictIfNeededUnlocked() async {
    int totalBytes = _totalBytes;

    if (totalBytes <= maxCacheBytes) return;

    debugPrint(
      '[ThumbnailCache] Cache at ${(totalBytes / 1e9).toStringAsFixed(2)} GB, evicting (incremental)...',
    );

    // Ordena por lastUsed (mais antigo primeiro)
    final sorted = _entries.values.toList(growable: false)
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));

    // Evict in small batches to avoid long I/O spikes
    const int batchSize = 50;
    int idx = 0;
    while (totalBytes > maxCacheBytes && idx < sorted.length) {
      final end = (idx + batchSize).clamp(0, sorted.length);
      final batch = sorted.sublist(idx, end);
      for (final entry in batch) {
        if (totalBytes <= maxCacheBytes) break;
        if (entry.thumbPath.isEmpty) continue;
        try {
          final f = File(entry.thumbPath);
          if (await f.exists()) {
            await f.delete();
            debugPrint('[ThumbnailCache] Evicted ${entry.thumbPath}');
          }
        } catch (_) {
          continue;
        }
        final removedSize = _sizes.remove(entry.filePath) ?? 0;
        totalBytes -= removedSize;
        _totalBytes -= removedSize;
        _entries.remove(entry.filePath);
      }
      idx += batchSize;
      if (totalBytes > maxCacheBytes && idx < sorted.length) {
        // schedule next batch shortly to yield to UI
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }

    _dirty = true;
  }

  // ─── Persistência ─────────────────────────────────────────────────────────

  /// Grava o índice em disco se houve mudanças.
  Future<void> flush() {
    _flushDebounceTimer?.cancel();
    _flushDebounceTimer = null;
    return _enqueueWrite(_flushUnlocked);
  }

  void _scheduleFlush() {
    // Bound the delay even while a large folder keeps producing thumbnails.
    _flushDebounceTimer ??= Timer(const Duration(seconds: 2), () {
      _flushDebounceTimer = null;
      unawaited(flush());
    });
  }

  Future<void> _flushUnlocked() async {
    if (!_dirty || _indexFile == null) return;
    try {
      // Só salva entradas com thumb válido OU com duration (para metadata-only)
      final toSave = _entries.values
          .where((e) => e.thumbPath.isNotEmpty || e.duration != null)
          .map((e) => e.toJson())
          .toList();
      final pendingFile = File('${_indexFile!.path}.tmp');
      await pendingFile.writeAsString(jsonEncode(toSave), flush: true);
      await pendingFile.rename(_indexFile!.path);
      _dirty = false;
    } catch (e) {
      debugPrint('[ThumbnailCache] Error flushing index: $e');
    }
  }

  Future<void> remove(String smbPath) async {
    await _enqueueWrite(() async {
      final key = normalizeKey(smbPath);
      final removed = _entries.remove(key);
      if (removed == null) return;
      _totalBytes -= _sizes.remove(key) ?? 0;

      try {
        if (removed.thumbPath.isNotEmpty) {
          final file = File(removed.thumbPath);
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (e) {
        debugPrint('[ThumbnailCache] Error deleting thumb for $key: $e');
      }

      _dirty = true;
      await _flushUnlocked();
    });
  }
}

/// Singleton global
final thumbCache = ThumbnailCache();
