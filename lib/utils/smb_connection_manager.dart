// SMB Connection Manager with Keepalive, Auto-Retry and Exponential Backoff
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Manages SMB connections with keepalive, auto-retry, and exponential backoff
class SMBConnectionManager {
  static final SMBConnectionManager _instance =
      SMBConnectionManager._internal();
  factory SMBConnectionManager() => _instance;
  SMBConnectionManager._internal();

  static const platform = MethodChannel('smb_channel');

  // Connection state tracking
  final Map<String, _ConnectionState> _connections = {};
  Timer? _keepaliveTimer;

  // Configuration
  // Increased keepalive interval to reduce aggressive reconnection.
  // SMB connections on a LAN should remain valid for much longer than 10 minutes.
  static const Duration _keepaliveInterval = Duration(hours: 1);
  static const Duration _initialRetryDelay = Duration(milliseconds: 1000);
  static const Duration _maxRetryDelay = Duration(minutes: 5);
  static const int _maxRetryAttempts = 3;
  static const double _exponentialBackoffBase = 2.0;

  /// Initialize connection manager
  void initialize() {
    _keepaliveTimer?.cancel();
    debugPrint('SMBConnectionManager: Initializing keepalive');
    _keepaliveTimer =
        Timer.periodic(_keepaliveInterval, (_) => _performKeepalive());
  }

  /// Register a connection
  void registerConnection(String key, String ip, String share,
      {String username = '', String password = ''}) {
    _connections[key] = _ConnectionState(
      key: key,
      ip: ip,
      share: share,
      username: username,
      password: password,
      lastActivity: DateTime.now(),
    );
    debugPrint('SMBConnectionManager: Registered connection $key @ $ip/$share');
  }

  /// Unregister a connection
  void unregisterConnection(String key) {
    _connections.remove(key);
    debugPrint('SMBConnectionManager: Unregistered connection $key');
  }

  /// Record activity on a connection
  void recordActivity(String key) {
    final conn = _connections[key];
    if (conn != null) {
      conn.lastActivity = DateTime.now();
      conn.consecutiveFailures = 0; // Reset on success
    }
  }

  /// Perform keepalive check on all connections
  void _performKeepalive() {
    // Iterate over a snapshot to avoid concurrent modification if connections map changes
    for (final conn in _connections.values.toList()) {
      _checkConnectionHealth(conn);
    }
  }

  /// Check health of a single connection
  Future<void> _checkConnectionHealth(_ConnectionState conn) async {
    if (conn.checking || !identical(_connections[conn.key], conn)) return;
    // Skip keepalive for connections that were used recently.
    if (DateTime.now().difference(conn.lastActivity) <
        const Duration(minutes: 3)) {
      return;
    }

    conn.checking = true;
    try {
      // Simple list check to verify connection is alive
      final result = await platform.invokeMethod('listShares', {
        'ip': conn.ip,
        'username': conn.username,
        'password': conn.password,
      }).timeout(const Duration(seconds: 6));

      if (result != null) {
        conn.consecutiveFailures = 0;
        conn.lastActivity = DateTime.now();
        debugPrint('SMBConnectionManager: Keepalive OK for ${conn.key}');
      } else {
        await _handleConnectionFailure(conn);
      }
    } catch (e) {
      await _handleConnectionFailure(conn);
    } finally {
      conn.checking = false;
    }
  }

  /// Handle connection failure with retry logic
  Future<void> _handleConnectionFailure(_ConnectionState conn) {
    return _retryConnectionWithBackoff(conn);
  }

  /// Retry connection with exponential backoff
  Future<void> _retryConnectionWithBackoff(_ConnectionState conn) async {
    conn.consecutiveFailures++;

    if (conn.consecutiveFailures > _maxRetryAttempts) {
      debugPrint('SMBConnectionManager: Max retries exceeded for ${conn.key}');
      return;
    }

    // Calculate exponential backoff delay
    final delayMs = (_initialRetryDelay.inMilliseconds *
            (math.pow(_exponentialBackoffBase, conn.consecutiveFailures - 1)))
        .toInt()
        .clamp(0, _maxRetryDelay.inMilliseconds);
    final delay = Duration(milliseconds: delayMs);

    debugPrint(
        'SMBConnectionManager: Retry ${conn.consecutiveFailures} for ${conn.key} in ${delay.inSeconds}s');

    // Wait before retry
    await Future.delayed(delay);
    if (!identical(_connections[conn.key], conn)) return;

    // Attempt reconnection
    try {
      final result = await platform.invokeMethod('listShares', {
        'ip': conn.ip,
        'username': conn.username,
        'password': conn.password,
      }).timeout(const Duration(seconds: 10));

      if (result != null) {
        conn.consecutiveFailures = 0;
        conn.lastActivity = DateTime.now();
        debugPrint('SMBConnectionManager: Reconnected to ${conn.key}');
      } else {
        // Retry again if still failing
        if (conn.consecutiveFailures < _maxRetryAttempts) {
          await _retryConnectionWithBackoff(conn);
        }
      }
    } catch (e) {
      // If still failing, retry again
      if (conn.consecutiveFailures < _maxRetryAttempts) {
        await _retryConnectionWithBackoff(conn);
      }
    }
  }

  /// Get connection state info
  Map<String, dynamic> getConnectionState(String key) {
    final conn = _connections[key];
    if (conn == null) return {};

    return {
      'key': conn.key,
      'ip': conn.ip,
      'share': conn.share,
      'lastActivity': conn.lastActivity.toIso8601String(),
      'consecutiveFailures': conn.consecutiveFailures,
      'isHealthy': conn.consecutiveFailures == 0,
    };
  }

  /// Get all connections state
  Map<String, dynamic> getAllConnectionsState() {
    // Build from a snapshot to avoid concurrent modification
    final snapshot = _connections.values.toList();
    final Map<String, dynamic> out = {};
    for (final conn in snapshot) {
      out[conn.key] = getConnectionState(conn.key);
    }
    return out;
  }

  /// Clear all connections and stop timers
  void dispose() {
    _keepaliveTimer?.cancel();
    _connections.clear();
    debugPrint('SMBConnectionManager: Disposed');
  }
}

/// Internal connection state tracker
class _ConnectionState {
  final String key;
  final String ip;
  final String share;
  final String username;
  final String password;

  DateTime lastActivity;
  int consecutiveFailures = 0;
  bool checking = false;

  _ConnectionState({
    required this.key,
    required this.ip,
    required this.share,
    required this.username,
    required this.password,
    required this.lastActivity,
  });
}

/// Global instance
final smbConnectionManager = SMBConnectionManager();
