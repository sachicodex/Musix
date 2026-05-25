import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class AndroidMediaNotificationBridge {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.sachicodex.musix/media_notification',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.sachicodex.musix/media_notification_actions',
  );

  static const String _actionPlayPause = 'play_pause';
  static const String _actionPlay = 'play';
  static const String _actionPause = 'pause';
  static const String _actionNext = 'next';
  static const String _actionPrevious = 'previous';
  static String? _lastTitle;
  static String? _lastArtist;
  static String? _lastAlbum;
  static String? _lastArtUri;
  static bool? _lastIsPlaying;
  static bool? _lastIsLoading;
  static int? _lastDurationMs;
  static int _lastPositionMs = 0;
  static DateTime? _lastUpdateAt;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Stream<String> actionStream() {
    if (!isSupported) {
      return const Stream<String>.empty();
    }
    return _eventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => (event as Map<dynamic, dynamic>)['action'])
        .where((dynamic action) => action is String)
        .cast<String>();
  }

  static Future<void> updatePlayback({
    required LibrarySong? song,
    required bool isPlaying,
    required bool isLoading,
    required Duration position,
    required Duration duration,
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
        _lastIsLoading != isLoading ||
        _lastDurationMs != durationMs;
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
    _lastIsLoading = isLoading;
    _lastDurationMs = durationMs;
    _lastPositionMs = positionMs;
    _lastUpdateAt = now;

    await _methodChannel
        .invokeMethod<void>('updateNotification', <String, dynamic>{
          'title': title,
          'artist': artist,
          'album': album,
          'artUri': artUri,
          'isPlaying': isPlaying,
          'isLoading': isLoading,
          'positionMs': positionMs,
          'durationMs': durationMs,
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
    _lastIsLoading = null;
    _lastDurationMs = null;
    _lastPositionMs = 0;
    _lastUpdateAt = null;
    await _methodChannel.invokeMethod<void>('stopNotification');
  }

  static bool isToggleAction(String action) {
    return action == _actionPlayPause;
  }

  static bool isPlayAction(String action) => action == _actionPlay;

  static bool isPauseAction(String action) => action == _actionPause;

  static bool isNextAction(String action) => action == _actionNext;

  static bool isPreviousAction(String action) => action == _actionPrevious;
}
