import 'package:flutter/foundation.dart';

class AppLogger {
  AppLogger._();

  static final Stopwatch _uptime = Stopwatch()..start();
  static const Set<String> _enabledDebugScopes = <String>{'Controller'};

  static void info(String scope, String message) {
    _emit('INFO', scope, message, always: true);
  }

  static void trace(String scope, String message) {
    _emit('TRACE', scope, message, always: false);
  }

  static void warn(String scope, String message) {
    _emit('WARN', scope, message, always: true);
  }

  static void error(String scope, String message) {
    _emit('ERROR', scope, message, always: true);
  }

  static Future<T> timeAsync<T>(
    String scope,
    String label,
    Future<T> Function() action,
  ) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    trace(scope, '$label started');
    try {
      final T result = await action();
      stopwatch.stop();
      info(scope, '$label completed in ${stopwatch.elapsedMilliseconds}ms');
      return result;
    } catch (error) {
      stopwatch.stop();
      AppLogger.error(
        scope,
        '$label failed after ${stopwatch.elapsedMilliseconds}ms: $error',
      );
      rethrow;
    }
  }

  static void _emit(
    String level,
    String scope,
    String message, {
    required bool always,
  }) {
    if (!kDebugMode) {
      return;
    }
    if (!_enabledDebugScopes.contains(scope)) {
      return;
    }
    final String elapsed = _formatElapsed(_uptime.elapsed);
    debugPrint('[$level][$elapsed][$scope] $message');
  }

  static String _formatElapsed(Duration duration) {
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);
    final int millis = duration.inMilliseconds.remainder(1000);
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }
}
