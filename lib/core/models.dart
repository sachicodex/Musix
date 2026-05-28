import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

enum AppDestination {
  home('Home', Icons.home_rounded, Icons.home_outlined),
  library('Library', Icons.library_music_rounded, Icons.library_music_outlined),
  search('Search', Icons.manage_search_rounded, Icons.search_rounded),
  settings(
    'Profile',
    Icons.account_circle_rounded,
    Icons.person_outline_rounded,
  );

  const AppDestination(this.label, this.selectedIcon, this.unselectedIcon);

  final String label;
  final IconData selectedIcon;
  final IconData unselectedIcon;
}

enum LibraryFilter {
  all('All'),
  songs('Songs'),
  folders('Folders'),
  artists('Artists'),
  albums('Albums'),
  playlists('Playlists');

  const LibraryFilter(this.label);

  final String label;
}

class AppRegion {
  const AppRegion({
    required this.countryCode,
    required this.label,
    required this.languageCode,
  });

  final String countryCode;
  final String label;
  final String languageCode;
}

const List<AppRegion> kAppRegions = <AppRegion>[
  AppRegion(countryCode: 'LK', label: 'Sri Lanka', languageCode: 'si'),
  AppRegion(countryCode: 'IN', label: 'India', languageCode: 'hi'),
  AppRegion(countryCode: 'PK', label: 'Pakistan', languageCode: 'ur'),
  AppRegion(countryCode: 'BD', label: 'Bangladesh', languageCode: 'bn'),
  AppRegion(countryCode: 'NP', label: 'Nepal', languageCode: 'ne'),
  AppRegion(
    countryCode: 'AE',
    label: 'United Arab Emirates',
    languageCode: 'ar',
  ),
  AppRegion(countryCode: 'SA', label: 'Saudi Arabia', languageCode: 'ar'),
  AppRegion(countryCode: 'QA', label: 'Qatar', languageCode: 'ar'),
  AppRegion(countryCode: 'SG', label: 'Singapore', languageCode: 'en'),
  AppRegion(countryCode: 'MY', label: 'Malaysia', languageCode: 'ms'),
  AppRegion(countryCode: 'TH', label: 'Thailand', languageCode: 'th'),
  AppRegion(countryCode: 'ID', label: 'Indonesia', languageCode: 'id'),
  AppRegion(countryCode: 'PH', label: 'Philippines', languageCode: 'en'),
  AppRegion(countryCode: 'US', label: 'United States', languageCode: 'en'),
  AppRegion(countryCode: 'GB', label: 'United Kingdom', languageCode: 'en'),
  AppRegion(countryCode: 'CA', label: 'Canada', languageCode: 'en'),
  AppRegion(countryCode: 'AU', label: 'Australia', languageCode: 'en'),
  AppRegion(countryCode: 'NZ', label: 'New Zealand', languageCode: 'en'),
  AppRegion(countryCode: 'DE', label: 'Germany', languageCode: 'de'),
  AppRegion(countryCode: 'FR', label: 'France', languageCode: 'fr'),
  AppRegion(countryCode: 'IT', label: 'Italy', languageCode: 'it'),
  AppRegion(countryCode: 'ES', label: 'Spain', languageCode: 'es'),
  AppRegion(countryCode: 'NL', label: 'Netherlands', languageCode: 'nl'),
  AppRegion(countryCode: 'SE', label: 'Sweden', languageCode: 'sv'),
  AppRegion(countryCode: 'NO', label: 'Norway', languageCode: 'no'),
  AppRegion(countryCode: 'DK', label: 'Denmark', languageCode: 'da'),
  AppRegion(countryCode: 'FI', label: 'Finland', languageCode: 'fi'),
  AppRegion(countryCode: 'TR', label: 'Turkey', languageCode: 'tr'),
  AppRegion(countryCode: 'BR', label: 'Brazil', languageCode: 'pt'),
  AppRegion(countryCode: 'MX', label: 'Mexico', languageCode: 'es'),
  AppRegion(countryCode: 'AR', label: 'Argentina', languageCode: 'es'),
  AppRegion(countryCode: 'ZA', label: 'South Africa', languageCode: 'en'),
  AppRegion(countryCode: 'JP', label: 'Japan', languageCode: 'ja'),
  AppRegion(countryCode: 'KR', label: 'South Korea', languageCode: 'ko'),
];

String? normalizeArtworkUrl(
  String? artworkUrl, {
  String? songId,
  String? path,
  bool isRemote = false,
}) {
  final String value = (artworkUrl ?? '').trim();
  final String? videoId = isRemote
      ? _extractYouTubeVideoId(songId: songId, path: path)
      : null;
  if (value.isEmpty) {
    return videoId == null ? null : _youtubeArtworkUrl(videoId);
  }

  final Uri? uri = Uri.tryParse(value);
  if (uri == null) {
    return videoId == null ? value : _youtubeArtworkUrl(videoId);
  }
  if (uri.host.isEmpty && videoId != null) {
    return _youtubeArtworkUrl(videoId);
  }

  final String host = uri.host.toLowerCase();
  if (host.contains('googleusercontent.com') ||
      host.contains('yt3.ggpht.com')) {
    final String normalizedPath = uri.path.replaceFirst(
      RegExp(r'=[^/?#]+$'),
      '=w320-h320-l90-rj',
    );
    final Map<String, String> params = Map<String, String>.from(
      uri.queryParameters,
    );
    bool changed = normalizedPath != uri.path;
    if (params.containsKey('w') && params['w'] != '320') {
      params['w'] = '320';
      changed = true;
    }
    if (params.containsKey('h') && params['h'] != '320') {
      params['h'] = '320';
      changed = true;
    }
    if (changed) {
      return uri
          .replace(
            path: normalizedPath,
            queryParameters: params.isEmpty ? null : params,
          )
          .toString();
    }
    return value;
  }

  if (videoId != null && host.contains('ytimg.com')) {
    return _youtubeArtworkUrl(videoId);
  }

  return value;
}

String? _extractYouTubeVideoId({String? songId, String? path}) {
  final String normalizedSongId = (songId ?? '').trim();
  if (normalizedSongId.startsWith('yt:')) {
    final String value = normalizedSongId.substring(3).trim();
    if (value.isNotEmpty) {
      return value;
    }
  }

  final String normalizedPath = (path ?? '').trim();
  if (normalizedPath.isEmpty) {
    return null;
  }
  if (normalizedPath.startsWith('yt:')) {
    final String value = normalizedPath.substring(3).trim();
    if (value.isNotEmpty) {
      return value;
    }
  }

  final Uri? uri = Uri.tryParse(normalizedPath);
  if (uri == null) {
    return null;
  }

  final String host = uri.host.toLowerCase();
  if (host.contains('youtu.be')) {
    final String value = uri.pathSegments.firstWhere(
      (String segment) => segment.trim().isNotEmpty,
      orElse: () => '',
    );
    return value.isEmpty ? null : value;
  }
  if (host.contains('youtube.com') || host.contains('music.youtube.com')) {
    final String value = (uri.queryParameters['v'] ?? '').trim();
    return value.isEmpty ? null : value;
  }
  if (host.contains('ytimg.com') && uri.pathSegments.length >= 2) {
    final String kind = uri.pathSegments.first;
    if (kind == 'vi' || kind == 'vi_webp') {
      final String value = uri.pathSegments[1].trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

String _youtubeArtworkUrl(String videoId) {
  return 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
}

class AppSettings {
  const AppSettings({
    this.denseLibrary = false,
    this.useGridView = true,
    this.playbackRate = 1.0,
    this.smartQueueEnabled = true,
    this.offlinePlaybackCacheEnabled = true,
    this.offlineMusicMode = false,
    this.nextChanceSongCount = 1,
    this.preloadNextSongCount = 1,
    this.sleepTimerMinutes = 0,
    this.preferredCountryCode = 'LK',
    this.ytMusicAuthJson,
  });

  final bool denseLibrary;
  final bool useGridView;
  final double playbackRate;
  final bool smartQueueEnabled;
  final bool offlinePlaybackCacheEnabled;
  final bool offlineMusicMode;
  final int nextChanceSongCount;
  final int preloadNextSongCount;
  final int sleepTimerMinutes;
  final String preferredCountryCode;
  final String? ytMusicAuthJson;

  AppSettings copyWith({
    bool? denseLibrary,
    bool? useGridView,
    double? playbackRate,
    bool? smartQueueEnabled,
    bool? offlinePlaybackCacheEnabled,
    bool? offlineMusicMode,
    int? nextChanceSongCount,
    int? preloadNextSongCount,
    int? sleepTimerMinutes,
    String? preferredCountryCode,
    String? ytMusicAuthJson,
  }) {
    return AppSettings(
      denseLibrary: denseLibrary ?? this.denseLibrary,
      useGridView: useGridView ?? this.useGridView,
      playbackRate: playbackRate ?? this.playbackRate,
      smartQueueEnabled: smartQueueEnabled ?? this.smartQueueEnabled,
      offlinePlaybackCacheEnabled:
          offlinePlaybackCacheEnabled ?? this.offlinePlaybackCacheEnabled,
      offlineMusicMode: offlineMusicMode ?? this.offlineMusicMode,
      nextChanceSongCount: nextChanceSongCount ?? this.nextChanceSongCount,
      preloadNextSongCount: preloadNextSongCount ?? this.preloadNextSongCount,
      sleepTimerMinutes: sleepTimerMinutes ?? this.sleepTimerMinutes,
      preferredCountryCode: preferredCountryCode ?? this.preferredCountryCode,
      ytMusicAuthJson: ytMusicAuthJson ?? this.ytMusicAuthJson,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'denseLibrary': denseLibrary,
      'useGridView': useGridView,
      'playbackRate': playbackRate,
      'smartQueueEnabled': smartQueueEnabled,
      'offlinePlaybackCacheEnabled': offlinePlaybackCacheEnabled,
      'offlineMusicMode': offlineMusicMode,
      'nextChanceSongCount': nextChanceSongCount,
      'preloadNextSongCount': preloadNextSongCount,
      'preferredCountryCode': preferredCountryCode,
      'ytMusicAuthJson': ytMusicAuthJson,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const AppSettings();
    }

    final String preferredCountryCode =
        (json['preferredCountryCode'] as String? ?? 'LK').trim().toUpperCase();
    final int nextChanceSongCount =
        (json['nextChanceSongCount'] as num?)?.toInt().clamp(0, 5) ?? 1;
    final int preloadNextSongCount =
        (json['preloadNextSongCount'] as num?)?.toInt().clamp(0, 3) ?? 1;
    return AppSettings(
      denseLibrary: json['denseLibrary'] as bool? ?? false,
      useGridView: json['useGridView'] as bool? ?? true,
      playbackRate: (json['playbackRate'] as num?)?.toDouble() ?? 1.0,
      smartQueueEnabled: json['smartQueueEnabled'] as bool? ?? true,
      offlinePlaybackCacheEnabled:
          json['offlinePlaybackCacheEnabled'] as bool? ?? true,
      offlineMusicMode: json['offlineMusicMode'] as bool? ?? false,
      nextChanceSongCount: nextChanceSongCount,
      preloadNextSongCount: preloadNextSongCount,
      preferredCountryCode: preferredCountryCode.isEmpty
          ? 'LK'
          : preferredCountryCode,
      ytMusicAuthJson: json['ytMusicAuthJson'] as String?,
    );
  }
}

class LibrarySong {
  LibrarySong({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.folderName,
    required this.folderPath,
    required this.sourceLabel,
    required this.addedAt,
    required this.durationMs,
    this.genre,
    this.year,
    this.trackNumber,
    this.discNumber,
    this.isFavorite = false,
    this.playCount = 0,
    this.lastPlayedAt,
    this.isRemote = false,
    String? artworkUrl,
    this.externalUrl,
    this.isLiked = false,
    this.isDisliked = false,
    this.downloadSourceSongId,
  }) : artworkUrl = normalizeArtworkUrl(
         artworkUrl,
         songId: id,
         path: path,
         isRemote: isRemote,
       );

  final String id;
  final String path;
  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final String folderName;
  final String folderPath;
  final String sourceLabel;
  final DateTime addedAt;
  final int durationMs;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? discNumber;
  final bool isFavorite;
  final int playCount;
  final DateTime? lastPlayedAt;
  final bool isRemote;
  final String? artworkUrl;
  final String? externalUrl;
  final bool isLiked;
  final bool isDisliked;
  final String? downloadSourceSongId;

  Duration get duration => Duration(milliseconds: durationMs.clamp(0, 1 << 31));
  bool get isDownloaded => downloadSourceSongId != null;

  String get subtitle {
    if (artist.trim().isEmpty) {
      return album;
    }
    return '$artist • $album';
  }

  LibrarySong copyWith({
    String? path,
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? folderName,
    String? folderPath,
    String? sourceLabel,
    DateTime? addedAt,
    int? durationMs,
    String? genre,
    int? year,
    int? trackNumber,
    int? discNumber,
    bool? isFavorite,
    int? playCount,
    DateTime? lastPlayedAt,
    bool clearLastPlayedAt = false,
    bool? isRemote,
    String? artworkUrl,
    String? externalUrl,
    bool? isLiked,
    bool? isDisliked,
    Object? downloadSourceSongId = _copyWithSentinel,
  }) {
    return LibrarySong(
      id: id,
      path: path ?? this.path,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumArtist: albumArtist ?? this.albumArtist,
      folderName: folderName ?? this.folderName,
      folderPath: folderPath ?? this.folderPath,
      sourceLabel: sourceLabel ?? this.sourceLabel,
      addedAt: addedAt ?? this.addedAt,
      durationMs: durationMs ?? this.durationMs,
      genre: genre ?? this.genre,
      year: year ?? this.year,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      isFavorite: isFavorite ?? this.isFavorite,
      playCount: playCount ?? this.playCount,
      lastPlayedAt: clearLastPlayedAt
          ? null
          : lastPlayedAt ?? this.lastPlayedAt,
      isRemote: isRemote ?? this.isRemote,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      externalUrl: externalUrl ?? this.externalUrl,
      isLiked: isLiked ?? this.isLiked,
      isDisliked: isDisliked ?? this.isDisliked,
      downloadSourceSongId: identical(downloadSourceSongId, _copyWithSentinel)
          ? this.downloadSourceSongId
          : downloadSourceSongId as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'path': path,
      'title': title,
      'artist': artist,
      'album': album,
      'albumArtist': albumArtist,
      'folderName': folderName,
      'folderPath': folderPath,
      'sourceLabel': sourceLabel,
      'addedAt': addedAt.toIso8601String(),
      'durationMs': durationMs,
      'genre': genre,
      'year': year,
      'trackNumber': trackNumber,
      'discNumber': discNumber,
      'isFavorite': isFavorite,
      'playCount': playCount,
      'lastPlayedAt': lastPlayedAt?.toIso8601String(),
      'isRemote': isRemote,
      'artworkUrl': artworkUrl,
      'externalUrl': externalUrl,
      'isLiked': isLiked,
      'isDisliked': isDisliked,
      'downloadSourceSongId': downloadSourceSongId,
    };
  }

  factory LibrarySong.fromJson(Map<String, dynamic> json) {
    final String album = json['album'] as String? ?? 'Unknown album';
    final String folderName = json['folderName'] as String? ?? 'Library';
    final String sourceLabel = json['sourceLabel'] as String? ?? 'Library';
    return LibrarySong(
      id: json['id'] as String,
      path: json['path'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String? ?? 'Unknown artist',
      album: _neutralRemoteLabel(album),
      albumArtist: json['albumArtist'] as String? ?? 'Unknown artist',
      folderName: _neutralRemoteLabel(folderName),
      folderPath: json['folderPath'] as String? ?? '',
      sourceLabel: _neutralRemoteLabel(sourceLabel),
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      genre: json['genre'] as String?,
      year: (json['year'] as num?)?.toInt(),
      trackNumber: (json['trackNumber'] as num?)?.toInt(),
      discNumber: (json['discNumber'] as num?)?.toInt(),
      isFavorite: json['isFavorite'] as bool? ?? false,
      playCount: (json['playCount'] as num?)?.toInt() ?? 0,
      lastPlayedAt: DateTime.tryParse(json['lastPlayedAt'] as String? ?? ''),
      isRemote: json['isRemote'] as bool? ?? false,
      artworkUrl: json['artworkUrl'] as String?,
      externalUrl: json['externalUrl'] as String?,
      isLiked: json['isLiked'] as bool? ?? false,
      isDisliked: json['isDisliked'] as bool? ?? false,
      downloadSourceSongId: json['downloadSourceSongId'] as String?,
    );
  }
}

const Object _copyWithSentinel = Object();

String _neutralRemoteLabel(String value) {
  final String normalized = value.trim().toLowerCase();
  if (normalized == 'youtube music') {
    return 'Online Music';
  }
  if (normalized == 'youtube') {
    return 'Online Stream';
  }
  return value;
}

class UserPlaylist {
  const UserPlaylist({
    required this.id,
    required this.name,
    required this.songIds,
    required this.createdAt,
    required this.updatedAt,
    this.songCount,
    this.songIdsComplete = true,
    this.lastSyncedAt,
  });

  final String id;
  final String name;
  final List<String> songIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? songCount;
  final bool songIdsComplete;
  final DateTime? lastSyncedAt;

  int get displaySongCount => songCount ?? songIds.length;

  UserPlaylist copyWith({
    String? name,
    List<String>? songIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? songCount,
    bool? songIdsComplete,
    Object? lastSyncedAt = _copyWithSentinel,
  }) {
    return UserPlaylist(
      id: id,
      name: name ?? this.name,
      songIds: songIds ?? this.songIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      songCount: songCount ?? this.songCount,
      songIdsComplete: songIdsComplete ?? this.songIdsComplete,
      lastSyncedAt: lastSyncedAt == _copyWithSentinel
          ? this.lastSyncedAt
          : lastSyncedAt as DateTime?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'songIds': songIds,
      'songCount': displaySongCount,
      'songIdsComplete': songIdsComplete,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    };
  }

  factory UserPlaylist.fromJson(Map<String, dynamic> json) {
    return UserPlaylist(
      id: json['id'] as String,
      name: json['name'] as String,
      songIds: (json['songIds'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic item) => item as String)
          .toList(),
      songCount: (json['songCount'] as num?)?.toInt(),
      songIdsComplete: json['songIdsComplete'] as bool? ?? true,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      lastSyncedAt: DateTime.tryParse(json['lastSyncedAt'] as String? ?? ''),
    );
  }
}

class PlaybackEntry {
  const PlaybackEntry({
    required this.songId,
    required this.playedAt,
    this.completionRatio = 0,
    this.listenedToEnd = false,
  });

  final String songId;
  final DateTime playedAt;
  final double completionRatio;
  final bool listenedToEnd;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'songId': songId,
      'playedAt': playedAt.toIso8601String(),
      'completionRatio': completionRatio,
      'listenedToEnd': listenedToEnd,
    };
  }

  factory PlaybackEntry.fromJson(Map<String, dynamic> json) {
    return PlaybackEntry(
      songId: json['songId'] as String,
      playedAt:
          DateTime.tryParse(json['playedAt'] as String? ?? '') ??
          DateTime.now(),
      completionRatio: (json['completionRatio'] as num?)?.toDouble() ?? 0,
      listenedToEnd: json['listenedToEnd'] as bool? ?? false,
    );
  }
}

class AlbumCollection {
  const AlbumCollection({
    required this.id,
    required this.title,
    required this.artist,
    required this.songs,
  });

  final String id;
  final String title;
  final String artist;
  final List<LibrarySong> songs;

  LibrarySong get leadSong => songs.first;
  int get songCount => songs.length;
  int get totalPlays => songs.fold<int>(
    0,
    (int total, LibrarySong song) => total + song.playCount,
  );
  Duration get totalDuration => songs.fold<Duration>(
    Duration.zero,
    (Duration total, LibrarySong song) => total + song.duration,
  );
}

class ArtistCollection {
  const ArtistCollection({
    required this.id,
    required this.name,
    required this.songs,
  });

  final String id;
  final String name;
  final List<LibrarySong> songs;

  LibrarySong get leadSong => songs.first;
  int get albumCount =>
      songs.map((LibrarySong song) => song.album).toSet().length;
  int get totalPlays => songs.fold<int>(
    0,
    (int total, LibrarySong song) => total + song.playCount,
  );
}

class FolderCollection {
  const FolderCollection({
    required this.id,
    required this.name,
    required this.path,
    required this.songs,
  });

  final String id;
  final String name;
  final String path;
  final List<LibrarySong> songs;

  LibrarySong get leadSong => songs.first;
}

class HomeFeedSection {
  const HomeFeedSection({
    required this.title,
    required this.subtitle,
    required this.query,
    required this.songs,
  });

  final String title;
  final String subtitle;
  final String query;
  final List<LibrarySong> songs;
}

class SongRecommendation {
  const SongRecommendation({
    required this.song,
    required this.reason,
    this.isExploratory = false,
  });

  final LibrarySong song;
  final String reason;
  final bool isExploratory;
}

enum PlaybackStreamTransport {
  localFile('Local file', isHls: false, hasVideo: false, isNetwork: false),
  cachedFile('Cached file', isHls: false, hasVideo: false, isNetwork: false),
  directUrl('Direct URL', isHls: false, hasVideo: false, isNetwork: true),
  audioOnly('Audio only', isHls: false, hasVideo: false, isNetwork: true),
  hlsAudioOnly('HLS audio only', isHls: true, hasVideo: false, isNetwork: true),
  muxed('Muxed', isHls: false, hasVideo: true, isNetwork: true),
  hlsMuxed('HLS muxed', isHls: true, hasVideo: true, isNetwork: true),
  hlsVideoOnly('HLS video only', isHls: true, hasVideo: true, isNetwork: true);

  const PlaybackStreamTransport(
    this.label, {
    required this.isHls,
    required this.hasVideo,
    required this.isNetwork,
  });

  final String label;
  final bool isHls;
  final bool hasVideo;
  final bool isNetwork;
}

class PlaybackStreamInfo {
  const PlaybackStreamInfo({
    required this.songId,
    required this.sourceLabel,
    required this.transport,
    required this.selectionPolicy,
    required this.originalUrl,
    required this.resolvedUrl,
    this.externalUrl,
    this.upstreamTransport,
    this.streamTag,
    this.bitrateBitsPerSecond,
    this.qualityLabel,
    this.containerName,
    this.codecDescription,
    this.audioCodec,
    this.videoCodec,
    this.availableAudioOnlyCount = 0,
    this.availableHlsAudioOnlyCount = 0,
    this.availableMuxedCount = 0,
    this.availableHlsMuxedCount = 0,
    this.availableHlsVideoOnlyCount = 0,
  });

  final String songId;
  final String sourceLabel;
  final PlaybackStreamTransport transport;
  final String selectionPolicy;
  final String originalUrl;
  final String resolvedUrl;
  final String? externalUrl;
  final PlaybackStreamTransport? upstreamTransport;
  final int? streamTag;
  final int? bitrateBitsPerSecond;
  final String? qualityLabel;
  final String? containerName;
  final String? codecDescription;
  final String? audioCodec;
  final String? videoCodec;
  final int availableAudioOnlyCount;
  final int availableHlsAudioOnlyCount;
  final int availableMuxedCount;
  final int availableHlsMuxedCount;
  final int availableHlsVideoOnlyCount;

  double? get bitrateKiloBitsPerSecond {
    final int? value = bitrateBitsPerSecond;
    if (value == null || value <= 0) {
      return null;
    }
    return value / 1024;
  }

  String get bitrateLabel {
    final double? kbps = bitrateKiloBitsPerSecond;
    if (kbps == null) {
      return 'Unknown bitrate';
    }
    if (kbps >= 1024) {
      return '${(kbps / 1024).toStringAsFixed(2)} Mbit/s';
    }
    return '${kbps.toStringAsFixed(2)} Kbit/s';
  }

  String get bitrateTier {
    final int? value = bitrateBitsPerSecond;
    if (value == null || value <= 0) {
      return 'unknown';
    }
    if (value <= 128000) {
      return 'low';
    }
    if (value <= 256000) {
      return 'medium';
    }
    return 'high';
  }

  String get selectionPolicyLabel {
    return switch (selectionPolicy) {
      'muxed-first-streaming' => 'Muxed first streaming',
      'lowest-bitrate-audio-first' => 'Lowest bitrate audio first',
      'windows-muxed-stability-first' => 'Windows stability first',
      'fallback-after-open-failure' => 'Fallback after open failure',
      'cache-hit' => 'Cached playback',
      'local-file' => 'Local file playback',
      'direct-url' => 'Direct URL playback',
      _ => selectionPolicy,
    };
  }

  String get debugSummary {
    final List<String> parts = <String>[
      'source=$sourceLabel',
      'transport=${transport.label}',
      'policy=$selectionPolicy',
      'bitrate=${bitrateBitsPerSecond ?? 0}',
      'tier=$bitrateTier',
      if ((qualityLabel ?? '').trim().isNotEmpty) 'quality=$qualityLabel',
      if ((containerName ?? '').trim().isNotEmpty) 'container=$containerName',
      if ((audioCodec ?? '').trim().isNotEmpty) 'audioCodec=$audioCodec',
      if ((videoCodec ?? '').trim().isNotEmpty) 'videoCodec=$videoCodec',
      if ((codecDescription ?? '').trim().isNotEmpty) 'codec=$codecDescription',
      if (streamTag != null) 'tag=$streamTag',
      if (upstreamTransport != null) 'upstream=${upstreamTransport!.label}',
      'choices[a=$availableAudioOnlyCount,ha=$availableHlsAudioOnlyCount,m=$availableMuxedCount,hm=$availableHlsMuxedCount,hv=$availableHlsVideoOnlyCount]',
    ];
    return parts.join(' ');
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PlaybackStreamInfo &&
            runtimeType == other.runtimeType &&
            songId == other.songId &&
            sourceLabel == other.sourceLabel &&
            transport == other.transport &&
            selectionPolicy == other.selectionPolicy &&
            originalUrl == other.originalUrl &&
            resolvedUrl == other.resolvedUrl &&
            externalUrl == other.externalUrl &&
            upstreamTransport == other.upstreamTransport &&
            streamTag == other.streamTag &&
            bitrateBitsPerSecond == other.bitrateBitsPerSecond &&
            qualityLabel == other.qualityLabel &&
            containerName == other.containerName &&
            codecDescription == other.codecDescription &&
            audioCodec == other.audioCodec &&
            videoCodec == other.videoCodec &&
            availableAudioOnlyCount == other.availableAudioOnlyCount &&
            availableHlsAudioOnlyCount == other.availableHlsAudioOnlyCount &&
            availableMuxedCount == other.availableMuxedCount &&
            availableHlsMuxedCount == other.availableHlsMuxedCount &&
            availableHlsVideoOnlyCount == other.availableHlsVideoOnlyCount;
  }

  @override
  int get hashCode => Object.hash(
    songId,
    sourceLabel,
    transport,
    selectionPolicy,
    originalUrl,
    resolvedUrl,
    externalUrl,
    upstreamTransport,
    streamTag,
    bitrateBitsPerSecond,
    qualityLabel,
    containerName,
    codecDescription,
    audioCodec,
    videoCodec,
    availableAudioOnlyCount,
    availableHlsAudioOnlyCount,
    availableMuxedCount,
    availableHlsMuxedCount,
    availableHlsVideoOnlyCount,
  );
}

String formatDataSize(int bytes) {
  final int sanitized = bytes < 0 ? 0 : bytes;
  if (sanitized < 1024) {
    return '$sanitized B';
  }

  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double value = sanitized / 1024;
  int unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  final bool useWholeNumber = value >= 100 || value % 1 == 0;
  final String formatted = useWholeNumber
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$formatted ${units[unitIndex]}';
}

class AppDataUsageStats {
  const AppDataUsageStats({
    this.totalBytes = 0,
    this.streamBytes = 0,
    this.cacheBytes = 0,
    this.searchBytes = 0,
    this.loadBytes = 0,
    this.artworkBytes = 0,
    this.metadataBytes = 0,
    this.currentSongBytes = 0,
    this.currentCacheBytes = 0,
    this.currentCacheExpectedBytes = 0,
    this.currentSongId,
    this.currentCacheSongId,
    this.lastUpdatedAt,
  });

  final int totalBytes;
  final int streamBytes;
  final int cacheBytes;
  final int searchBytes;
  final int loadBytes;
  final int artworkBytes;
  final int metadataBytes;
  final int currentSongBytes;
  final int currentCacheBytes;
  final int currentCacheExpectedBytes;
  final String? currentSongId;
  final String? currentCacheSongId;
  final DateTime? lastUpdatedAt;

  String get totalLabel => formatDataSize(totalBytes);
  String get streamLabel => formatDataSize(streamBytes);
  String get cacheLabel => formatDataSize(cacheBytes);
  int get otherBytes => searchBytes + loadBytes + artworkBytes + metadataBytes;
  String get otherLabel => formatDataSize(otherBytes);
  String get searchLabel => formatDataSize(searchBytes);
  String get loadLabel => formatDataSize(loadBytes);
  String get artworkLabel => formatDataSize(artworkBytes);
  String get metadataLabel => formatDataSize(metadataBytes);
  String get currentSongLabel => formatDataSize(currentSongBytes);
  String get currentCacheLabel => formatDataSize(currentCacheBytes);
  bool get hasCurrentSongUsage =>
      (currentSongId?.trim().isNotEmpty ?? false) && currentSongBytes > 0;
  bool get hasCurrentCacheUsage =>
      (currentCacheSongId?.trim().isNotEmpty ?? false) &&
      (currentCacheBytes > 0 || currentCacheExpectedBytes > 0);

  AppDataUsageStats copyWith({
    int? totalBytes,
    int? streamBytes,
    int? cacheBytes,
    int? searchBytes,
    int? loadBytes,
    int? artworkBytes,
    int? metadataBytes,
    int? currentSongBytes,
    int? currentCacheBytes,
    int? currentCacheExpectedBytes,
    String? currentSongId,
    String? currentCacheSongId,
    bool clearCurrentSongId = false,
    bool clearCurrentCacheSongId = false,
    DateTime? lastUpdatedAt,
  }) {
    return AppDataUsageStats(
      totalBytes: totalBytes ?? this.totalBytes,
      streamBytes: streamBytes ?? this.streamBytes,
      cacheBytes: cacheBytes ?? this.cacheBytes,
      searchBytes: searchBytes ?? this.searchBytes,
      loadBytes: loadBytes ?? this.loadBytes,
      artworkBytes: artworkBytes ?? this.artworkBytes,
      metadataBytes: metadataBytes ?? this.metadataBytes,
      currentSongBytes: currentSongBytes ?? this.currentSongBytes,
      currentCacheBytes: currentCacheBytes ?? this.currentCacheBytes,
      currentCacheExpectedBytes:
          currentCacheExpectedBytes ?? this.currentCacheExpectedBytes,
      currentSongId: clearCurrentSongId
          ? null
          : currentSongId ?? this.currentSongId,
      currentCacheSongId: clearCurrentCacheSongId
          ? null
          : currentCacheSongId ?? this.currentCacheSongId,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'totalBytes': totalBytes,
      'streamBytes': streamBytes,
      'cacheBytes': cacheBytes,
      'searchBytes': searchBytes,
      'loadBytes': loadBytes,
      'artworkBytes': artworkBytes,
      'metadataBytes': metadataBytes,
      'currentSongBytes': currentSongBytes,
      'currentSongId': currentSongId,
      'currentCacheBytes': currentCacheBytes,
      'currentCacheExpectedBytes': currentCacheExpectedBytes,
      'currentCacheSongId': currentCacheSongId,
      'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
    };
  }

  factory AppDataUsageStats.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const AppDataUsageStats();
    }

    return AppDataUsageStats(
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      streamBytes: (json['streamBytes'] as num?)?.toInt() ?? 0,
      cacheBytes: (json['cacheBytes'] as num?)?.toInt() ?? 0,
      searchBytes: (json['searchBytes'] as num?)?.toInt() ?? 0,
      loadBytes: (json['loadBytes'] as num?)?.toInt() ?? 0,
      artworkBytes: (json['artworkBytes'] as num?)?.toInt() ?? 0,
      metadataBytes: (json['metadataBytes'] as num?)?.toInt() ?? 0,
      currentSongBytes: (json['currentSongBytes'] as num?)?.toInt() ?? 0,
      currentSongId: json['currentSongId'] as String?,
      currentCacheBytes: (json['currentCacheBytes'] as num?)?.toInt() ?? 0,
      currentCacheExpectedBytes:
          (json['currentCacheExpectedBytes'] as num?)?.toInt() ?? 0,
      currentCacheSongId: json['currentCacheSongId'] as String?,
      lastUpdatedAt: DateTime.tryParse(json['lastUpdatedAt'] as String? ?? ''),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AppDataUsageStats &&
            runtimeType == other.runtimeType &&
            totalBytes == other.totalBytes &&
            streamBytes == other.streamBytes &&
            cacheBytes == other.cacheBytes &&
            searchBytes == other.searchBytes &&
            loadBytes == other.loadBytes &&
            artworkBytes == other.artworkBytes &&
            metadataBytes == other.metadataBytes &&
            currentSongBytes == other.currentSongBytes &&
            currentCacheBytes == other.currentCacheBytes &&
            currentCacheExpectedBytes == other.currentCacheExpectedBytes &&
            currentSongId == other.currentSongId &&
            currentCacheSongId == other.currentCacheSongId &&
            lastUpdatedAt == other.lastUpdatedAt;
  }

  @override
  int get hashCode => Object.hash(
    totalBytes,
    streamBytes,
    cacheBytes,
    searchBytes,
    loadBytes,
    artworkBytes,
    metadataBytes,
    currentSongBytes,
    currentCacheBytes,
    currentCacheExpectedBytes,
    currentSongId,
    currentCacheSongId,
    lastUpdatedAt,
  );
}

class NowPlayingState {
  const NowPlayingState({
    this.song,
    this.isLoading = false,
    this.isShuffleEnabled = false,
    this.repeatMode = PlaylistMode.none,
    this.queueIndex = 0,
    this.queueLength = 0,
    this.streamInfo,
  });

  final LibrarySong? song;
  final bool isLoading;
  final bool isShuffleEnabled;
  final PlaylistMode repeatMode;
  final int queueIndex;
  final int queueLength;
  final PlaybackStreamInfo? streamInfo;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is NowPlayingState &&
            runtimeType == other.runtimeType &&
            song == other.song &&
            isLoading == other.isLoading &&
            isShuffleEnabled == other.isShuffleEnabled &&
            repeatMode == other.repeatMode &&
            queueIndex == other.queueIndex &&
            queueLength == other.queueLength &&
            streamInfo == other.streamInfo;
  }

  @override
  int get hashCode => Object.hash(
    song,
    isLoading,
    isShuffleEnabled,
    repeatMode,
    queueIndex,
    queueLength,
    streamInfo,
  );
}

class PlaybackProgressState {
  const PlaybackProgressState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  final bool isPlaying;
  final Duration position;
  final Duration duration;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PlaybackProgressState &&
            runtimeType == other.runtimeType &&
            isPlaying == other.isPlaying &&
            position == other.position &&
            duration == other.duration;
  }

  @override
  int get hashCode => Object.hash(isPlaying, position, duration);
}
