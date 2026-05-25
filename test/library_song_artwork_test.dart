import 'package:flutter_test/flutter_test.dart';

import 'package:musix/core/models.dart';

void main() {
  LibrarySong remoteSong({
    required String id,
    required String path,
    String? artworkUrl,
  }) {
    return LibrarySong(
      id: id,
      path: path,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      albumArtist: 'Artist',
      folderName: 'YouTube',
      folderPath: 'youtube',
      sourceLabel: 'YouTube',
      addedAt: DateTime(2026, 4, 27),
      durationMs: 180000,
      isRemote: true,
      artworkUrl: artworkUrl,
    );
  }

  test('normalizes google hosted remote artwork on construction', () {
    final LibrarySong song = remoteSong(
      id: 'yt:abc123def45',
      path: 'https://music.youtube.com/watch?v=abc123def45',
      artworkUrl: 'https://lh3.googleusercontent.com/abc=w120-h120-p-l90-rj',
    );

    expect(
      song.artworkUrl,
      'https://lh3.googleusercontent.com/abc=w320-h320-l90-rj',
    );
  });

  test(
    'derives youtube artwork when a remote song is restored without art',
    () {
      final LibrarySong song = LibrarySong.fromJson(<String, dynamic>{
        'id': 'yt:abc123def45',
        'path': 'https://www.youtube.com/watch?v=abc123def45',
        'title': 'Song',
        'artist': 'Artist',
        'album': 'Album',
        'albumArtist': 'Artist',
        'folderName': 'YouTube',
        'folderPath': 'youtube',
        'sourceLabel': 'YouTube',
        'addedAt': DateTime(2026, 4, 27).toIso8601String(),
        'durationMs': 180000,
        'isRemote': true,
        'artworkUrl': '   ',
      });

      expect(
        song.artworkUrl,
        'https://i.ytimg.com/vi/abc123def45/hqdefault.jpg',
      );
    },
  );

  test('canonicalizes volatile ytimg artwork urls for remote songs', () {
    final LibrarySong song = remoteSong(
      id: 'yt:abc123def45',
      path: 'https://www.youtube.com/watch?v=abc123def45',
      artworkUrl:
          'https://i.ytimg.com/vi_webp/abc123def45/hqdefault.webp?foo=bar',
    );

    expect(song.artworkUrl, 'https://i.ytimg.com/vi/abc123def45/hqdefault.jpg');
  });

  test('falls back to youtube artwork when remote artwork is malformed', () {
    final LibrarySong song = remoteSong(
      id: 'yt:abc123def45',
      path: 'https://www.youtube.com/watch?v=abc123def45',
      artworkUrl: 'not-a-real-artwork-url',
    );

    expect(song.artworkUrl, 'https://i.ytimg.com/vi/abc123def45/hqdefault.jpg');
  });
}
