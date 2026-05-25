import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class WindowsMediaControlsBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.sachicodex.musix/windows_media_controls',
  );

  static const String _actionPlayPause = 'play_pause';
  static const String _actionPlay = 'play';
  static const String _actionPause = 'pause';
  static const String _actionNext = 'next';
  static const String _actionPrevious = 'previous';

  static StreamController<String>? _actionController;
  static bool _methodHandlerBound = false;
  static String? _lastTitle;
  static String? _lastArtist;
  static String? _lastAlbum;
  static String? _lastArtUri;
  static bool? _lastIsPlaying;
  static int? _lastDurationMs;
  static int? _lastQueueIndex;
  static int? _lastQueueLength;
  static int _lastPositionMs = 0;
  static DateTime? _lastUpdateAt;

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  static Stream<String> actionStream() {
    if (!isSupported) {
      return const Stream<String>.empty();
    }
    _ensureMethodHandler();
    return (_actionController ??= StreamController<String>.broadcast()).stream;
  }

  static Future<void> updatePlayback({
    required LibrarySong? song,
    required bool isPlaying,
    required Duration position,
    required Duration duration,
    required int queueIndex,
    required int queueLength,
  }) async {
    if (!isSupported) {
      return;
    }

    final String title = song?.title ?? 'Nothing playing';
    final String artist = song?.artist ?? 'Unknown artist';
    final String album = song?.album ?? 'Unknown album';
    final String? artUri = song?.artworkUrl;
    final int durationMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds
        : (song?.durationMs ?? 0);
    final int positionMs = position.inMilliseconds;
    final DateTime now = DateTime.now();
    final bool meaningfullyChanged =
        _lastTitle != title ||
        _lastArtist != artist ||
        _lastAlbum != album ||
        _lastArtUri != artUri ||
        _lastIsPlaying != isPlaying ||
        _lastDurationMs != durationMs ||
        _lastQueueIndex != queueIndex ||
        _lastQueueLength != queueLength;
    final bool positionRefreshDue =
        _lastUpdateAt == null ||
        now.difference(_lastUpdateAt!) >= const Duration(seconds: 1) ||
        (positionMs - _lastPositionMs).abs() >= 2000;

    if (!meaningfullyChanged && !positionRefreshDue) {
      return;
    }

    _lastTitle = title;
    _lastArtist = artist;
    _lastAlbum = album;
    _lastArtUri = artUri;
    _lastIsPlaying = isPlaying;
    _lastDurationMs = durationMs;
    _lastQueueIndex = queueIndex;
    _lastQueueLength = queueLength;
    _lastPositionMs = positionMs;
    _lastUpdateAt = now;

    await _channel.invokeMethod<void>('updateMediaState', <String, dynamic>{
      'title': title,
      'artist': artist,
      'album': album,
      'artUri': artUri,
      'isPlaying': isPlaying,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'hasPrevious': queueLength > 1 || queueIndex > 0,
      'hasNext': queueIndex >= 0 && queueIndex < queueLength - 1,
    });
  }

  static Future<void> stop() async {
    if (!isSupported) {
      return;
    }
    _lastTitle = null;
    _lastArtist = null;
    _lastAlbum = null;
    _lastArtUri = null;
    _lastIsPlaying = null;
    _lastDurationMs = null;
    _lastQueueIndex = null;
    _lastQueueLength = null;
    _lastPositionMs = 0;
    _lastUpdateAt = null;
    await _channel.invokeMethod<void>('clearMediaState');
  }

  static bool isToggleAction(String action) => action == _actionPlayPause;

  static bool isPlayAction(String action) => action == _actionPlay;

  static bool isPauseAction(String action) => action == _actionPause;

  static bool isNextAction(String action) => action == _actionNext;

  static bool isPreviousAction(String action) => action == _actionPrevious;

  static void _ensureMethodHandler() {
    if (_methodHandlerBound) {
      return;
    }
    _methodHandlerBound = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'mediaAction') {
        return;
      }
      final dynamic arguments = call.arguments;
      if (arguments is! Map<Object?, Object?>) {
        return;
      }
      final Object? action = arguments['action'];
      if (action is String && action.isNotEmpty) {
        (_actionController ??= StreamController<String>.broadcast()).add(
          action,
        );
      }
    });
  }
}
