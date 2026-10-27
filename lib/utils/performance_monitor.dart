// Performance monitoring and logging
import 'dart:async';
import 'package:flutter/material.dart';
import 'memory_cache.dart';
import 'file_cache_manager.dart';

/// Performance monitor and logger
class PerformanceMonitor {
  static final PerformanceMonitor _instance = PerformanceMonitor._internal();
  factory PerformanceMonitor() => _instance;
  PerformanceMonitor._internal();

  Timer? _reportTimer;
  final List<String> _logs = [];
  static const int _maxLogs = 1000;

  void initialize() {
    _reportTimer = Timer.periodic(const Duration(minutes: 1), (_) => _logStats());
  }

  void log(String message) {
    final timestamp = DateTime.now().toIso8601String();
    final logEntry = '[$timestamp] $message';
    _logs.add(logEntry);
    
    // Keep log size bounded
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    
    debugPrint(logEntry);
  }

  void _logStats() {
    final imageCacheStats = imageMemoryCache.entryCount;
    final imageCacheMB = imageMemoryCache.memoryBytes / 1024 / 1024;
    final fileCacheStats = fileCacheManager.getStats();
    
    log('STATS - Image cache: $imageCacheStats items, ${imageCacheMB.toStringAsFixed(2)} MB | '
        'File cache: ${fileCacheStats['entries']} items, ${(fileCacheStats['sizeBytes'] as int) / 1024 / 1024 ~/ 1} MB');
  }

  List<String> getLogs({int limit = 100}) {
    return _logs.skip((_logs.length - limit).clamp(0, _logs.length)).toList();
  }

  void clearLogs() {
    _logs.clear();
  }

  void dispose() {
    _reportTimer?.cancel();
  }
}

/// Global performance monitor
final performanceMonitor = PerformanceMonitor();
