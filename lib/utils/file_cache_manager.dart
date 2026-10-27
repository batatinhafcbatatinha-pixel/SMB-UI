// Comprehensive file cache manager with LRU eviction and size limits
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Cache entry metadata
class _CacheEntry {
  final String path;
  final int size;
  DateTime lastAccess;

  _CacheEntry({
    required this.path,
    required this.size,
    required this.lastAccess,
  });

  void touch() {
    lastAccess = DateTime.now();
  }
}

/// LRU File Cache Manager with automatic cleanup
class FileCacheManager {
  static final FileCacheManager _instance = FileCacheManager._internal();
  factory FileCacheManager() => _instance;
  FileCacheManager._internal();

  // Configuration
  int maxCacheEntries = 300;
  int maxCacheSizeBytes = 800 * 1024 * 1024; // 800 MB
  Duration maxFileAge = const Duration(hours: 12); // Reduced from 24
  Duration cleanupInterval = const Duration(
    minutes: 5,
  ); // More frequent cleanup

  // State
  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();
  int _currentSize = 0;
  bool _initialized = false;
  Future<void>? _initializing;
  Future<void>? _cleaning;
  Timer? _cleanupTimer;
  Directory? _cacheDir;

  /// Initialize the cache manager
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<void> _initialize() async {
    try {
      final appDir = await getTemporaryDirectory();
      _cacheDir = Directory('${appDir.path}/smb_media_cache');

      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }

      // Load existing files
      await _loadExistingFiles();

      // Start periodic cleanup
      _cleanupTimer = Timer.periodic(cleanupInterval, (_) => _performCleanup());

      _initialized = true;
      if (kDebugMode) {
        debugPrint(
          'FileCacheManager initialized: ${_entries.length} files, ${_currentSize ~/ 1024 ~/ 1024} MB',
        );
      }
    } catch (e) {
      debugPrint('Error initializing FileCacheManager: $e');
      rethrow;
    }
  }

  /// Get cache directory
  Directory get cacheDir {
    if (!_initialized || _cacheDir == null) {
      throw StateError(
        'FileCacheManager not initialized. Call initialize() first.',
      );
    }
    return _cacheDir!;
  }

  /// Load existing cache files from disk
  Future<void> _loadExistingFiles() async {
    if (_cacheDir == null) return;
    _entries.clear();
    _currentSize = 0;

    try {
      final files = await _cacheDir!
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();

      for (final file in files) {
        try {
          final stat = await file.stat();
          final path = file.path;

          _entries[path] = _CacheEntry(
            path: path,
            size: stat.size,
            lastAccess: stat.accessed,
          );
          _currentSize += stat.size;
        } catch (e) {
          debugPrint('Error loading cache entry: $e');
        }
      }

      // Sort by last access time
      final sorted = _entries.entries.toList()
        ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));

      _entries.clear();
      for (final entry in sorted) {
        _entries[entry.key] = entry.value;
      }
    } catch (e) {
      debugPrint('Error loading existing files: $e');
    }
  }

  /// Register a file in the cache
  void registerFile(String path, int size) {
    if (size < 0) throw ArgumentError.value(size, 'size');
    final existing = _entries.remove(path);
    if (existing != null) {
      _currentSize -= existing.size;
    }

    _entries[path] = _CacheEntry(
      path: path,
      size: size,
      lastAccess: DateTime.now(),
    );
    _currentSize += size;

    // Trigger async cleanup if needed
    if (_entries.length > maxCacheEntries || _currentSize > maxCacheSizeBytes) {
      Future.microtask(() => _performCleanup());
    }
  }

  /// Touch a file (update access time)
  void touch(String path) {
    final entry = _entries[path];
    if (entry != null) {
      entry.touch();
      // Move to end (most recent)
      _entries.remove(path);
      _entries[path] = entry;
    }
  }

  /// Check if a file is in cache
  bool contains(String path) {
    return _entries.containsKey(path);
  }

  /// Delete a specific file from cache
  Future<void> delete(String path) async {
    final entry = _entries.remove(path);
    if (entry != null) {
      _currentSize -= entry.size;
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // Retain failed deletions so a later cleanup can reclaim the file.
        if (!_entries.containsKey(path)) {
          _entries[path] = entry;
          _currentSize += entry.size;
        }
        debugPrint('Error deleting cache file: $e');
      }
    }
  }

  /// Clear all cache
  Future<void> clearAll() async {
    final paths = _entries.keys.toList();
    for (final path in paths) {
      await delete(path);
    }
  }

  /// Perform cleanup of old/large cache
  Future<void> _performCleanup() {
    return _cleaning ??= _cleanup().whenComplete(() => _cleaning = null);
  }

  Future<void> _cleanup() async {
    if (_entries.isEmpty) return;
    final initialSize = _currentSize;

    final now = DateTime.now();
    final toDelete = <String>[];

    // Check age and size limits
    int currentCount = _entries.length;
    int currentSize = _currentSize;

    // Build sorted list (oldest first)
    final sorted = _entries.entries.toList();

    for (final entry in sorted) {
      final age = now.difference(entry.value.lastAccess);

      // Delete if:
      // 1. Too old
      // 2. Over count limit
      // 3. Over size limit
      if (age > maxFileAge ||
          currentCount > maxCacheEntries ||
          currentSize > maxCacheSizeBytes) {
        toDelete.add(entry.key);
        currentCount--;
        currentSize -= entry.value.size;
      }
    }

    // Execute deletions
    for (final path in toDelete) {
      await delete(path);
    }

    if (toDelete.isNotEmpty && kDebugMode) {
      debugPrint(
        'Cache cleanup: deleted ${toDelete.length} files, freed ${(initialSize - _currentSize) ~/ 1024 ~/ 1024} MB',
      );
    }
  }

  /// Get cache statistics
  Map<String, dynamic> getStats() {
    return {
      'entries': _entries.length,
      'sizeBytes': _currentSize,
      'sizeMB': _currentSize / 1024 / 1024,
      'maxEntries': maxCacheEntries,
      'maxSizeMB': maxCacheSizeBytes / 1024 / 1024,
    };
  }

  /// Generate a cache-safe filename
  String generateCachePath(String originalPath, {String? prefix}) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final hash = originalPath.hashCode.abs();
    final ext = originalPath.contains('.')
        ? originalPath.substring(originalPath.lastIndexOf('.'))
        : '';

    final name = '${prefix ?? 'cached'}_${timestamp}_$hash$ext';
    return '${cacheDir.path}/$name';
  }

  /// Dispose the manager
  void dispose() {
    _cleanupTimer?.cancel();
  }
}

/// Global instance
final fileCacheManager = FileCacheManager();

/// Helper to track file access and auto-delete on dispose
class TrackedFile {
  final String path;
  bool _disposed = false;

  TrackedFile(this.path);

  void touch() {
    if (!_disposed) {
      fileCacheManager.touch(path);
    }
  }

  void delete() async {
    if (!_disposed) {
      _disposed = true;
      await fileCacheManager.delete(path);
    }
  }

  void dispose() {
    // Mark for potential cleanup
    touch();
  }
}

/// Widget mixin for handling temporary files
mixin TempFileHandler<T extends StatefulWidget> on State<T> {
  final List<String> _tempFiles = [];

  void registerTempFile(String path) {
    _tempFiles.add(path);
    fileCacheManager.registerFile(path, File(path).lengthSync());
  }

  Future<void> cleanupTempFiles() async {
    for (final path in _tempFiles) {
      await fileCacheManager.delete(path);
    }
    _tempFiles.clear();
  }

  @override
  void dispose() {
    cleanupTempFiles();
    super.dispose();
  }
}
