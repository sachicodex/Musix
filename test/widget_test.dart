import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musix/core/models.dart';

void main() {
  test('app settings deserialize supported fields', () {
    final AppSettings settings = AppSettings.fromJson(<String, dynamic>{
      'themeModeIndex': ThemeMode.dark.index,
      'denseLibrary': true,
      'useGridView': false,
      'playbackRate': 1.25,
      'smartQueueEnabled': false,
      'ytMusicAuthJson': '{"cookie":"abc"}',
    });

    expect(settings.denseLibrary, isTrue);
    expect(settings.useGridView, isFalse);
    expect(settings.playbackRate, 1.25);
    expect(settings.smartQueueEnabled, isFalse);
    expect(settings.ytMusicAuthJson, '{"cookie":"abc"}');
  });

  test('library song copyWith updates user state', () {
    final LibrarySong song = LibrarySong(
      id: 'track-1',
      path: 'C:/music/song.mp3',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      albumArtist: 'Artist',
      folderName: 'music',
      folderPath: 'C:/music',
      sourceLabel: 'music',
      addedAt: DateTime(2026, 4, 15),
      durationMs: 123000,
    );

    final LibrarySong updated = song.copyWith(
      isFavorite: true,
      playCount: 4,
      lastPlayedAt: DateTime(2026, 4, 16),
    );

    expect(updated.isFavorite, isTrue);
    expect(updated.playCount, 4);
    expect(updated.lastPlayedAt, DateTime(2026, 4, 16));
    expect(updated.title, 'Song');
    expect(song.isFavorite, isFalse);
  });
}
