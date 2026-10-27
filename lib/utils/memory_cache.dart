// Memory-optimized cache manager with LRU eviction and size limits
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Global memory cap for all in-memory caches: 1 GiB (ensured by MemoryCacheManager)
const int _kGlobalMemoryCapBytes = 1024 * 1024 * 1024;

/// Manager that keeps track of MemoryCache instances and ensures
/// the sum of their allowed memory does not exceed the global cap.
class MemoryCacheManager {
  MemoryCacheManager._internal();
  static final MemoryCacheManager instance = MemoryCacheManager._internal();

  final List<MemoryCache> _caches = <MemoryCache>[];

  void register(MemoryCache cache, int requestedMaxBytes) {
    if (!_caches.contains(cache)) {
      _caches.add(cache);
    }
    _recalculateCaps();
  }

  void unregister(MemoryCache cache) {
    _caches.remove(cache);
    _recalculateCaps();
  }

  void _recalculateCaps() {
    // Sum requested caps
    int totalRequested = 0;
    for (final c in _caches) {
      totalRequested += c.requestedMaxMemoryBytes;
    }

    if (totalRequested <= _kGlobalMemoryCapBytes) {
      // Honor requests
      for (final c in _caches) {
        c._applyMaxMemory(c.requestedMaxMemoryBytes);
      }
      return;
    }

    // Scale down proportionally to respect global cap
    final double scale = _kGlobalMemoryCapBytes / totalRequested;
    for (final c in _caches) {
      final newCap = (c.requestedMaxMemoryBytes * scale).toInt();
      c._applyMaxMemory(newCap);
    }
  }
}

/// LRU Memory Cache with size limits
class MemoryCache<T> {
  final int maxEntries;
  int maxMemoryBytes; // actual cap enforced (may be reduced by manager)
  final int requestedMaxMemoryBytes; // what the cache originally requested
  int _currentMemoryBytes = 0;
  final LinkedHashMap<String, _CacheEntry<T>> _cache =
      LinkedHashMap<String, _CacheEntry<T>>();

  MemoryCache({this.maxEntries = 50, this.maxMemoryBytes = 50 * 1024 * 1024})
    : requestedMaxMemoryBytes = maxMemoryBytes {
    if (maxEntries < 0 || maxMemoryBytes < 0) {
      throw ArgumentError('Cache limits must be non-negative');
    }
    // Register with global manager to avoid exceeding global memory cap
    MemoryCacheManager.instance.register(this, requestedMaxMemoryBytes);
  }

  /// Get a value and mark it as recently used
  T? get(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    _cache[key] = entry; // move to end
    return entry.value;
  }

  /// Put a value. Caller may provide a size estimate to avoid expensive heuristics.
  void put(String key, T value, {int? sizeBytes}) {
    if (sizeBytes != null && sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'Must be non-negative');
    }
    final oldEntry = _cache.remove(key);
    if (oldEntry != null) {
      _currentMemoryBytes -= oldEntry.sizeBytes;
    }

    final size = sizeBytes ?? _estimateSize(value);

    // Fast path: if single item larger than cap, don't store it
    if (size > maxMemoryBytes) return;

    _cache[key] = _CacheEntry(value, size);
    _currentMemoryBytes += size;

    _evictIfNeeded();
  }

  void remove(String key) {
    final entry = _cache.remove(key);
    if (entry != null) {
      _currentMemoryBytes -= entry.sizeBytes;
    }
  }

  void clear() {
    _cache.clear();
    _currentMemoryBytes = 0;
  }

  /// Internal API used by the manager to update a cache's cap
  void _applyMaxMemory(int newMax) {
    maxMemoryBytes = newMax;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    // Evict by entry count first
    while (_cache.length > maxEntries) {
      final first = _cache.entries.first;
      _cache.remove(first.key);
      _currentMemoryBytes -= first.value.sizeBytes;
      _onEvict(first.key, first.value.value);
    }

    // Evict by memory size
    while (_currentMemoryBytes > maxMemoryBytes && _cache.isNotEmpty) {
      final first = _cache.entries.first;
      _cache.remove(first.key);
      _currentMemoryBytes -= first.value.sizeBytes;
      _onEvict(first.key, first.value.value);
    }
  }

  @protected
  void _onEvict(String key, T value) {}

  int _estimateSize(T value) {
    if (value is Uint8List) return value.length;
    if (value is List<int>) return value.length;
    if (value is String) return value.length * 2;
    return 1024; // conservative default
  }

  int get entryCount => _cache.length;
  int get memoryBytes => _currentMemoryBytes;

  /// Call when the cache is no longer needed
  void dispose() {
    MemoryCacheManager.instance.unregister(this);
    clear();
  }
}

class _CacheEntry<T> {
  final T value;
  final int sizeBytes;
  _CacheEntry(this.value, this.sizeBytes);
}

/// Specialized cache for image bytes with accurate size estimation
class ImageMemoryCache extends MemoryCache<Uint8List> {
  ImageMemoryCache({
    int maxEntries = 30,
    int maxMemoryBytes = 100 * 1024 * 1024,
  }) // Increased to 100MB
  : super(maxEntries: maxEntries, maxMemoryBytes: maxMemoryBytes);

  @override
  int _estimateSize(Uint8List value) => value.length;
}

/// File cache manager for thumbnails with LRU cleanup
class ThumbnailFileCache {
  final int maxFiles;
  final int maxSizeBytes;
  final Directory cacheDir;
  final LinkedHashMap<String, DateTime> _accessTimes =
      LinkedHashMap<String, DateTime>();
  Timer? _cleanupTimer;
  late final Future<void> _initializing;
  bool _cleaning = false;
  bool _disposed = false;

  ThumbnailFileCache({
    this.maxFiles = 40,
    this.maxSizeBytes = 100 * 1024 * 1024,
    required this.cacheDir,
  }) {
    _cleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _cleanup(),
    ); // More frequent cleanup
    _initializing = _loadExistingFiles();
  }

  Future<void> _loadExistingFiles() async {
    try {
      if (!await cacheDir.exists()) return;
      await for (final file in cacheDir.list(followLinks: false)) {
        if (_disposed) return;
        if (file is! File) continue;
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) {
          _accessTimes.putIfAbsent(file.path, () => stat.accessed);
        }
      }
    } catch (e) {
      debugPrint('Error loading thumbnail files: $e');
    }
  }

  void recordAccess(String path) {
    _accessTimes.remove(path);
    _accessTimes[path] = DateTime.now();
  }

  Future<void> _cleanup() async {
    if (_cleaning || _disposed) return;
    _cleaning = true;
    try {
      await _initializing;
      if (_disposed || _accessTimes.isEmpty) return;
      await _cleanupFiles();
    } finally {
      _cleaning = false;
    }
  }

  Future<void> _cleanupFiles() async {
    final files = _accessTimes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    int totalSize = 0;
    int fileCount = 0;
    final toDelete = <MapEntry<String, DateTime>>[];

    for (final entry in files) {
      if (_disposed) return;
      try {
        final file = File(entry.key);
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) {
          final size = stat.size;
          totalSize += size;
          fileCount++;
          if (fileCount > maxFiles || totalSize > maxSizeBytes) {
            toDelete.add(entry);
          }
        } else {
          _accessTimes.remove(entry.key);
        }
      } catch (e) {
        debugPrint('Error checking thumbnail file: $e');
      }
    }

    for (final entry in toDelete) {
      if (_disposed) return;
      final path = entry.key;
      if (_accessTimes[path] != entry.value) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          if (_accessTimes[path] != entry.value) continue;
          await file.delete();
        }
        _accessTimes.remove(path);
        debugPrint('Cleaned up thumbnail: $path');
      } catch (e) {
        debugPrint('Error deleting thumbnail: $e');
      }
    }
  }

  void dispose() {
    _disposed = true;
    _cleanupTimer?.cancel();
  }
}

/// Global cache instances - more conservative limits to prevent memory leaks
final imageMemoryCache = ImageMemoryCache(
  maxEntries: 20,
  maxMemoryBytes: 50 * 1024 * 1024,
);
ThumbnailFileCache? _thumbnailCache;

ThumbnailFileCache getThumbnailCache() {
  _thumbnailCache ??= ThumbnailFileCache(
    cacheDir: Directory('${Directory.systemTemp.path}/smb_thumbs'),
    maxFiles: 40,
    maxSizeBytes: 100 * 1024 * 1024, // 100MB for thumbnails - more conservative
  );
  return _thumbnailCache!;
}

/// Memory pressure handler
class MemoryPressureHandler {
  static final MemoryPressureHandler _instance =
      MemoryPressureHandler._internal();
  factory MemoryPressureHandler() => _instance;
  MemoryPressureHandler._internal();

  final _listeners = <VoidCallback>[];
  Timer? _pressureCheckTimer;

  void initialize() {
    _pressureCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkMemoryPressure(),
    );
  }

  void dispose() {
    _pressureCheckTimer?.cancel();
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _checkMemoryPressure() {
    // Placeholder: platform-specific memory checks could be added here.
    // Intentionally left as a no-op until platform memory callbacks are wired.
  }

  void notifyLowMemory() {
    debugPrint('Low memory notification received - clearing all caches');
    imageMemoryCache.clear();
    getThumbnailCache()._cleanup();
  }
}
