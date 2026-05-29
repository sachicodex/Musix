import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Playlist;
import 'package:ytmusicapi_dart/auth/browser.dart' as ytm_browser;
import 'package:ytmusicapi_dart/ytmusicapi_dart.dart';
import 'package:ytmusicapi_dart/enums.dart' as ytm;

import '../services/firestore_user_data_service.dart';
import 'android_media_notification_bridge.dart';
import 'app_logger.dart';
import 'controller/musix_domain_state.dart';
import 'controller/musix_notify_scheduler.dart';
import 'library_scan.dart';
import 'models.dart';
import 'playback_proxy.dart';
import 'snapshot_codec.dart';
import 'streaming.dart';
import 'windows_media_controls_bridge.dart';

enum _AppNetworkUsageBucket { search, load, metadata }

class MusixController extends ChangeNotifier with WidgetsBindingObserver {
  MusixController({FirestoreUserDataService? firestoreUserDataService})
    : _yt = YoutubeExplode(),
      _firestoreUserDataService = firestoreUserDataService {
    WidgetsBinding.instance.addObserver(this);
    _notifyScheduler = MusixNotifyScheduler(_flushBatchedNotify);
  }

  final MusixHomeState home = MusixHomeState();
  final MusixLibraryState library = MusixLibraryState();
  final MusixSearchState search = MusixSearchState();
  final MusixConnectivityState connectivity = MusixConnectivityState();
  final MusixAppSettingsState appSettings = MusixAppSettingsState();
  final MusixQueueState queue = MusixQueueState();

  late final MusixNotifyScheduler _notifyScheduler;
  int _homeStateRevision = 0;
  int _settingsStateRevision = 0;
  static const int _smartQueueBatchSize = 15;
  static const int _recommendationProfileVersion = 3;
  static const int _cloudSongHydrationBatchSize = 20;
  static const Duration _cloudSongHydrationBatchDelay = Duration(
    milliseconds: 120,
  );
  static const Duration _minBrowsableSongDuration = Duration(seconds: 30);
  static const Duration _minLocalSongDuration = Duration(seconds: 90);
  static const Duration _maxBrowsableSongDuration = Duration(minutes: 10);
  static const Duration _maxHomeAndSmartQueueSongDuration = Duration(
    minutes: 6,
  );
  static const Duration _playbackActivationMinimumLoading = Duration(
    seconds: 1,
  );
  static const Duration _playbackActivationForcedStableDuration = Duration(
    seconds: 2,
  );
  static const double _minimumProfileLanguageConfidence = 0.58;
  static const double _strictLanguageGateConfidence = 0.68;
  static const double _likedArtistRankMultiplier = 1.75;
  static const double _dislikedArtistRankMultiplier = 0.25;
  static const List<String> supportedExtensions = <String>[
    'mp3',
    'flac',
    'ogg',
    'wav',
    'm4a',
    'aac',
    'opus',
    'wma',
    'aiff',
    'alac',
  ];

  Player? _playerInstance;
  bool _playerBound = false;
  final List<_StandbyPreloadSlot> _standbyPreloads = <_StandbyPreloadSlot>[];
  int _standbyPreloadRevision = 0;
  bool _standbyPreloadRefreshInFlight = false;
  Timer? _standbyPreloadRetryTimer;
  DateTime? _youtubeRequestBackoffUntil;
  final YoutubeExplode _yt;
  final FirestoreUserDataService? _firestoreUserDataService;
  late final PlaybackProxyServer _playbackProxy = PlaybackProxyServer(
    onBytesTransferred: _handlePlaybackProxyTransfer,
    onCacheProgress: _handlePlaybackProxyCacheProgress,
    onCacheCompleted: _handlePlaybackProxyCacheCompleted,
  );
  final Connectivity _connectivity = Connectivity();
  final ValueNotifier<NowPlayingState> nowPlayingState =
      ValueNotifier<NowPlayingState>(const NowPlayingState());
  final ValueNotifier<PlaybackProgressState> playbackProgressState =
      ValueNotifier<PlaybackProgressState>(const PlaybackProgressState());
  final ValueNotifier<AppDataUsageStats> dataUsageState =
      ValueNotifier<AppDataUsageStats>(const AppDataUsageStats());
  StreamSubscription<String>? _notificationActionSubscription;
  StreamSubscription<String>? _windowsMediaActionSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<FirestoreUserData>? _cloudUserDataSubscription;
  Future<void>? _cloudUserDataLoadFuture;
  Timer? _cloudPreferenceProfileSyncTimer;
  Timer? _sleepTimer;
  YTMusic? _ytMusic;
  final Uuid _uuid = const Uuid();
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  final Map<String, LibrarySong> _transientSongsById = <String, LibrarySong>{};
  final Set<String> _cloudLikedSongIds = <String>{};
  final Set<String> _cloudDislikedSongIds = <String>{};
  CloudPreferenceProfile _cloudPreferenceProfile =
      const CloudPreferenceProfile.empty();
  List<ArtistCollection> _topArtistsCache = const <ArtistCollection>[];
  final Set<String> _cloudSongHydrationInFlight = <String>{};
  final Map<String, Future<void>> _cloudPlaylistSongLoadFutures =
      <String, Future<void>>{};
  final Map<String, String> _preparedMediaUrlsBySongId = <String, String>{};
  final Map<String, Map<String, String>?> _preparedMediaHeadersBySongId =
      <String, Map<String, String>?>{};
  final Map<String, List<PlaybackStreamCandidate>>
  _rankedPlaybackCandidatesBySongId = <String, List<PlaybackStreamCandidate>>{};
  final Map<String, PlaybackStreamInfo> _playbackStreamInfoBySongId =
      <String, PlaybackStreamInfo>{};
  final Map<String, int> _playbackCandidateIndexBySongId = <String, int>{};
  final Map<String, int> _songPlaybackBytes = <String, int>{};
  final Map<String, _ActivePlaybackProxy> _activePlaybackProxiesBySongId =
      <String, _ActivePlaybackProxy>{};
  final Set<String> _playbackProxyBypassSongIds = <String>{};

  /// Songs whose proxy playback session was removed (e.g. during fallback
  /// recovery) but whose upstream download is still writing the cache file.
  /// Once the file is complete, [_handlePlaybackProxyCacheCompleted] removes
  /// the id from this set.
  final Set<String> _proxyCachingOnlySongIds = <String>{};
  bool _isDisposing = false;
  bool _isDisposed = false;

  bool _initialized = false;
  bool _startupContinuationScheduled = false;
  bool _scanning = false;
  bool _onlineLoading = false;
  bool _trendingNowLoading = false;
  bool _homeLoading = false;
  bool _homeRefreshResolvedOnce = false;
  bool _homeStartupRefreshConsumed = false;
  bool _smartQueueLoading = false;
  bool _smartQueueRefillQueued = false;
  bool _isOffline = false;
  bool _startupOfflineMode = false;
  String? _statusMessage;
  String? _errorMessage;
  String? _cloudSyncMessage;
  String? _connectivityMessage;
  String? _onlineError;
  String? _trendingNowError;
  String? _homeError;
  String? _ytMusicAuthError;
  String _onlineQuery = '';
  int _onlineResultLimit = 0;
  bool _onlineHasMore = false;
  int _onlineSearchRequestId = 0;
  int _trendingNowRequestId = 0;

  AppSettings _settings = const AppSettings();
  List<String> _sources = <String>[];
  List<String> _autoSources = <String>[];
  List<LibrarySong> _songs = <LibrarySong>[];
  List<UserPlaylist> _playlists = <UserPlaylist>[];
  List<PlaybackEntry> _history = <PlaybackEntry>[];
  List<LibrarySong> _onlineResults = <LibrarySong>[];
  List<LibrarySong> _trendingNowSongs = <LibrarySong>[];
  String _trendingNowRegionLabel = 'Your region';
  List<HomeFeedSection> _homeFeed = <HomeFeedSection>[];
  List<SongRecommendation> _personalizedHomeRecommendations =
      <SongRecommendation>[];
  int _homeQueryCursor = 0;
  final Set<String> _homeConsumedIdentityKeys = <String>{};
  final Set<String> _homeConsumedIds = <String>{};
  final Map<String, List<LibrarySong>> _searchCache =
      <String, List<LibrarySong>>{};
  final Map<String, List<LibrarySong>> _ytMusicSearchCache =
      <String, List<LibrarySong>>{};
  final Map<String, String?> _ytMusicVideoIdCache = <String, String?>{};
  final Map<String, String?> _ytMusicArtistImageCache = <String, String?>{};
  final Map<String, ArtistCollection?> _ytMusicArtistCollectionCache =
      <String, ArtistCollection?>{};
  final Map<String, _OnlineArtistCollectionSession>
  _ytMusicArtistCollectionSessionCache =
      <String, _OnlineArtistCollectionSession>{};
  final Set<String> _smartQueueSongIds = <String>{};
  final Map<String, String> _offlinePlaybackCachePaths = <String, String>{};
  final Map<String, int> _offlinePlaybackCacheSizesBySongId = <String, int>{};
  final Map<String, int> _offlinePlaybackCacheProgressBytesBySongId =
      <String, int>{};
  final Map<String, int> _offlinePlaybackCacheExpectedBytesBySongId =
      <String, int>{};
  final Set<String> _offlinePlaybackPrefetchInFlight = <String>{};
  final Set<String> _offlinePlaybackCacheFailedSongIds = <String>{};
  final Map<String, List<Completer<bool>>> _offlinePlaybackCacheWaiters =
      <String, List<Completer<bool>>>{};
  final Set<String> _completedPlaybackSaveEligibleSongIds = <String>{};
  final Map<String, String> _pendingCompletedPlaybackCachePaths =
      <String, String>{};
  String? _activePlaybackSongId;
  double _activePlaybackCompletionRatio = 0;
  bool _pauseRequestedByUser = false;
  bool _suppressAutoAdvanceOnNextStop = false;
  DateTime? _lastAutoHomeRefreshAt;
  AppDataUsageStats _dataUsage = const AppDataUsageStats();
  Timer? _dataUsageSnapshotTimer;
  Timer? _playbackActivationTimer;
  bool _playbackFallbackRecoveryInFlight = false;
  String? _playbackFallbackRecoverySongId;
  int? _playbackFallbackRecoveryIndex;
  bool _playbackRecoveryQueueLocked = false;
  String? _playbackActivationSongId;
  DateTime? _playbackActivationStartedAt;
  final int _offlinePlaybackCacheEpoch = 0;
  bool _offlineQueueAdvancePending = false;
  bool _queueNavigationInFlight = false;
  int _sleepTimerMinutes = 0;
  DateTime? _sleepTimerEndAt;
  DateTime? _lastSleepTimerActivityAt;
  Duration? _sleepTimerRemainingDuration;
  bool _sleepTimerStopInFlight = false;
  String? _offlineQueueActivationTargetSongId;
  int? _offlineQueueActivationTargetIndex;
  List<String>? _offlineQueueActivationSongIds;
  String? _offlineQueueWaitingSongId;
  int? _offlineQueueWaitingIndex;
  bool _offlineQueueWaitingShouldResume = false;
  bool _offlineDetachedQueueMode = false;
  String? _activeCloudUserId;
  DateTime? _cloudLibraryRevision;
  bool _cloudUserDataLoaded = false;
  bool _snapshotLoaded = false;
  final Set<String> _downloadingSongIds = <String>{};

  int _libraryDataRevision = 0;
  int _derivedLibraryRevision = -1;
  Map<String, LibrarySong> _songLookupCache = <String, LibrarySong>{};
  List<LibrarySong> _browsableSongsCache = const <LibrarySong>[];
  List<LibrarySong> _downloadedSongs = <LibrarySong>[];
  List<LibrarySong> _downloadedSongsCache = const <LibrarySong>[];
  List<LibrarySong> _likedSongsCache = const <LibrarySong>[];
  List<LibrarySong> _dislikedSongsCache = const <LibrarySong>[];
  Map<String, List<LibrarySong>> _playlistSongsCache =
      <String, List<LibrarySong>>{};

  List<String> _queueSongIds = <String>[];
  List<String> _detachedSequentialQueueSongIds = <String>[];
  String _queueLabel = 'Now Playing';
  int _queueIndex = 0;
  bool _isPlaying = false;
  bool _isShuffleEnabled = false;
  PlaylistMode _repeatMode = PlaylistMode.none;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  LibrarySong? _pendingSelectionSong;
  String? _startupMiniPlayerSongId;
  String? _transitioningSongId;
  int? _transitioningQueueIndex;
  int _playbackSelectionRevision = 0;
  bool _hasPublishedPlaybackNotification = false;
  String _searchDraft = '';
  List<String> _recentSearchTerms = <String>[];

  String? _lastTrackedSongId;

  Player get _player {
    final Player player = _playerInstance ??= Player();
    if (!_playerBound) {
      _bindPrimaryPlayer(player);
    }
    return player;
  }

  bool get initialized => _initialized;
  bool get scanning => _scanning;
  bool get onlineLoading => _onlineLoading;
  bool get trendingNowLoading => _trendingNowLoading;
  bool get homeLoading => _homeLoading;
  bool get homeRefreshResolvedOnce => _homeRefreshResolvedOnce;
  bool get smartQueueLoading => _smartQueueLoading;
  bool get isOffline => _isOffline;
  bool get isOfflineViewActive => _startupOfflineMode || offlineMusicMode;
  bool get offlineMusicMode => _settings.offlineMusicMode;
  bool get offlinePlaybackCacheEnabled => false;
  int get offlinePlaybackCacheSongCount => 0;
  int get nextChanceSongCount => _settings.nextChanceSongCount;
  int get preloadNextSongCount => _settings.preloadNextSongCount;
  int get sleepTimerMinutes => _sleepTimerMinutes;
  bool get sleepTimerEnabled => sleepTimerMinutes > 0;
  AppDataUsageStats get dataUsage => dataUsageState.value;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  String? get cloudSyncMessage => _cloudSyncMessage;
  String? get connectivityMessage => _connectivityMessage;
  String? get onlineError => _onlineError;
  String? get trendingNowError => _trendingNowError;
  String? get homeError => _homeError;
  String? get ytMusicAuthError => _ytMusicAuthError;
  bool get onlineHasMore => _onlineHasMore;
  String get onlineQuery => _onlineQuery;
  AppSettings get settings => _settings;
  Player get player => _player;
  bool get isPlaying => _isPlaying;
  bool get isShuffleEnabled => _isShuffleEnabled;
  PlaylistMode get repeatMode => _repeatMode;
  Duration get position => _position;
  Duration get duration => _duration;
  List<String> get sources => List<String>.unmodifiable(_sources);
  List<LibrarySong> get songs => List<LibrarySong>.unmodifiable(_songs);
  List<LibrarySong> get browsableSongs {
    _ensureDerivedLibraryData();
    return List<LibrarySong>.unmodifiable(_browsableSongsCache);
  }

  List<LibrarySong> get onlineResults =>
      List<LibrarySong>.unmodifiable(_onlineResults);
  List<LibrarySong> get trendingNowSongs => List<LibrarySong>.unmodifiable(
    _filterSongsForBrowsing(_trendingNowSongs),
  );
  String get trendingNowRegionLabel => _trendingNowRegionLabel;
  List<AppRegion> get availableRegions =>
      List<AppRegion>.unmodifiable(kAppRegions);
  String get preferredCountryCode =>
      _normalizeCountryCode(_settings.preferredCountryCode);
  String get preferredRegionLabel =>
      _regionLabelFromCountryCode(preferredCountryCode);
  Duration? get sleepTimerRemaining {
    if (!sleepTimerEnabled) {
      return null;
    }
    final DateTime? endAt = _sleepTimerEndAt;
    if (endAt != null) {
      final Duration remaining = endAt.difference(DateTime.now());
      if (remaining.isNegative) {
        return Duration.zero;
      }
      return remaining;
    }
    return _sleepTimerRemainingDuration ?? Duration(minutes: sleepTimerMinutes);
  }

  String get sleepTimerSelectionLabel =>
      _sleepTimerOptionLabel(sleepTimerMinutes);

  String get sleepTimerStatusLabel {
    if (!sleepTimerEnabled) {
      return 'Off';
    }
    if (!_isPlaying && _sleepTimerEndAt == null) {
      return '${_sleepTimerOptionLabel(sleepTimerMinutes)} on play';
    }
    final Duration remaining =
        sleepTimerRemaining ?? Duration(minutes: sleepTimerMinutes);
    return _formatSleepTimerRemaining(remaining);
  }

  List<HomeFeedSection> get homeFeed =>
      List<HomeFeedSection>.unmodifiable(_homeFeed);
  List<SongRecommendation> get personalizedHomeRecommendations =>
      List<SongRecommendation>.unmodifiable(_personalizedHomeRecommendations);
  List<LibrarySong> get personalizedHomeSongs =>
      _personalizedHomeRecommendations
          .map((SongRecommendation item) => item.song)
          .toList(growable: false);
  List<LibrarySong> get cachedSongs {
    return const <LibrarySong>[];
  }

  List<LibrarySong> get downloadedSongs {
    _ensureDerivedLibraryData();
    return List<LibrarySong>.unmodifiable(_downloadedSongsCache);
  }

  bool get hasDownloads => downloadedSongs.isNotEmpty;

  List<UserPlaylist> get playlists =>
      List<UserPlaylist>.unmodifiable(_playlists);
  bool get cloudLibraryLoading =>
      _cloudUserDataLoadFuture != null && !_cloudUserDataLoaded;
  bool isPlaylistSongsLoading(String playlistId) =>
      _cloudPlaylistSongLoadFutures.containsKey(playlistId);
  List<PlaybackEntry> get history => List<PlaybackEntry>.unmodifiable(
    _history.where(
      (PlaybackEntry entry) => _shouldUseSongIdForHistorySignals(entry.songId),
    ),
  );
  String get searchDraft => _searchDraft;
  List<String> get recentSearchTerms =>
      List<String>.unmodifiable(_recentSearchTerms);
  String get queueLabel => _queueLabel;
  int get queueIndex => _queueIndex;
  int get visibleQueueIndex {
    final int? waitingIndex = _offlineQueueWaitingIndex;
    if (waitingIndex != null &&
        waitingIndex >= 0 &&
        waitingIndex < _queueSongIds.length) {
      return waitingIndex;
    }
    final int? transitioningIndex = _transitioningQueueIndex;
    if (transitioningIndex != null &&
        transitioningIndex >= 0 &&
        transitioningIndex < _queueSongIds.length) {
      return transitioningIndex;
    }
    return _queueIndex;
  }

  bool get hasHomeRecommendations =>
      _homeFeed.isNotEmpty || _personalizedHomeRecommendations.isNotEmpty;
  bool get hasYtMusicAuth =>
      (_settings.ytMusicAuthJson?.trim().isNotEmpty ?? false);
  PlaybackStreamInfo? get currentPlaybackStreamInfo {
    final String? songId = miniPlayerSong?.id;
    if (songId == null) {
      return null;
    }
    return _playbackStreamInfoBySongId[songId];
  }

  List<LibrarySong> get queueSongs => _queueSongIds
      .map(songById)
      .whereType<LibrarySong>()
      .toList(growable: false);

  String? takeCloudSyncMessage() {
    final String? message = _cloudSyncMessage;
    _cloudSyncMessage = null;
    return message;
  }

  String? takeConnectivityMessage() {
    final String? message = _connectivityMessage;
    _connectivityMessage = null;
    return message;
  }

  List<String> get _playerQueueSongIds {
    final Player? player = _playerInstance;
    if (player == null) {
      return const <String>[];
    }
    return player.state.playlist.medias
        .map((Media media) => media.extras?['songId'] as String?)
        .whereType<String>()
        .toList(growable: false);
  }

  LibrarySong? get currentSong {
    if (_queueSongIds.isEmpty ||
        _queueIndex < 0 ||
        _queueIndex >= _queueSongIds.length) {
      return null;
    }
    return songById(_queueSongIds[_queueIndex]);
  }

  LibrarySong? get miniPlayerSong {
    final String? waitingSongId = _offlineQueueWaitingSongId;
    if (waitingSongId != null) {
      return songById(waitingSongId) ?? _pendingSelectionSong ?? currentSong;
    }
    final String? transitioningSongId = _transitioningSongId;
    if (transitioningSongId != null) {
      return songById(transitioningSongId) ??
          _pendingSelectionSong ??
          currentSong;
    }
    return _pendingSelectionSong ?? currentSong ?? _startupMiniPlayerSong;
  }

  LibrarySong? get startupSuggestionSong => _startupMiniPlayerSong;

  LibrarySong? get _startupMiniPlayerSong {
    final LibrarySong? lastPlayedSong = recentlyPlayedSongs.firstOrNull;
    if (lastPlayedSong != null) {
      _startupMiniPlayerSongId = lastPlayedSong.id;
      return lastPlayedSong;
    }

    final String? cachedSongId = _startupMiniPlayerSongId;
    if (cachedSongId != null) {
      final LibrarySong? cachedSong = songById(cachedSongId);
      if (cachedSong != null &&
          cachedSong.isRemote &&
          shouldShowSongOutsideSearch(cachedSong)) {
        return cachedSong;
      }
    }

    final List<LibrarySong> remoteSongs = <LibrarySong>[
      ..._songs.where(
        (LibrarySong song) =>
            song.isRemote && shouldShowSongOutsideSearch(song),
      ),
      ..._transientSongsById.values.where(
        (LibrarySong song) =>
            song.isRemote && shouldShowSongOutsideSearch(song),
      ),
    ];
    if (remoteSongs.isEmpty) {
      _startupMiniPlayerSongId = null;
      return null;
    }

    final LibrarySong randomSong =
        remoteSongs[math.Random().nextInt(remoteSongs.length)];
    _startupMiniPlayerSongId = randomSong.id;
    return randomSong;
  }

  bool get supportsLocalFileImport => !kIsWeb && Platform.isWindows;

  bool shouldShowLocalFile(LibrarySong song) {
    if (song.isDisliked || song.isRemote) {
      return false;
    }
    final int durationMs = song.durationMs;
    if (durationMs <= 0) {
      return false;
    }
    return durationMs >= _minLocalSongDuration.inMilliseconds;
  }

  bool shouldShowSongOutsideSearch(LibrarySong song) {
    if (song.isDisliked) {
      return false;
    }
    if (!song.isRemote) {
      return shouldShowLocalFile(song);
    }
    final int durationMs = song.durationMs;
    if (durationMs <= 0) {
      return true;
    }
    return durationMs >= _minBrowsableSongDuration.inMilliseconds &&
        durationMs <= _maxBrowsableSongDuration.inMilliseconds;
  }

  bool shouldShowSongOnHome(LibrarySong song) {
    if (!shouldShowSongOutsideSearch(song)) {
      return false;
    }
    if (!_isShortEnoughForHomeAndSmartQueue(song)) {
      return false;
    }
    if (_isSongExplicitlyDisliked(song)) {
      return false;
    }
    return !(song.isRemote &&
        (song.sourceLabel == 'Online Stream' || song.sourceLabel == 'YouTube'));
  }

  bool _shouldCacheSongForOfflinePlayback(LibrarySong song) {
    return song.isRemote &&
        shouldShowSongOutsideSearch(song) &&
        !_offlinePlaybackCacheFailedSongIds.contains(song.id);
  }

  List<LibrarySong> _filterSongsForBrowsing(Iterable<LibrarySong> songs) {
    return songs.where(shouldShowSongOutsideSearch).toList(growable: false);
  }

  bool _isShortEnoughForHomeAndSmartQueue(LibrarySong song) {
    final int durationMs = song.durationMs;
    if (durationMs <= 0) {
      return true;
    }
    return durationMs <= _maxHomeAndSmartQueueSongDuration.inMilliseconds;
  }

  bool _shouldUseSongInHomeOrSmartQueue(LibrarySong song) {
    return shouldShowSongOutsideSearch(song) &&
        _isShortEnoughForHomeAndSmartQueue(song) &&
        !_isSongExplicitlyDisliked(song);
  }

  List<HomeFeedSection> _filterHomeFeedSectionsForBrowsing(
    Iterable<HomeFeedSection> sections,
  ) {
    final List<HomeFeedSection> result = <HomeFeedSection>[];
    for (final HomeFeedSection section in sections) {
      final List<LibrarySong> songs = section.songs
          .where(shouldShowSongOnHome)
          .toList(growable: false);
      if (songs.isEmpty) {
        continue;
      }
      result.add(
        HomeFeedSection(
          title: section.title,
          subtitle: section.subtitle,
          query: section.query,
          songs: songs,
        ),
      );
    }
    return result;
  }

  bool _isSongExplicitlyDisliked(LibrarySong song) {
    if (song.isDisliked || _cloudDislikedSongIds.contains(song.id)) {
      return true;
    }
    final String identityKey = _songIdentityKey(song);
    return _decisionDislikedSongs.any(
      (LibrarySong dislikedSong) =>
          _songIdentityKey(dislikedSong) == identityKey,
    );
  }

  void _dropRestrictedDurationOfflinePlaybackCacheEntry(String songId) {
    final LibrarySong? song = songById(songId);
    if (song == null || shouldShowSongOutsideSearch(song)) {
      return;
    }
    final String? path = _offlinePlaybackCachePaths[songId];
    _dropOfflinePlaybackCacheEntry(songId);
    if (path != null && path.trim().isNotEmpty) {
      unawaited(_deleteFileIfExists(path));
    }
  }

  void _purgeRestrictedDurationOfflinePlaybackCacheEntries() {
    for (final String songId in _offlinePlaybackCachePaths.keys.toList()) {
      _dropRestrictedDurationOfflinePlaybackCacheEntry(songId);
    }
  }

  bool get miniPlayerSelectionLoading {
    if (_playbackActivationSongId != null) {
      return true;
    }
    final String? waitingSongId = _offlineQueueWaitingSongId;
    if (waitingSongId != null) {
      return true;
    }
    final LibrarySong? active = currentSong;
    final String? transitioningSongId = _transitioningSongId;
    if (transitioningSongId != null &&
        (active == null || active.id != transitioningSongId)) {
      return true;
    }
    final LibrarySong? pending = _pendingSelectionSong;
    if (pending == null) {
      return false;
    }
    return active == null || active.id != pending.id;
  }

  bool _playerQueueHasControllerPlaylist() {
    if (_queueSongIds.isEmpty) {
      return false;
    }
    final List<String> playerQueueSongIds = _playerQueueSongIds;
    if (playerQueueSongIds.length != _queueSongIds.length) {
      return false;
    }
    for (int i = 0; i < _queueSongIds.length; i += 1) {
      if (playerQueueSongIds[i] != _queueSongIds[i]) {
        return false;
      }
    }
    return true;
  }

  bool _playerQueueMatchesControllerState() {
    if (!_playerQueueHasControllerPlaylist() ||
        _queueIndex < 0 ||
        _queueIndex >= _queueSongIds.length) {
      return false;
    }
    final List<String> playerQueueSongIds = _playerQueueSongIds;
    final int playerIndex = _player.state.playlist.index;
    return playerIndex >= 0 &&
        playerIndex < playerQueueSongIds.length &&
        playerQueueSongIds[playerIndex] == _queueSongIds[_queueIndex];
  }

  int? _activePlayerQueueIndex() {
    final List<String> playerQueueSongIds = _playerQueueSongIds;
    final int playerIndex = _player.state.playlist.index;
    if (playerIndex < 0 || playerIndex >= playerQueueSongIds.length) {
      return null;
    }
    return playerIndex;
  }

  bool _syncControllerQueueIndexToPlayer({bool notify = false}) {
    if (_offlineDetachedQueueMode ||
        _offlineQueueWaitingSongId != null ||
        _offlineQueueActivationTargetSongId != null) {
      return false;
    }
    if (!_playerQueueHasControllerPlaylist()) {
      return false;
    }
    final int? playerIndex = _activePlayerQueueIndex();
    if (playerIndex == null || playerIndex == _queueIndex) {
      return false;
    }
    _debugPlayback(
      'player.queue sync immediate queueIndex=$_queueIndex -> $playerIndex',
    );
    _queueIndex = playerIndex;
    if (notify) {
      notifyListeners();
    }
    return true;
  }

  bool _playerHasLoadedCurrentSong(LibrarySong? song) {
    if (song == null) {
      return false;
    }
    final int? playerIndex = _activePlayerQueueIndex();
    if (playerIndex == null) {
      return false;
    }
    final List<String> playerQueueSongIds = _playerQueueSongIds;
    return playerQueueSongIds[playerIndex] == song.id;
  }

  bool _songHasImmediatePlaybackSource(LibrarySong song) {
    if (!songNeedsResolvedPlaybackUrl(song)) {
      return true;
    }
    if (_offlinePlaybackCachePathForSong(song.id) != null) {
      return true;
    }
    final String? prepared = _preparedMediaUrlsBySongId[song.id];
    return prepared != null && prepared.isNotEmpty && prepared != song.path;
  }

  bool _queueRequiresDetachedSequentialPlayback(Iterable<LibrarySong> songs) {
    return songs.any(songNeedsResolvedPlaybackUrl);
  }

  Future<void> _primeStartupMiniPlayerPlayback() async {
    final LibrarySong? song = currentSong;
    if (song == null || !_songHasImmediatePlaybackSource(song)) {
      return;
    }
    // Android should stay network-idle until explicit user playback intent.
    // This avoids resolving remote stream manifests during app startup.
    if (Platform.isAndroid &&
        songNeedsResolvedPlaybackUrl(song) &&
        _offlinePlaybackCachePathForSong(song.id) == null) {
      return;
    }
    try {
      await _preparePlayableSong(song);
      if (!_isDisposed && !_isDisposing) {
        notifyListeners();
      }
    } catch (error) {
      _debugPlayback(
        'startup.prime skipped song=${_debugSongLabel(song)} error=$error',
      );
    }
  }

  Future<bool> _resumeMiniPlayerPlaybackFallback() async {
    final LibrarySong? song = miniPlayerSong;
    if (song == null) {
      return false;
    }
    final String trimmedQueueLabel = _queueLabel.trim();
    final String label =
        trimmedQueueLabel.isEmpty || trimmedQueueLabel == 'Now Playing'
        ? 'Jump back in'
        : trimmedQueueLabel;
    final List<LibrarySong> restoredQueue = queueSongs;
    final int restoredIndex = restoredQueue.indexWhere(
      (LibrarySong queuedSong) => queuedSong.id == song.id,
    );
    if (restoredIndex >= 0) {
      await playSongs(restoredQueue, startIndex: restoredIndex, label: label);
      return true;
    }
    await playSong(song, label: label);
    return true;
  }

  NowPlayingState _buildNowPlayingState() {
    final LibrarySong? song = miniPlayerSong;
    return NowPlayingState(
      song: song,
      isLoading: miniPlayerSelectionLoading,
      isShuffleEnabled: _isShuffleEnabled,
      repeatMode: _repeatMode,
      queueIndex: visibleQueueIndex,
      queueLength: _queueSongIds.length,
      streamInfo: song == null ? null : _playbackStreamInfoBySongId[song.id],
    );
  }

  PlaybackProgressState _buildPlaybackProgressState() {
    return PlaybackProgressState(
      isPlaying: _isPlaying,
      position: _position,
      duration: _duration,
    );
  }

  void _syncPlaybackNotifiers() {
    if (_isDisposed) {
      return;
    }
    final NowPlayingState nextNowPlaying = _buildNowPlayingState();
    if (nowPlayingState.value != nextNowPlaying) {
      nowPlayingState.value = nextNowPlaying;
    }
    final PlaybackProgressState nextProgress = _buildPlaybackProgressState();
    if (playbackProgressState.value != nextProgress) {
      playbackProgressState.value = nextProgress;
    }
  }

  void _syncDataUsageState() {
    if (dataUsageState.value != const AppDataUsageStats()) {
      dataUsageState.value = const AppDataUsageStats();
    }
  }

  void _recordStreamBytes(String songId, int bytes) {
    return;
  }

  void _beginPlaybackActivation(
    LibrarySong? song, {
    bool resetMetrics = false,
    bool notify = true,
  }) {
    if (song == null) {
      return;
    }
    _playbackActivationSongId = song.id;
    _playbackActivationStartedAt = DateTime.now();
    _schedulePlaybackActivationCheck();
    if (resetMetrics) {
      _position = Duration.zero;
      _duration = Duration.zero;
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _clearPlaybackActivation({bool notify = false}) {
    if (_playbackActivationSongId == null &&
        _playbackActivationStartedAt == null &&
        _playbackActivationTimer == null) {
      return;
    }
    _playbackActivationTimer?.cancel();
    _playbackActivationTimer = null;
    _playbackActivationSongId = null;
    _playbackActivationStartedAt = null;
    if (notify) {
      notifyListeners();
    }
  }

  void _maybeResolvePlaybackActivation({bool notify = false}) {
    final String? targetSongId = _playbackActivationSongId;
    if (targetSongId == null) {
      return;
    }
    if (!_hasPlaybackActivationMinimumElapsed()) {
      _schedulePlaybackActivationCheck();
      return;
    }
    if (!_isPlaybackActivationStable(targetSongId)) {
      _schedulePlaybackActivationCheck();
      return;
    }
    _clearPlaybackActivation(notify: notify);
  }

  Duration _playbackActivationElapsed() {
    final DateTime? startedAt = _playbackActivationStartedAt;
    if (startedAt == null) {
      return Duration.zero;
    }
    return DateTime.now().difference(startedAt);
  }

  bool _hasPlaybackActivationMinimumElapsed() {
    return _playbackActivationElapsed() >= _playbackActivationMinimumLoading;
  }

  bool _hasPlaybackActivationForcedStableElapsed() {
    return _playbackActivationElapsed() >=
        _playbackActivationForcedStableDuration;
  }

  bool _isPlaybackActivationStable(String targetSongId) {
    if (_playbackFallbackRecoveryInFlight ||
        _playbackFallbackRecoverySongId != null ||
        _offlineQueueWaitingSongId != null ||
        _offlineQueueActivationTargetSongId != null ||
        _shouldHoldTransitionMetrics()) {
      return false;
    }
    final LibrarySong? active = currentSong;
    if (active == null ||
        active.id != targetSongId ||
        !_playerHasLoadedCurrentSong(active) ||
        !_isPlaying) {
      return false;
    }
    if (_position > Duration.zero) {
      return true;
    }
    if (!_hasPlaybackActivationForcedStableElapsed()) {
      return false;
    }
    return _duration > Duration.zero || _playerHasLoadedCurrentSong(active);
  }

  void _schedulePlaybackActivationCheck() {
    _playbackActivationTimer?.cancel();
    _playbackActivationTimer = null;
    if (_isDisposed || _isDisposing || _playbackActivationSongId == null) {
      return;
    }
    final Duration elapsed = _playbackActivationElapsed();
    Duration? delay;
    if (elapsed < _playbackActivationMinimumLoading) {
      delay = _playbackActivationMinimumLoading - elapsed;
    } else if (elapsed < _playbackActivationForcedStableDuration) {
      delay = _playbackActivationForcedStableDuration - elapsed;
    } else {
      delay = const Duration(milliseconds: 220);
    }
    if (delay <= Duration.zero) {
      return;
    }
    _playbackActivationTimer = Timer(delay, () {
      if (_isDisposed || _isDisposing) {
        return;
      }
      _maybeResolvePlaybackActivation(notify: true);
    });
  }

  void _handlePlaybackProxyTransfer(PlaybackProxyTransfer transfer) {
    if (_isDisposed || _isDisposing) {
      return;
    }
    _recordStreamBytes(transfer.songId, transfer.bytesTransferred);
  }

  void _handlePlaybackProxyCacheProgress(PlaybackProxyCacheProgress progress) {
    if (_isDisposed || _isDisposing) {
      return;
    }
    _updateOfflinePlaybackCacheProgress(
      songId: progress.songId,
      bytesWritten: progress.bytesWritten,
      expectedBytes: progress.expectedBytes,
    );
  }

  void _handlePlaybackProxyCacheCompleted(PlaybackProxyCacheResult result) {
    if (_isDisposed || _isDisposing) {
      return;
    }
    // Always remove from the background-caching set regardless of epoch.
    _proxyCachingOnlySongIds.remove(result.songId);
    if (result.cacheEpoch != _offlinePlaybackCacheEpoch) {
      unawaited(_deleteFileIfExists(result.cachedFilePath));
      _completeOfflinePlaybackCacheWaiters(result.songId, false);
      return;
    }
    if (_completedPlaybackSaveEligibleSongIds.contains(result.songId)) {
      _finalizeCompletedPlaybackCacheSave(
        songId: result.songId,
        cachedFilePath: result.cachedFilePath,
      );
      return;
    }
    _pendingCompletedPlaybackCachePaths[result.songId] = result.cachedFilePath;
  }

  void _scheduleSnapshotSave() {
    _dataUsageSnapshotTimer?.cancel();
    _dataUsageSnapshotTimer = Timer(const Duration(milliseconds: 700), () {
      if (_isDisposing || _isDisposed) {
        return;
      }
      unawaited(_saveSnapshot());
    });
  }

  Future<void> _clearPreparedPlaybackState() async {
    _activePlaybackProxiesBySongId.clear();
    _proxyCachingOnlySongIds.clear();
    _playbackProxyBypassSongIds.clear();
    _pendingCompletedPlaybackCachePaths.clear();
    _completedPlaybackSaveEligibleSongIds.clear();
    _preparedMediaUrlsBySongId.clear();
    _preparedMediaHeadersBySongId.clear();
    _rankedPlaybackCandidatesBySongId.clear();
    _playbackCandidateIndexBySongId.clear();
    _playbackStreamInfoBySongId.clear();
    _songPlaybackBytes.clear();
    _playbackFallbackRecoveryInFlight = false;
    _playbackFallbackRecoverySongId = null;
    _playbackFallbackRecoveryIndex = null;
    _smartQueueRefillQueued = false;
    _clearPlaybackActivation();
    _syncDataUsageState();
  }

  int _startPlaybackSelection(LibrarySong song) {
    _playbackSelectionRevision += 1;
    _pendingSelectionSong = song;
    _beginPlaybackActivation(song, resetMetrics: true, notify: false);
    _debugPlayback(
      'selection.start revision=$_playbackSelectionRevision '
      'song=${_debugSongLabel(song)} '
      'queueIndex=$_queueIndex '
      'playerIndex=${_playerInstance?.state.playlist.index ?? -1}',
    );
    return _playbackSelectionRevision;
  }

  bool _isCurrentPlaybackSelection(int revision) {
    return !_isDisposing &&
        !_isDisposed &&
        revision == _playbackSelectionRevision;
  }

  bool _guardCurrentPlaybackSelection(int revision, String stage) {
    final bool isCurrent = _isCurrentPlaybackSelection(revision);
    if (!isCurrent) {
      _debugPlayback(
        'selection.stale stage=$stage '
        'revision=$revision '
        'active=$_playbackSelectionRevision '
        'pending=${_debugSongLabel(_pendingSelectionSong)} '
        'transitionSong=$_transitioningSongId '
        'transitionIndex=$_transitioningQueueIndex '
        'queueIndex=$_queueIndex',
      );
    }
    return isCurrent;
  }

  Future<void> _interruptCurrentPlayback() async {
    final Player? player = _playerInstance;
    if (player == null) {
      return;
    }
    _suppressAutoAdvanceOnNextStop = _isPlaying;
    _debugPlayback(
      'player.interrupt requested '
      'playing=$_isPlaying queueIndex=$_queueIndex '
      'suppressAutoAdvance=$_suppressAutoAdvanceOnNextStop',
    );
    try {
      await player.stop();
    } catch (_) {
      try {
        await player.pause();
      } catch (_) {}
    }
  }

  void _bindPrimaryPlayer(Player player) {
    _cancelPlayerListeners();
    _playerInstance = player;
    _playerBound = true;
    _attachPlayerListeners(player);
    _syncPlaybackNotifiers();
    unawaited(player.setRate(_settings.playbackRate));
    unawaited(_syncPlayerPlaybackModes(player));
  }

  void _cancelPlayerListeners() {
    for (final StreamSubscription<dynamic> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _playerBound = false;
  }

  void _invalidateStandbyPreloads() {
    _standbyPreloadRevision += 1;
    _standbyPreloadRetryTimer?.cancel();
    _standbyPreloadRetryTimer = null;
    if (_isDisposing || _isDisposed) {
      return;
    }
    if (_standbyPreloadRefreshInFlight) {
      return;
    }
    _standbyPreloadRefreshInFlight = true;
    unawaited(() async {
      try {
        while (!_isDisposing && !_isDisposed) {
          final int revision = _standbyPreloadRevision;
          await _refreshStandbyPreloads(revision);
          if (revision == _standbyPreloadRevision) {
            break;
          }
        }
      } finally {
        _standbyPreloadRefreshInFlight = false;
      }
    }());
  }

  Future<void> _refreshStandbyPreloads(int revision) async {
    final LibrarySong? activeSong = currentSong;
    if (activeSong == null || _queueSongIds.isEmpty) {
      await _disposeStandbyPreloads();
      return;
    }
    final int startIndex = _queueIndex + 1;
    final int preloadCount = _settings.preloadNextSongCount.clamp(0, 3);
    if (preloadCount <= 0) {
      await _disposeStandbyPreloads();
      return;
    }
    final int endIndex = math.min(
      _queueSongIds.length,
      startIndex + preloadCount,
    );
    final Set<String> desiredKeys = <String>{};
    for (int index = startIndex; index < endIndex; index += 1) {
      desiredKeys.add(_standbyPreloadKey(index, _queueSongIds[index]));
    }

    for (int index = _standbyPreloads.length - 1; index >= 0; index -= 1) {
      final _StandbyPreloadSlot slot = _standbyPreloads[index];
      if (desiredKeys.contains(
        _standbyPreloadKey(slot.queueIndex, slot.songId),
      )) {
        continue;
      }
      _standbyPreloads.removeAt(index);
      await slot.dispose();
    }

    for (int queueIndex = startIndex; queueIndex < endIndex; queueIndex += 1) {
      if (revision != _standbyPreloadRevision || _isDisposing || _isDisposed) {
        return;
      }
      final String songId = _queueSongIds[queueIndex];
      final bool alreadyLoaded = _standbyPreloads.any(
        (_StandbyPreloadSlot slot) =>
            slot.queueIndex == queueIndex && slot.songId == songId,
      );
      if (alreadyLoaded) {
        continue;
      }
      final _StandbyPreloadSlot? created = await _createStandbyPreloadSlot(
        queueIndex,
        songId,
        revision,
      );
      if (created == null) {
        continue;
      }
      if (revision != _standbyPreloadRevision || _isDisposing || _isDisposed) {
        await created.dispose();
        return;
      }
      _standbyPreloads.add(created);
    }

    if (revision == _standbyPreloadRevision &&
        !_isDisposing &&
        !_isDisposed &&
        !_isOffline &&
        !offlineMusicMode &&
        _standbyPreloads.length < desiredKeys.length) {
      _scheduleStandbyPreloadRetry(revision);
    }
  }

  void _scheduleStandbyPreloadRetry(int revision) {
    if (_standbyPreloadRetryTimer != null ||
        _isDisposing ||
        _isDisposed ||
        _settings.preloadNextSongCount <= 0) {
      return;
    }
    final DateTime? backoffUntil = _youtubeRequestBackoffUntil;
    final Duration delay =
        backoffUntil != null && DateTime.now().isBefore(backoffUntil)
        ? backoffUntil.difference(DateTime.now())
        : const Duration(seconds: 2);
    _standbyPreloadRetryTimer = Timer(delay, () {
      _standbyPreloadRetryTimer = null;
      if (revision != _standbyPreloadRevision ||
          _isDisposing ||
          _isDisposed ||
          _isOffline ||
          offlineMusicMode ||
          _settings.preloadNextSongCount <= 0 ||
          currentSong == null ||
          _queueSongIds.isEmpty) {
        return;
      }
      _invalidateStandbyPreloads();
    });
  }

  String _standbyPreloadKey(int queueIndex, String songId) {
    return '$queueIndex::$songId';
  }

  Future<_StandbyPreloadSlot?> _createStandbyPreloadSlot(
    int queueIndex,
    String songId,
    int revision,
  ) async {
    final LibrarySong? originalSong = songById(songId);
    if (originalSong == null) {
      return null;
    }
    Player? standbyPlayer;
    try {
      final LibrarySong preparedSong =
          _queueSongNeedsPreparedMediaSource(originalSong)
          ? await _preparePlayableSong(originalSong)
          : originalSong;
      if (revision != _standbyPreloadRevision || _isDisposing || _isDisposed) {
        return null;
      }
      standbyPlayer = Player();
      await standbyPlayer.setRate(_settings.playbackRate);
      await standbyPlayer.setPlaylistMode(_repeatMode);
      await standbyPlayer.open(
        Playlist(<Media>[_mediaForSong(preparedSong)]),
        play: false,
      );
      await standbyPlayer.pause();
      if (revision != _standbyPreloadRevision || _isDisposing || _isDisposed) {
        await standbyPlayer.dispose();
        return null;
      }
      _debugPlayback(
        'queue.preload standby ready index=$queueIndex '
        'song=${_debugSongLabel(preparedSong)}',
      );
      return _StandbyPreloadSlot(
        queueIndex: queueIndex,
        songId: preparedSong.id,
        player: standbyPlayer,
      );
    } catch (error) {
      _debugPlayback(
        'queue.preload standby failed index=$queueIndex '
        'song=${_debugSongLabel(originalSong)} error=$error',
      );
      if (standbyPlayer != null) {
        unawaited(standbyPlayer.dispose());
      }
      return null;
    }
  }

  Future<void> _disposeStandbyPreloads() async {
    if (_standbyPreloads.isEmpty) {
      return;
    }
    final List<_StandbyPreloadSlot> slots = List<_StandbyPreloadSlot>.from(
      _standbyPreloads,
    );
    _standbyPreloads.clear();
    for (final _StandbyPreloadSlot slot in slots) {
      await slot.dispose();
    }
  }

  Future<bool> _tryPromoteStandbyPreload(
    int targetIndex, {
    required bool shouldResumePlayback,
  }) async {
    final LibrarySong? targetSong =
        targetIndex >= 0 && targetIndex < _queueSongIds.length
        ? songById(_queueSongIds[targetIndex])
        : null;
    final int slotIndex = _standbyPreloads.indexWhere(
      (_StandbyPreloadSlot slot) =>
          slot.queueIndex == targetIndex &&
          targetIndex >= 0 &&
          targetIndex < _queueSongIds.length &&
          slot.songId == _queueSongIds[targetIndex],
    );
    if (slotIndex < 0) {
      final bool requiresDetachedReopen =
          _offlineDetachedQueueMode ||
          (targetSong != null && songNeedsResolvedPlaybackUrl(targetSong));
      if (requiresDetachedReopen) {
        _debugPlayback(
          'queue.preload promotion bypassed index=$targetIndex '
          'song=${_debugSongLabel(targetSong)} detached=$_offlineDetachedQueueMode '
          'reason=no-standby-slot',
        );
      }
      return false;
    }
    final _StandbyPreloadSlot slot = _standbyPreloads.removeAt(slotIndex);
    final Player promotedPlayer = slot.player;
    final Player? previousPlayer = _playerInstance;
    final bool canSkipPreviousPlayerStop =
        previousPlayer != null &&
        !identical(previousPlayer, promotedPlayer) &&
        (!_isPlaying || previousPlayer.state.completed);
    if (previousPlayer != null &&
        !identical(previousPlayer, promotedPlayer) &&
        !canSkipPreviousPlayerStop) {
      _cancelPlayerListeners();
      try {
        await previousPlayer.stop();
      } catch (_) {
        try {
          await previousPlayer.pause();
        } catch (_) {}
      }
    }
    _playerInstance = promotedPlayer;
    _bindPrimaryPlayer(promotedPlayer);
    _offlineDetachedQueueMode = true;
    _queueIndex = targetIndex;
    final LibrarySong? song = songById(slot.songId);
    if (song != null) {
      _pendingSelectionSong = song;
    }
    if (shouldResumePlayback) {
      await promotedPlayer.play();
    }
    _clearOfflineQueueActivationState();
    _resolveTrackTransition(song);
    if (song != null) {
      _trackPlayback(song.id);
      _scheduleSmartQueueWindowRefill(seed: song);
    }
    unawaited(_refreshOfflinePlaybackCache(anchor: song));
    _debugPlayback(
      'queue.preload promoted index=$targetIndex '
      'song=${_debugSongLabel(song)} '
      'skipStop=$canSkipPreviousPlayerStop',
    );
    if (previousPlayer != null && !identical(previousPlayer, promotedPlayer)) {
      unawaited(previousPlayer.dispose());
    }
    _invalidateStandbyPreloads();
    notifyListeners();
    return true;
  }

  void _flushBatchedNotify() {
    if (_isDisposed || _isDisposing) {
      return;
    }
    super.notifyListeners();
  }

  @override
  void notifyListeners() {
    _syncPlaybackNotifiers();
    _publishDomainStates();
    _notifyScheduler.schedule();
  }

  void notifyListenersImmediate() {
    _syncPlaybackNotifiers();
    _publishDomainStates();
    if (_isDisposed || _isDisposing) {
      return;
    }
    super.notifyListeners();
  }

  void _bumpHomeStateRevision() {
    _homeStateRevision += 1;
  }

  void _bumpSettingsStateRevision() {
    _settingsStateRevision += 1;
  }

  void _publishDomainStates() {
    home.publish(
      revision: _homeStateRevision,
      loading: _homeLoading,
      refreshResolvedOnce: _homeRefreshResolvedOnce,
      offlineViewActive: isOfflineViewActive,
      error: _homeError,
    );
    library.publish(
      revision: _libraryDataRevision,
      scanning: _scanning,
      cloudLoading: cloudLibraryLoading,
    );
    connectivity.publish(
      isOffline: _isOffline,
      offlineViewActive: isOfflineViewActive,
      connectivityMessage: _connectivityMessage,
    );
    appSettings.publish(
      revision: _settingsStateRevision,
      preloadNextSongCount: preloadNextSongCount,
      sleepTimerStatusLabel: sleepTimerStatusLabel,
      preferredRegionLabel: preferredRegionLabel,
      offlineMusicMode: offlineMusicMode,
    );
    queue.publish(
      revision: _queueSongIds.length + visibleQueueIndex,
      hasMiniPlayer: miniPlayerSong != null,
      queueLength: _queueSongIds.length,
      visibleQueueIndex: visibleQueueIndex,
    );
    search.publish(
      revision: Object.hash(
        _trendingNowRequestId,
        _onlineSearchRequestId,
        _trendingNowSongs.length,
        _onlineResults.length,
      ),
      offlineViewActive: isOfflineViewActive,
      trendingLoading: _trendingNowLoading,
      onlineLoading: _onlineLoading,
      libraryRevision: _libraryDataRevision,
      homeRevision: _homeStateRevision,
    );
  }

  void _markLibraryDataDirty([String reason = '']) {
    _libraryDataRevision += 1;
    _rebuildTopArtistsCache();
    if (reason.isNotEmpty) {
      AppLogger.trace('Library', 'data changed: $reason');
    }
  }

  void _ensureDerivedLibraryData() {
    if (_derivedLibraryRevision == _libraryDataRevision) {
      return;
    }

    final Map<String, LibrarySong> lookup = <String, LibrarySong>{
      for (final LibrarySong song in _songs) song.id: song,
      for (final LibrarySong song in _downloadedSongs) song.id: song,
      ..._transientSongsById,
    };

    final Map<String, List<LibrarySong>> playlistSongs =
        <String, List<LibrarySong>>{};
    for (final UserPlaylist playlist in _playlists) {
      playlistSongs[playlist.id] = playlist.songIds
          .map((String id) => lookup[id])
          .whereType<LibrarySong>()
          .where(shouldShowSongOutsideSearch)
          .toList(growable: false);
    }

    final Map<String, LibrarySong> likedMerged = <String, LibrarySong>{
      for (final LibrarySong song in _songs)
        if (song.isLiked) song.id: song,
      for (final LibrarySong song in _transientSongsById.values)
        if (song.isLiked) song.id: song,
    };
    final Map<String, LibrarySong> dislikedMerged = <String, LibrarySong>{
      for (final LibrarySong song in _songs)
        if (song.isDisliked) song.id: song,
      for (final LibrarySong song in _transientSongsById.values)
        if (song.isDisliked) song.id: song,
    };

    final List<LibrarySong> browsable = _filterSongsForBrowsing(_songs);
    final List<LibrarySong> downloads =
        _downloadedSongs
            .where((LibrarySong song) => File(song.path).existsSync())
            .toList(growable: false)
          ..sort((LibrarySong a, LibrarySong b) {
            final int recentCompare = b.addedAt.compareTo(a.addedAt);
            if (recentCompare != 0) {
              return recentCompare;
            }
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
    final List<LibrarySong> liked = _filterSongsForBrowsing(likedMerged.values);
    liked.sort((LibrarySong a, LibrarySong b) {
      final int playCompare = b.playCount.compareTo(a.playCount);
      if (playCompare != 0) {
        return playCompare;
      }
      final DateTime left = a.lastPlayedAt ?? a.addedAt;
      final DateTime right = b.lastPlayedAt ?? b.addedAt;
      final int recentCompare = right.compareTo(left);
      if (recentCompare != 0) {
        return recentCompare;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    final List<LibrarySong> disliked = dislikedMerged.values
        .where(
          (LibrarySong song) =>
              song.durationMs <= 0 ||
              (song.durationMs >= _minBrowsableSongDuration.inMilliseconds &&
                  song.durationMs <= _maxBrowsableSongDuration.inMilliseconds),
        )
        .toList(growable: false);
    disliked.sort((LibrarySong a, LibrarySong b) {
      final DateTime left = a.lastPlayedAt ?? a.addedAt;
      final DateTime right = b.lastPlayedAt ?? b.addedAt;
      final int recentCompare = right.compareTo(left);
      if (recentCompare != 0) {
        return recentCompare;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    _songLookupCache = lookup;
    _playlistSongsCache = playlistSongs;
    _browsableSongsCache = browsable;
    _downloadedSongsCache = downloads;
    _likedSongsCache = liked;
    _dislikedSongsCache = disliked;
    _derivedLibraryRevision = _libraryDataRevision;

    AppLogger.trace(
      'Library',
      'derived cache rebuilt songs=${_songs.length} '
          'downloads=${_downloadedSongs.length} '
          'transient=${_transientSongsById.length} playlists=${_playlists.length} '
          'liked=${_likedSongsCache.length} disliked=${_dislikedSongsCache.length}',
    );
  }

  bool isSmartQueueSong(String songId) => _smartQueueSongIds.contains(songId);

  bool isSongAvailableOffline(LibrarySong song) {
    return !song.isRemote;
  }

  bool isSongOfflineDownloadInProgress(String songId) {
    return false;
  }

  void _completeOfflinePlaybackCacheWaiters(String songId, bool saved) {
    final List<Completer<bool>> waiters =
        _offlinePlaybackCacheWaiters.remove(songId) ?? <Completer<bool>>[];
    for (final Completer<bool> waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(saved);
      }
    }
  }

  void _completeAllOfflinePlaybackCacheWaiters(bool saved) {
    for (final String songId in _offlinePlaybackCacheWaiters.keys.toList()) {
      _completeOfflinePlaybackCacheWaiters(songId, saved);
    }
  }

  bool isSongDownloading(String songId) => _downloadingSongIds.contains(songId);

  LibrarySong? downloadedSongFor(LibrarySong song) {
    _ensureDerivedLibraryData();
    return _downloadedSongs.firstWhereOrNull(
      (LibrarySong item) =>
          item.downloadSourceSongId == song.id ||
          _songIdentityKey(item) == _songIdentityKey(song),
    );
  }

  bool isSongDownloaded(LibrarySong song) => downloadedSongFor(song) != null;

  Future<String> downloadSongForOffline(LibrarySong song) async {
    final LibrarySong? existing = downloadedSongFor(song);
    if (existing != null && await File(existing.path).exists()) {
      return 'Already in Downloads';
    }
    if (!song.isRemote) {
      return 'Only online songs need downloading';
    }
    if (_downloadingSongIds.contains(song.id)) {
      return 'Download already in progress';
    }
    if (await _resolveOfflineStateForAction()) {
      return 'Internet is unavailable right now.';
    }

    _downloadingSongIds.add(song.id);
    _errorMessage = null;
    _statusMessage = 'Downloading ${song.title}...';
    notifyListeners();
    try {
      final _ResolvedDownloadPayload payload = await _downloadRemoteSong(song);
      final LibrarySong downloaded = song.copyWith(
        path: payload.audioPath,
        title: payload.title,
        artist: payload.artist,
        album: payload.album,
        albumArtist: payload.albumArtist,
        folderName: 'Downloads',
        folderPath: p.dirname(payload.audioPath),
        sourceLabel: 'Downloads',
        addedAt: DateTime.now(),
        durationMs: payload.durationMs > 0
            ? payload.durationMs
            : song.durationMs,
        isRemote: false,
        artworkUrl: payload.artworkPath ?? song.artworkUrl,
        externalUrl: song.externalUrl ?? song.path,
        downloadSourceSongId: song.id,
      );

      _downloadedSongs.removeWhere(
        (LibrarySong item) =>
            item.downloadSourceSongId == song.id ||
            _songIdentityKey(item) == _songIdentityKey(song),
      );
      _downloadedSongs.add(downloaded);
      _markLibraryDataDirty('song downloaded');
      await _saveSnapshot();
      _statusMessage = 'Downloaded to your device';
      notifyListeners();
      return 'Downloaded to Downloads';
    } catch (error) {
      _statusMessage = null;
      _errorMessage = 'Could not download this song right now.';
      notifyListeners();
      _debugLog('Download failed for ${song.id}: $error');
      return 'Download failed';
    } finally {
      _downloadingSongIds.remove(song.id);
      notifyListeners();
    }
  }

  Future<void> extendSmartQueueIfNeeded({LibrarySong? seed}) async {
    await _maybeExtendSmartQueue(seed: seed);
  }

  Future<void> appendSmartQueue({
    LibrarySong? seed,
    int batchSize = 10,
    bool force = false,
  }) async {
    if (_isOffline ||
        offlineMusicMode ||
        (!_settings.smartQueueEnabled && !force) ||
        _smartQueueLoading) {
      return;
    }

    final LibrarySong? queuedAnchor = queueSongs.lastOrNull;
    final LibrarySong? current = currentSong;
    final LibrarySong? anchor =
        (seed != null && _shouldUseSongInHomeOrSmartQueue(seed))
        ? seed
        : (queuedAnchor != null &&
              _shouldUseSongInHomeOrSmartQueue(queuedAnchor))
        ? queuedAnchor
        : (current != null && _shouldUseSongInHomeOrSmartQueue(current))
        ? current
        : null;
    if (anchor == null) {
      return;
    }

    await _appendSmartQueuePredictions(anchor, limit: batchSize);
  }

  bool _hasOfflinePlaybackCache(String songId) {
    if (!offlinePlaybackCacheEnabled) {
      return false;
    }
    final LibrarySong? song = songById(songId);
    if (song != null && !shouldShowSongOutsideSearch(song)) {
      return false;
    }
    final String? path = _offlinePlaybackCachePaths[songId];
    if (path == null || path.isEmpty) {
      return false;
    }
    if (_isOfflinePlaybackCacheFileUsable(path)) {
      return true;
    }
    _dropOfflinePlaybackCacheEntry(songId);
    return false;
  }

  String? _offlinePlaybackCachePathForSong(String songId) {
    if (!offlinePlaybackCacheEnabled) {
      return null;
    }
    final LibrarySong? song = songById(songId);
    if (song != null && !shouldShowSongOutsideSearch(song)) {
      return null;
    }
    final String? path = _offlinePlaybackCachePaths[songId];
    if (path == null || path.isEmpty) {
      return null;
    }
    if (_isOfflinePlaybackCacheFileUsable(path)) {
      return path;
    }
    _dropOfflinePlaybackCacheEntry(songId);
    return null;
  }

  bool _isOfflinePlaybackCacheFileUsable(String path) {
    if (path.trim().isEmpty) {
      return false;
    }
    final File file = File(path);
    if (!file.existsSync()) {
      return false;
    }
    final String extension = p.extension(path).toLowerCase();
    if (extension == '.m3u8' || extension == '.m3u') {
      return false;
    }
    return file.lengthSync() > 0;
  }

  void _dropOfflinePlaybackCacheEntry(String songId) {
    _offlinePlaybackCachePaths.remove(songId);
    _offlinePlaybackCacheSizesBySongId.remove(songId);
    _offlinePlaybackCacheProgressBytesBySongId.remove(songId);
    _offlinePlaybackCacheExpectedBytesBySongId.remove(songId);
    _pendingCompletedPlaybackCachePaths.remove(songId);
    _completedPlaybackSaveEligibleSongIds.remove(songId);
    _completeOfflinePlaybackCacheWaiters(songId, false);
  }

  List<LibrarySong> get recentlyAddedSongs {
    final List<LibrarySong> result = _filterSongsForBrowsing(_songs);
    result.sort(
      (LibrarySong a, LibrarySong b) => b.addedAt.compareTo(a.addedAt),
    );
    return result;
  }

  List<LibrarySong> get favoriteSongs {
    final List<LibrarySong> result = _songs
        .where(
          (LibrarySong song) =>
              song.isFavorite && shouldShowSongOutsideSearch(song),
        )
        .toList();
    result.sort(
      (LibrarySong a, LibrarySong b) => b.playCount.compareTo(a.playCount),
    );
    return result;
  }

  List<LibrarySong> get likedSongs {
    _ensureDerivedLibraryData();
    return List<LibrarySong>.unmodifiable(_likedSongsCache);
  }

  int get likedSongCount {
    _ensureDerivedLibraryData();
    return <String>{
      ..._cloudLikedSongIds,
      ..._likedSongsCache.map((LibrarySong song) => song.id),
    }.length;
  }

  int get likedSongsPendingCount =>
      pendingCloudSongCountForIds(_cloudLikedSongIds);

  int get likedSongsUnavailableCount =>
      unavailableCloudSongCountForIds(_cloudLikedSongIds);

  bool get likedSongsLoading => likedSongsPendingCount > 0;

  List<LibrarySong> get dislikedSongs {
    _ensureDerivedLibraryData();
    return List<LibrarySong>.unmodifiable(_dislikedSongsCache);
  }

  int get dislikedSongCount {
    _ensureDerivedLibraryData();
    return <String>{
      ..._cloudDislikedSongIds,
      ..._dislikedSongsCache.map((LibrarySong song) => song.id),
    }.length;
  }

  int get dislikedSongsPendingCount =>
      pendingCloudSongCountForIds(_cloudDislikedSongIds);

  int get dislikedSongsUnavailableCount =>
      unavailableCloudSongCountForIds(_cloudDislikedSongIds);

  bool get dislikedSongsLoading => dislikedSongsPendingCount > 0;

  List<LibrarySong> get topPlayedSongs {
    final List<LibrarySong> result = _songs
        .where(_shouldUseSongForHistorySignals)
        .toList(growable: false);
    result.sort((LibrarySong a, LibrarySong b) {
      final int countCompare = b.playCount.compareTo(a.playCount);
      if (countCompare != 0) {
        return countCompare;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return result;
  }

  List<LibrarySong> get recentlyPlayedSongs {
    final Set<String> seen = <String>{};
    final List<LibrarySong> result = <LibrarySong>[];
    for (final PlaybackEntry entry in _history) {
      if (seen.add(entry.songId)) {
        final LibrarySong? song = songById(entry.songId);
        if (song != null && _shouldUseSongForHistorySignals(song)) {
          result.add(song);
        }
      }
    }
    final List<LibrarySong> fallbackSongs =
        <LibrarySong>[..._songs, ..._transientSongsById.values]
            .where(
              (LibrarySong song) =>
                  _shouldUseSongForHistorySignals(song) &&
                  (song.playCount > 0 || song.lastPlayedAt != null),
            )
            .toList(growable: false)
          ..sort((LibrarySong a, LibrarySong b) {
            final DateTime left = a.lastPlayedAt ?? a.addedAt;
            final DateTime right = b.lastPlayedAt ?? b.addedAt;
            final int recentCompare = right.compareTo(left);
            if (recentCompare != 0) {
              return recentCompare;
            }
            return b.playCount.compareTo(a.playCount);
          });
    for (final LibrarySong song in fallbackSongs) {
      if (seen.add(song.id)) {
        result.add(song);
      }
    }
    return result;
  }

  void cacheSearchDraft(String value) {
    _searchDraft = value;
  }

  void clearSearchState({bool clearRecentSearches = false}) {
    _onlineSearchRequestId += 1;
    _searchDraft = '';
    _onlineResults = <LibrarySong>[];
    _onlineError = null;
    _onlineLoading = false;
    _onlineQuery = '';
    _onlineResultLimit = 0;
    _onlineHasMore = false;
    if (clearRecentSearches) {
      _recentSearchTerms = <String>[];
    }
    _scheduleSnapshotSave();
    notifyListeners();
  }

  void rememberRecentSearch(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    registerUserActivity(reason: 'recent-search', notify: false);
    _recentSearchTerms = <String>[
      trimmed,
      ..._recentSearchTerms.where(
        (String item) => item.toLowerCase() != trimmed.toLowerCase(),
      ),
    ].take(8).toList(growable: false);
    _scheduleSnapshotSave();
  }

  void removeRecentSearch(String value) {
    _recentSearchTerms = _recentSearchTerms
        .where((String item) => item != value)
        .toList(growable: false);
    _scheduleSnapshotSave();
  }

  Future<void> setSleepTimerMinutes(int value) async {
    final int normalized = switch (value) {
      10 || 20 || 30 || 45 || 60 => value,
      _ => 0,
    };
    if (_sleepTimerMinutes == normalized) {
      if (normalized == 0) {
        await cancelSleepTimer();
      } else {
        registerUserActivity(reason: 'sleep-timer-refresh', notify: true);
      }
      return;
    }
    _sleepTimerMinutes = normalized;
    if (normalized == 0) {
      _clearSleepTimerRuntimeState();
    } else {
      _sleepTimerRemainingDuration = Duration(minutes: normalized);
      registerUserActivity(reason: 'sleep-timer-set', notify: false);
    }
    _bumpSettingsStateRevision();
    notifyListeners();
  }

  Future<void> cancelSleepTimer() async {
    if (!sleepTimerEnabled &&
        _sleepTimerEndAt == null &&
        _sleepTimerRemainingDuration == null) {
      return;
    }
    _sleepTimerMinutes = 0;
    _clearSleepTimerRuntimeState();
    notifyListeners();
  }

  void registerScrollActivity() {
    registerUserActivity(reason: 'scroll', throttle: true);
  }

  void registerUserActivity({
    String reason = 'interaction',
    bool notify = false,
    bool throttle = false,
  }) {
    if (!sleepTimerEnabled) {
      return;
    }
    final DateTime now = DateTime.now();
    if (throttle) {
      final DateTime? lastActivityAt = _lastSleepTimerActivityAt;
      if (lastActivityAt != null &&
          now.difference(lastActivityAt) < const Duration(seconds: 2)) {
        return;
      }
    }
    _lastSleepTimerActivityAt = now;
    _sleepTimerRemainingDuration = Duration(minutes: sleepTimerMinutes);
    _sleepTimerEndAt = _isPlaying
        ? now.add(_sleepTimerRemainingDuration!)
        : null;
    _scheduleSleepTimer();
    AppLogger.trace('SleepTimer', 'Activity reset by $reason');
    if (notify) {
      notifyListeners();
    }
  }

  void _scheduleSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (!sleepTimerEnabled || !_isPlaying) {
      return;
    }
    final DateTime? endAt = _sleepTimerEndAt;
    if (endAt == null) {
      return;
    }
    final Duration delay = endAt.difference(DateTime.now());
    _sleepTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      _handleSleepTimerExpired,
    );
  }

  void _handleSleepTimerExpired() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (!sleepTimerEnabled) {
      return;
    }
    _sleepTimerRemainingDuration = Duration.zero;
    unawaited(_finalizeSleepTimerStop());
  }

  void _clearSleepTimerRuntimeState() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndAt = null;
    _lastSleepTimerActivityAt = null;
    _sleepTimerRemainingDuration = null;
  }

  void _pauseSleepTimerCountdown() {
    if (!sleepTimerEnabled) {
      return;
    }
    final DateTime? endAt = _sleepTimerEndAt;
    if (endAt != null) {
      final Duration remaining = endAt.difference(DateTime.now());
      _sleepTimerRemainingDuration = remaining.isNegative
          ? Duration.zero
          : remaining;
    } else {
      _sleepTimerRemainingDuration ??= Duration(minutes: sleepTimerMinutes);
    }
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndAt = null;
  }

  void _resumeSleepTimerCountdown({bool notify = false}) {
    if (!sleepTimerEnabled) {
      return;
    }
    final Duration remaining =
        _sleepTimerRemainingDuration ?? Duration(minutes: sleepTimerMinutes);
    if (remaining <= Duration.zero) {
      unawaited(_finalizeSleepTimerStop());
      return;
    }
    _sleepTimerEndAt = DateTime.now().add(remaining);
    _scheduleSleepTimer();
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _finalizeSleepTimerStop() async {
    if (_sleepTimerStopInFlight) {
      return;
    }
    _sleepTimerStopInFlight = true;
    AppLogger.info('SleepTimer', 'Stopping playback after inactivity timeout');
    try {
      _clearSleepTimerRuntimeState();
      _sleepTimerMinutes = 0;
      _suppressAutoAdvanceOnNextStop = true;
      try {
        await _player.stop();
      } catch (_) {}
      notifyListeners();
    } finally {
      _sleepTimerStopInFlight = false;
    }
  }

  String _sleepTimerOptionLabel(int minutes) {
    return switch (minutes) {
      10 => '10 min',
      20 => '20 min',
      30 => '30 min',
      45 => '45 min',
      60 => '1 hour',
      _ => 'Off',
    };
  }

  String _formatSleepTimerRemaining(Duration duration) {
    if (duration.inSeconds <= 0) {
      return 'Ending now';
    }
    if (duration.inHours >= 1) {
      final int hours = duration.inHours;
      final int minutes = duration.inMinutes.remainder(60);
      if (minutes == 0) {
        return '${hours}h left';
      }
      return '${hours}h ${minutes}m';
    }
    final int minutes = duration.inMinutes;
    final int seconds = duration.inSeconds.remainder(60);
    if (minutes <= 0) {
      return '${seconds}s left';
    }
    return seconds == 0 ? '${minutes}m left' : '${minutes}m ${seconds}s';
  }

  List<PlaybackEntry> get validPlaybackHistory => _history
      .where(
        (PlaybackEntry entry) =>
            _shouldUseSongIdForHistorySignals(entry.songId) &&
            (entry.listenedToEnd || entry.completionRatio >= 0.88),
      )
      .toList(growable: false);

  List<LibrarySong> get _decisionLikedSongs => likedSongs
      .where((LibrarySong song) => song.isRemote)
      .toList(growable: false);

  List<LibrarySong> get _decisionDislikedSongs => dislikedSongs
      .where((LibrarySong song) => song.isRemote)
      .toList(growable: false);

  bool _shouldUseSongForHistorySignals(LibrarySong song) {
    return song.isRemote && shouldShowSongOutsideSearch(song);
  }

  bool _shouldUseSongIdForHistorySignals(String songId) {
    final LibrarySong? song = songById(songId);
    return song != null && _shouldUseSongForHistorySignals(song);
  }

  void _prunePlaybackHistory() {
    _history = _history
        .where(
          (PlaybackEntry entry) =>
              _shouldUseSongIdForHistorySignals(entry.songId),
        )
        .take(300)
        .toList(growable: false);
  }

  List<AlbumCollection> get albums {
    final Map<String, List<LibrarySong>> grouped =
        <String, List<LibrarySong>>{};
    for (final LibrarySong song in browsableSongs) {
      final String key =
          '${song.album.trim().toLowerCase()}::${song.albumArtist.trim().toLowerCase()}';
      grouped.putIfAbsent(key, () => <LibrarySong>[]).add(song);
    }

    final List<AlbumCollection> result = grouped.entries.map((
      MapEntry<String, List<LibrarySong>> entry,
    ) {
      final List<LibrarySong> sortedSongs = List<LibrarySong>.from(entry.value)
        ..sort((LibrarySong a, LibrarySong b) {
          final int discCompare = (a.discNumber ?? 0).compareTo(
            b.discNumber ?? 0,
          );
          if (discCompare != 0) {
            return discCompare;
          }
          final int trackCompare = (a.trackNumber ?? 0).compareTo(
            b.trackNumber ?? 0,
          );
          if (trackCompare != 0) {
            return trackCompare;
          }
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      final LibrarySong leadSong = sortedSongs.first;
      return AlbumCollection(
        id: entry.key,
        title: leadSong.album,
        artist: leadSong.albumArtist,
        songs: sortedSongs,
      );
    }).toList();

    result.sort((AlbumCollection a, AlbumCollection b) {
      final int playCompare = b.totalPlays.compareTo(a.totalPlays);
      if (playCompare != 0) {
        return playCompare;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return result;
  }

  List<ArtistCollection> get artists {
    final Map<String, List<LibrarySong>> grouped =
        <String, List<LibrarySong>>{};
    for (final LibrarySong song in browsableSongs) {
      final String key = song.artist.trim().toLowerCase();
      grouped.putIfAbsent(key, () => <LibrarySong>[]).add(song);
    }

    final List<ArtistCollection> result = grouped.entries
        .map(
          (MapEntry<String, List<LibrarySong>> entry) => ArtistCollection(
            id: entry.key,
            name: entry.value.first.artist,
            songs: List<LibrarySong>.from(entry.value)
              ..sort((LibrarySong a, LibrarySong b) {
                return a.title.toLowerCase().compareTo(b.title.toLowerCase());
              }),
          ),
        )
        .toList();

    result.sort((ArtistCollection a, ArtistCollection b) {
      final int playCompare = b.totalPlays.compareTo(a.totalPlays);
      if (playCompare != 0) {
        return playCompare;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  List<ArtistCollection> get topArtists =>
      List<ArtistCollection>.unmodifiable(_topArtistsCache);

  List<ArtistCollection> preferredArtists({int limit = 10}) {
    if (limit <= 0) {
      return const <ArtistCollection>[];
    }
    return _topArtistsCache.take(limit).toList(growable: false);
  }

  void _rebuildTopArtistsCache() {
    final List<String> orderedKeys = _cloudPreferenceProfile.artistKeyOrder
        .map(_normalizeToken)
        .where((String key) => key.isNotEmpty)
        .take(10)
        .toList(growable: false);
    if (orderedKeys.isEmpty) {
      _topArtistsCache = const <ArtistCollection>[];
      return;
    }

    final List<ArtistCollection> resolved = <ArtistCollection>[];
    final Set<String> seen = <String>{};
    final List<ArtistCollection> libraryArtists = artists;
    final Map<String, ArtistCollection> artistsById =
        <String, ArtistCollection>{
          for (final ArtistCollection artist in libraryArtists)
            artist.id: artist,
        };
    final Map<String, ArtistCollection> artistsByNormalizedName =
        <String, ArtistCollection>{
          for (final ArtistCollection artist in libraryArtists)
            _normalizeToken(artist.name): artist,
        };
    for (final String artistKey in orderedKeys) {
      if (!seen.add(artistKey)) {
        continue;
      }
      final ArtistCollection? matched =
          artistsById[artistKey] ?? artistsByNormalizedName[artistKey];
      resolved.add(
        matched ??
            ArtistCollection(
              id: artistKey,
              name: _displayArtistNameFromKey(artistKey),
              songs: const <LibrarySong>[],
            ),
      );
    }
    _topArtistsCache = List<ArtistCollection>.unmodifiable(resolved);
  }

  String _displayArtistNameFromKey(String key) {
    final List<String> words = key
        .trim()
        .split(RegExp(r'\s+'))
        .where((String word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      return key.trim();
    }
    return words
        .map(
          (String word) => word.length == 1
              ? word.toUpperCase()
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  List<FolderCollection> get folders {
    final Map<String, List<LibrarySong>> grouped =
        <String, List<LibrarySong>>{};
    for (final LibrarySong song in browsableSongs) {
      grouped.putIfAbsent(song.folderPath, () => <LibrarySong>[]).add(song);
    }

    final List<FolderCollection> result = grouped.entries
        .map(
          (MapEntry<String, List<LibrarySong>> entry) => FolderCollection(
            id: entry.key,
            name: entry.value.first.folderName,
            path: entry.key,
            songs: List<LibrarySong>.from(entry.value)
              ..sort((LibrarySong a, LibrarySong b) {
                return a.title.toLowerCase().compareTo(b.title.toLowerCase());
              }),
          ),
        )
        .toList();

    result.sort(
      (FolderCollection a, FolderCollection b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return result;
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    AppLogger.info('Startup', 'Controller initialize started');
    await AppLogger.timeAsync<void>('Startup', 'Load snapshot', _loadSnapshot);
    _reconcileCachedCloudStateWithCurrentUser();
    unawaited(_deleteLegacyOfflinePlaybackCacheDirectory());
    _player;
    unawaited(_primeStartupMiniPlayerPlayback());
    // Never block app startup on Android runtime permission UI.
    unawaited(_ensureNotificationPermission());
    _bindNotificationActions();
    _initialized = true;
    unawaited(AndroidMediaNotificationBridge.stop());
    unawaited(WindowsMediaControlsBridge.stop());
    notifyListeners();
    _scheduleStartupContinuation();
    AppLogger.info('Startup', 'Controller initialize completed');
  }

  Future<void> loadUserDataFromCloud({bool force = false}) {
    final Future<void>? activeLoad = _cloudUserDataLoadFuture;
    if (activeLoad != null) {
      return activeLoad;
    }

    final Future<void> loadFuture = _loadUserDataFromCloud(force: force);
    _cloudUserDataLoadFuture = loadFuture;
    return loadFuture.whenComplete(() {
      if (identical(_cloudUserDataLoadFuture, loadFuture)) {
        _cloudUserDataLoadFuture = null;
      }
    });
  }

  Future<void> _loadUserDataFromCloud({bool force = false}) async {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null) {
      return;
    }

    if (!_initialized) {
      await initialize();
    }

    final String? userId = service.currentUserId;
    if (userId == null) {
      await clearUserDataFromCloud();
      return;
    }

    if (!service.supportsCloudSync) {
      if (_activeCloudUserId != userId || !_cloudUserDataLoaded) {
        _queueCloudSyncMessage(
          'Cloud sync is temporarily disabled on Windows. Local music data is still available.',
        );
      }
      _activeCloudUserId = userId;
      _cloudUserDataLoaded = true;
      notifyListeners();
      return;
    }

    try {
      AppLogger.info(
        'Cloud',
        'Loading Firestore library for user=$userId force=$force',
      );
      await _cloudUserDataSubscription?.cancel();
      _cloudUserDataSubscription = null;
      final DateTime? remoteRevision = await service.loadCurrentUserRevision();
      if (_isDisposed || _isDisposing || service.currentUserId != userId) {
        return;
      }
      if (!force &&
          _activeCloudUserId == userId &&
          _cloudUserDataLoaded &&
          _sameCloudRevision(_cloudLibraryRevision, remoteRevision)) {
        _cloudLibraryRevision = remoteRevision;
        return;
      }
      final FirestoreUserData userData = await service.loadCurrentUserData();
      if (_isDisposed || _isDisposing || service.currentUserId != userId) {
        return;
      }
      _activeCloudUserId = userId;
      _cloudUserDataLoaded = true;
      _applyCloudUserData(userData);
      if (userData.preferenceProfile.profileVersion <
          _recommendationProfileVersion) {
        _scheduleCloudPreferenceProfileSync();
      }
      await _saveSnapshot();
      notifyListeners();
      AppLogger.info(
        'Cloud',
        'Firestore library ready playlists=${_playlists.length}',
      );
    } on FirestoreUserDataException catch (error) {
      if (_isDisposed || _isDisposing || service.currentUserId != userId) {
        return;
      }
      _queueCloudSyncMessage(error.message);
      notifyListeners();
    } catch (error) {
      if (_isDisposed || _isDisposing || service.currentUserId != userId) {
        return;
      }
      _queueCloudSyncMessage(
        'Could not load your Firestore library. Local data is still available.',
      );
      _debugLog('Firestore user data load failed: $error');
      notifyListeners();
    }
  }

  Future<void> clearUserDataFromCloud() async {
    _cloudUserDataLoadFuture = null;
    await _cloudUserDataSubscription?.cancel();
    _cloudUserDataSubscription = null;
    _cloudPlaylistSongLoadFutures.clear();
    _applyCloudUserData(const FirestoreUserData.empty());
    _activeCloudUserId = null;
    _cloudLibraryRevision = null;
    _cloudUserDataLoaded = false;
    _cloudPreferenceProfileSyncTimer?.cancel();
    _cloudPreferenceProfileSyncTimer = null;
    await _saveSnapshot();
    notifyListeners();
    _refreshHomeAfterCloudDataChange();
  }

  void _applyCloudUserData(FirestoreUserData userData) {
    final Set<String> previousLikedSongIds = Set<String>.from(
      _cloudLikedSongIds,
    );
    final Set<String> previousDislikedSongIds = Set<String>.from(
      _cloudDislikedSongIds,
    );
    final Set<String> dislikedSongIds = Set<String>.from(
      userData.dislikedSongIds,
    );
    final Set<String> likedSongIds = Set<String>.from(userData.likedSongIds)
      ..removeAll(dislikedSongIds);
    _cloudLikedSongIds
      ..clear()
      ..addAll(likedSongIds);
    _cloudDislikedSongIds
      ..clear()
      ..addAll(dislikedSongIds);
    _cloudPreferenceProfile = userData.preferenceProfile;
    _rebuildTopArtistsCache();

    _applyCloudPreferenceStateToCollections(<String>{
      ...previousLikedSongIds,
      ...previousDislikedSongIds,
      ...likedSongIds,
      ...dislikedSongIds,
    });
    final List<UserPlaylist> nextPlaylists = userData.playlists.toList(
      growable: false,
    )..sort(_sortUserPlaylists);
    _playlists = _mergeCloudPlaylists(nextPlaylists);
    _cloudLibraryRevision = userData.libraryRevision ?? _cloudLibraryRevision;
    _markLibraryDataDirty('cloud user data applied');
  }

  int _sortUserPlaylists(UserPlaylist a, UserPlaylist b) {
    final int updatedCompare = b.updatedAt.compareTo(a.updatedAt);
    if (updatedCompare != 0) {
      return updatedCompare;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  void _queueCloudSyncMessage(String message) {
    _cloudSyncMessage = message;
  }

  LibrarySong _withCloudPreferenceState(LibrarySong song) {
    final bool isDisliked = _cloudDislikedSongIds.contains(song.id);
    final bool isLiked = !isDisliked && _cloudLikedSongIds.contains(song.id);
    if (song.isLiked == isLiked && song.isDisliked == isDisliked) {
      return song;
    }
    return song.copyWith(isLiked: isLiked, isDisliked: isDisliked);
  }

  LibrarySong _withKnownCloudPreferenceState(LibrarySong song) {
    if (_activeCloudUserId == null || !_cloudUserDataLoaded) {
      return song;
    }
    return _withCloudPreferenceState(song);
  }

  Future<void> _hydrateMissingCloudSongs({
    Iterable<String> songIds = const <String>[],
    bool includeCloudPreferenceSongs = true,
  }) async {
    if (_isDisposed || _isDisposing) {
      return;
    }

    final Set<String> candidateSongIds = <String>{...songIds};
    if (includeCloudPreferenceSongs) {
      candidateSongIds
        ..addAll(_cloudLikedSongIds)
        ..addAll(_cloudDislikedSongIds);
    }
    final List<String> missingSongIds = candidateSongIds
        .where((String songId) {
          return _canHydrateCloudSongId(songId) &&
              songById(songId) == null &&
              !_cloudSongHydrationInFlight.contains(songId);
        })
        .toList(growable: false);
    if (missingSongIds.isEmpty) {
      return;
    }
    final List<String> currentBatch = missingSongIds
        .take(_cloudSongHydrationBatchSize)
        .toList(growable: false);
    final List<String> remainingSongIds = missingSongIds
        .skip(_cloudSongHydrationBatchSize)
        .toList(growable: false);
    _cloudSongHydrationInFlight.addAll(currentBatch);

    void scheduleRemainingHydration() {
      if (remainingSongIds.isEmpty || _isDisposed || _isDisposing) {
        return;
      }
      unawaited(
        Future<void>.delayed(_cloudSongHydrationBatchDelay, () {
          return _hydrateMissingCloudSongs(
            songIds: remainingSongIds,
            includeCloudPreferenceSongs: false,
          );
        }),
      );
    }

    final String? expectedUserId = _firestoreUserDataService?.currentUserId;
    List<LibrarySong?> hydratedSongs = const <LibrarySong?>[];
    try {
      hydratedSongs = await Future.wait(
        currentBatch.map(_hydrateCloudSongById),
      );
    } finally {
      _cloudSongHydrationInFlight.removeAll(currentBatch);
    }

    if (_isDisposed ||
        _isDisposing ||
        expectedUserId == null ||
        _firestoreUserDataService?.currentUserId != expectedUserId ||
        _activeCloudUserId != expectedUserId ||
        !_cloudUserDataLoaded) {
      return;
    }

    bool changed = false;
    bool queueNeedsRestrictionPrune = false;
    final List<String> hydratedSongIds = <String>[];
    for (final LibrarySong song in hydratedSongs.whereType<LibrarySong>()) {
      hydratedSongIds.add(song.id);
      _rememberTransientSong(song);
      changed = true;
      final bool affectsQueue =
          _queueSongIds.contains(song.id) ||
          _detachedSequentialQueueSongIds.contains(song.id) ||
          currentSong?.id == song.id;
      final bool restrictedInQueue =
          !shouldShowSongOutsideSearch(song) ||
          ((_smartQueueSongIds.contains(song.id) ||
                  _queueSongIds.contains(song.id)) &&
              !_isShortEnoughForHomeAndSmartQueue(song));
      if (affectsQueue && restrictedInQueue) {
        queueNeedsRestrictionPrune = true;
      }
    }
    if (!changed) {
      scheduleRemainingHydration();
      return;
    }

    _debugPlayback(
      'cloud.hydration applied '
      'hydrated=${hydratedSongIds.join(",")} '
      'queueNeedsRestrictionPrune=$queueNeedsRestrictionPrune '
      'queueLen=${_queueSongIds.length} '
      'queueIndex=$_queueIndex',
    );
    if (queueNeedsRestrictionPrune) {
      _debugPlayback(
        'cloud.hydration triggering restricted queue prune '
        'current=${_debugSongLabel(currentSong)}',
      );
      _pruneRestrictedSongsFromQueue();
    }

    unawaited(_saveSnapshot());
    if (!_isDisposed && !_isDisposing) {
      notifyListeners();
    }
    scheduleRemainingHydration();
  }

  bool _canHydrateCloudSongId(String songId) {
    final String normalizedSongId = songId.trim();
    if (normalizedSongId.startsWith('yt:')) {
      return normalizedSongId.substring(3).trim().isNotEmpty;
    }
    if (!normalizedSongId.startsWith('url:')) {
      return false;
    }
    final Uri? uri = Uri.tryParse(normalizedSongId.substring(4).trim());
    return uri != null && uri.hasScheme;
  }

  Future<LibrarySong?> _hydrateCloudSongById(String songId) async {
    try {
      if (songId.startsWith('yt:')) {
        final String videoId = songId.substring(3).trim();
        if (videoId.isEmpty) {
          return null;
        }
        final Video video = await _yt.videos.get(videoId);
        return _withKnownCloudPreferenceState(_videoToSong(video));
      }

      if (songId.startsWith('url:')) {
        final Uri? uri = Uri.tryParse(songId.substring(4));
        if (uri == null || !uri.hasScheme) {
          return null;
        }
        return _withKnownCloudPreferenceState(_urlToSong(uri));
      }
    } catch (error) {
      _debugLog('Cloud song hydration failed for $songId: $error');
    }
    return null;
  }

  void _applyCloudPreferenceStateToCollections(
    Set<String> songIds, {
    bool syncQueue = true,
    bool pruneQueue = true,
  }) {
    if (songIds.isEmpty) {
      return;
    }
    _songs = _songs
        .map((LibrarySong song) {
          if (!songIds.contains(song.id)) {
            return song;
          }
          return _withCloudPreferenceState(song);
        })
        .toList(growable: false);
    _transientSongsById.updateAll((String id, LibrarySong song) {
      if (!songIds.contains(id)) {
        return song;
      }
      return _withCloudPreferenceState(song);
    });
    if (pruneQueue) {
      _pruneRestrictedSongsFromQueue(syncPlayer: syncQueue);
    }
    _markLibraryDataDirty('cloud preference state updated');
  }

  bool _pruneRestrictedSongsFromQueue({
    bool syncPlayer = true,
    int? preferredContinuationIndex,
  }) {
    bool keepQueueSong(String songId) {
      final LibrarySong? song = songById(songId);
      if (song == null || !shouldShowSongOutsideSearch(song)) {
        return false;
      }
      if (_smartQueueSongIds.contains(songId) &&
          !_isShortEnoughForHomeAndSmartQueue(song)) {
        return false;
      }
      return true;
    }

    final List<String> previousQueueSongIds = List<String>.from(_queueSongIds);
    final List<String> nextQueueSongIds = _queueSongIds
        .where(keepQueueSong)
        .toList(growable: false);
    final List<String> nextDetachedSequentialQueueSongIds =
        _detachedSequentialQueueSongIds
            .where(keepQueueSong)
            .toList(growable: false);
    if (listEquals(previousQueueSongIds, nextQueueSongIds) &&
        listEquals(
          _detachedSequentialQueueSongIds,
          nextDetachedSequentialQueueSongIds,
        )) {
      _debugPlayback(
        'queue.prune skipped no restricted changes '
        'queueLen=${_queueSongIds.length} '
        'queueIndex=$_queueIndex '
        'queue=${_debugQueueSnapshot(songIds: _queueSongIds, activeIndex: _queueIndex)} '
        'syncPlayer=$syncPlayer',
      );
      return false;
    }

    final String? currentSongId = currentSong?.id;
    final int previousQueueIndex = _queueIndex;
    final List<String> removedSongIds = previousQueueSongIds
        .where((String songId) => !nextQueueSongIds.contains(songId))
        .toList(growable: false);
    _queueSongIds = nextQueueSongIds;
    _detachedSequentialQueueSongIds = nextDetachedSequentialQueueSongIds;
    _smartQueueSongIds.removeAll(removedSongIds);

    if (_queueSongIds.isEmpty) {
      _queueIndex = 0;
    } else if (preferredContinuationIndex != null) {
      _queueIndex = preferredContinuationIndex.clamp(
        0,
        _queueSongIds.length - 1,
      );
    } else {
      final int currentSongIndex = currentSongId == null
          ? -1
          : _queueSongIds.indexOf(currentSongId);
      if (currentSongIndex >= 0) {
        _queueIndex = currentSongIndex;
      } else {
        _queueIndex = previousQueueIndex.clamp(0, _queueSongIds.length - 1);
      }
    }

    _debugPlayback(
      'queue.prune removed restricted songs '
      'removed=${removedSongIds.join(",")} '
      'previousLen=${previousQueueSongIds.length} '
      'nextLen=${_queueSongIds.length} '
      'previousIndex=$previousQueueIndex '
      'nextIndex=$_queueIndex '
      'currentSongId=$currentSongId '
      'preferredContinuationIndex=$preferredContinuationIndex '
      'before=${_debugQueueSnapshot(songIds: previousQueueSongIds, activeIndex: previousQueueIndex)} '
      'after=${_debugQueueSnapshot(songIds: _queueSongIds, activeIndex: _queueIndex)} '
      'syncPlayer=$syncPlayer',
    );

    if (syncPlayer) {
      unawaited(
        _syncPlayerAfterRestrictedQueuePrune(
          previousQueueSongIds: previousQueueSongIds,
        ),
      );
    }
    return true;
  }

  Future<void> _syncPlayerAfterRestrictedQueuePrune({
    required List<String> previousQueueSongIds,
  }) async {
    if (_isDisposed || _isDisposing || previousQueueSongIds.isEmpty) {
      return;
    }
    _debugPlayback(
      'queue.prune sync start '
      'previousLen=${previousQueueSongIds.length} '
      'nextLen=${_queueSongIds.length} '
      'queueIndex=$_queueIndex '
      'playing=$_isPlaying '
      'playerIndex=${_player.state.playlist.index}',
    );
    if (_queueSongIds.isEmpty) {
      _offlineDetachedQueueMode = false;
      _clearTrackTransition();
      _debugPlayback('queue.prune sync stopping player because queue is empty');
      await _player.stop();
      if (!_isDisposed && !_isDisposing) {
        notifyListeners();
      }
      return;
    }

    final int targetIndex = _queueIndex.clamp(0, _queueSongIds.length - 1);
    _debugPlayback(
      'queue.prune sync reopen '
      'targetIndex=$targetIndex '
      'target=${_debugSongLabel(songById(_queueSongIds[targetIndex]))}',
    );
    await _reopenQueueAtIndex(
      targetIndex,
      forcePlay: _isPlaying,
      preferDetached: _offlineDetachedQueueMode,
    );
  }

  List<UserPlaylist> _mergeCloudPlaylists(List<UserPlaylist> incoming) {
    final Map<String, UserPlaylist> existingById = <String, UserPlaylist>{
      for (final UserPlaylist playlist in _playlists) playlist.id: playlist,
    };
    return incoming
        .map((UserPlaylist playlist) {
          final UserPlaylist? existing = existingById[playlist.id];
          if (existing != null && _samePlaylist(existing, playlist)) {
            return existing;
          }
          return playlist;
        })
        .toList(growable: false);
  }

  bool _samePlaylist(UserPlaylist a, UserPlaylist b) {
    return a.id == b.id &&
        a.name == b.name &&
        a.createdAt == b.createdAt &&
        a.updatedAt == b.updatedAt &&
        a.lastSyncedAt == b.lastSyncedAt &&
        a.songCount == b.songCount &&
        a.songIdsComplete == b.songIdsComplete &&
        listEquals(a.songIds, b.songIds);
  }

  List<String> _mergePlaylistSongIds({
    required List<String> baseSongIds,
    required List<String> localSongIds,
    required List<String> remoteSongIds,
  }) {
    final Set<String> baseSet = baseSongIds.toSet();
    final Set<String> localSet = localSongIds.toSet();
    final Set<String> removals = baseSet.difference(localSet);
    final List<String> merged = remoteSongIds
        .where((String songId) => !removals.contains(songId))
        .toList(growable: true);
    final List<String> additions = localSongIds
        .where((String songId) => !baseSet.contains(songId))
        .toList(growable: false);

    for (final String songId in additions) {
      if (merged.contains(songId)) {
        continue;
      }
      final int localIndex = localSongIds.indexOf(songId);
      int insertIndex = merged.length;

      for (int index = localIndex - 1; index >= 0; index--) {
        final int mergedIndex = merged.indexOf(localSongIds[index]);
        if (mergedIndex >= 0) {
          insertIndex = mergedIndex + 1;
          break;
        }
      }

      if (insertIndex == merged.length) {
        for (int index = localIndex + 1; index < localSongIds.length; index++) {
          final int mergedIndex = merged.indexOf(localSongIds[index]);
          if (mergedIndex >= 0) {
            insertIndex = mergedIndex;
            break;
          }
        }
      }

      merged.insert(insertIndex.clamp(0, merged.length), songId);
    }

    return merged;
  }

  UserPlaylist _mergePlaylistConflict({
    required UserPlaylist base,
    required UserPlaylist local,
    required UserPlaylist remote,
  }) {
    final bool nameChangedLocally = local.name != base.name;
    final List<String> mergedSongIds = _mergePlaylistSongIds(
      baseSongIds: base.songIds,
      localSongIds: local.songIds,
      remoteSongIds: remote.songIds,
    );
    return remote.copyWith(
      name: nameChangedLocally ? local.name : remote.name,
      songIds: mergedSongIds,
      songCount: mergedSongIds.length,
      songIdsComplete: true,
      updatedAt: DateTime.now(),
    );
  }

  Future<void> _markPlaylistCloudSynced(
    String playlistId,
    DateTime syncedAt,
  ) async {
    bool changed = false;
    _playlists = _playlists
        .map((UserPlaylist playlist) {
          if (playlist.id != playlistId ||
              playlist.lastSyncedAt == syncedAt ||
              playlist.updatedAt != syncedAt) {
            return playlist;
          }
          changed = true;
          return playlist.copyWith(lastSyncedAt: syncedAt);
        })
        .toList(growable: false);
    if (!changed) {
      return;
    }
    await _saveSnapshot();
    if (!_isDisposed && !_isDisposing) {
      notifyListeners();
    }
  }

  bool _sameCloudRevision(DateTime? a, DateTime? b) {
    if (a == null || b == null) {
      return a == b;
    }
    return a.isAtSameMomentAs(b);
  }

  Future<void> loadPlaylistSongsFromCloud(String playlistId) {
    final Future<void>? activeLoad = _cloudPlaylistSongLoadFutures[playlistId];
    if (activeLoad != null) {
      return activeLoad;
    }

    final Future<void> loadFuture = _loadPlaylistSongsFromCloud(playlistId);
    _cloudPlaylistSongLoadFutures[playlistId] = loadFuture;
    notifyListeners();
    return loadFuture.whenComplete(() {
      if (identical(_cloudPlaylistSongLoadFutures[playlistId], loadFuture)) {
        _cloudPlaylistSongLoadFutures.remove(playlistId);
        if (!_isDisposed && !_isDisposing) {
          notifyListeners();
        }
      }
    });
  }

  Future<void> _loadPlaylistSongsFromCloud(String playlistId) async {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }
    final UserPlaylist? existing = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (existing == null || existing.songIdsComplete) {
      return;
    }

    final String expectedUserId = service.currentUserId!;
    try {
      final UserPlaylist? loaded = await service.loadPlaylistSongs(playlistId);
      if (_isDisposed ||
          _isDisposing ||
          service.currentUserId != expectedUserId ||
          _activeCloudUserId != expectedUserId ||
          loaded == null) {
        return;
      }
      _playlists =
          _playlists
              .map((UserPlaylist playlist) {
                return playlist.id == playlistId ? loaded : playlist;
              })
              .toList(growable: false)
            ..sort(_sortUserPlaylists);
      _markLibraryDataDirty('cloud playlist songs loaded');
      unawaited(
        _hydrateMissingCloudSongs(
          songIds: loaded.songIds,
          includeCloudPreferenceSongs: false,
        ),
      );
      await _saveSnapshot();
      if (!_isDisposed && !_isDisposing) {
        notifyListeners();
      }
    } on FirestoreUserDataException catch (error) {
      _queueCloudSyncMessage(error.message);
      if (!_isDisposed && !_isDisposing) {
        notifyListeners();
      }
    } catch (error) {
      _queueCloudSyncMessage(
        'Could not load this playlist from Firestore. Local data is still available.',
      );
      _debugLog('Firestore playlist load failed: $error');
      if (!_isDisposed && !_isDisposing) {
        notifyListeners();
      }
    }
  }

  Future<void> loadLikedSongsFromCloud() {
    return Future<void>.value();
  }

  Future<void> loadDislikedSongsFromCloud() {
    return _loadCloudSongCollection(_cloudDislikedSongIds);
  }

  Future<void> _loadCloudSongCollection(Iterable<String> songIds) {
    return _hydrateMissingCloudSongs(
      songIds: songIds,
      includeCloudPreferenceSongs: false,
    );
  }

  int pendingCloudSongCountForIds(Iterable<String> songIds) {
    int pendingCount = 0;
    for (final String songId in _normalizedUniqueSongIds(songIds)) {
      if (_canHydrateCloudSongId(songId) && songById(songId) == null) {
        pendingCount += 1;
      }
    }
    return pendingCount;
  }

  int unavailableCloudSongCountForIds(Iterable<String> songIds) {
    int unavailableCount = 0;
    for (final String songId in _normalizedUniqueSongIds(songIds)) {
      if (!_canHydrateCloudSongId(songId) && songById(songId) == null) {
        unavailableCount += 1;
      }
    }
    return unavailableCount;
  }

  Iterable<String> _normalizedUniqueSongIds(Iterable<String> songIds) sync* {
    final Set<String> seen = <String>{};
    for (final String rawSongId in songIds) {
      final String songId = rawSongId.trim();
      if (songId.isEmpty || !seen.add(songId)) {
        continue;
      }
      yield songId;
    }
  }

  void _reconcileCachedCloudStateWithCurrentUser() {
    final String? currentUserId = _firestoreUserDataService?.currentUserId;
    if (_activeCloudUserId == null && currentUserId == null) {
      return;
    }
    if (_activeCloudUserId == currentUserId) {
      return;
    }
    _clearCachedCloudStateLocally();
  }

  void _clearCachedCloudStateLocally() {
    final Set<String> affectedSongIds = <String>{
      ..._cloudLikedSongIds,
      ..._cloudDislikedSongIds,
      ..._songs
          .where((LibrarySong song) => song.isLiked || song.isDisliked)
          .map((LibrarySong song) => song.id),
      ..._transientSongsById.values
          .where((LibrarySong song) => song.isLiked || song.isDisliked)
          .map((LibrarySong song) => song.id),
    };
    _cloudLikedSongIds.clear();
    _cloudDislikedSongIds.clear();
    _cloudPlaylistSongLoadFutures.clear();
    _cloudLibraryRevision = null;
    _activeCloudUserId = null;
    _cloudUserDataLoaded = false;
    _playlists = <UserPlaylist>[];
    _applyCloudPreferenceStateToCollections(affectedSongIds);
    _markLibraryDataDirty('cached cloud state cleared');
  }

  void _refreshHomeAfterCloudDataChange() {
    if (_isDisposed || _isDisposing || _isOffline || offlineMusicMode) {
      return;
    }
    if (_homeRefreshResolvedOnce) {
      unawaited(refreshHomeFeed(force: true, preserveVisibleContent: true));
      return;
    }
    _requestStartupHomeRefresh(force: true);
  }

  Future<void> _syncLikedSongToCloud({
    required String songId,
    required bool isLiked,
  }) async {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }

    try {
      await service.setLikedSong(songId: songId, isLiked: isLiked);
    } on FirestoreUserDataException catch (error) {
      _queueCloudSyncMessage(
        '${error.message} The change was kept only on this device.',
      );
      notifyListeners();
    } catch (error) {
      _queueCloudSyncMessage(
        'Could not sync liked songs to Firestore. The change was kept only on this device.',
      );
      _debugLog('Firestore liked song sync failed: $error');
      notifyListeners();
    }
  }

  Future<void> _syncDislikedSongToCloud({
    required String songId,
    required bool isDisliked,
  }) async {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }

    try {
      await service.setDislikedSong(songId: songId, isDisliked: isDisliked);
    } on FirestoreUserDataException catch (error) {
      _queueCloudSyncMessage(
        '${error.message} The change was kept only on this device.',
      );
      notifyListeners();
    } catch (error) {
      _queueCloudSyncMessage(
        'Could not sync disliked songs to Firestore. The change was kept only on this device.',
      );
      _debugLog('Firestore disliked song sync failed: $error');
      notifyListeners();
    }
  }

  void _applyOptimisticCloudSongPreference({
    required String songId,
    required bool isLiked,
    required bool isDisliked,
    bool pruneQueue = true,
  }) {
    if (_firestoreUserDataService?.currentUserId == null) {
      return;
    }
    if (isDisliked) {
      _cloudLikedSongIds.remove(songId);
      _cloudDislikedSongIds.add(songId);
    } else if (isLiked) {
      _cloudDislikedSongIds.remove(songId);
      _cloudLikedSongIds.add(songId);
    } else {
      _cloudLikedSongIds.remove(songId);
      _cloudDislikedSongIds.remove(songId);
    }
    _applyCloudPreferenceStateToCollections(<String>{
      songId,
    }, pruneQueue: pruneQueue);
  }

  bool _matchesCloudPreferenceProfile(CloudPreferenceProfile profile) {
    return _cloudPreferenceProfile.profileVersion == profile.profileVersion &&
        _cloudPreferenceProfile.completedListenCount ==
            profile.completedListenCount &&
        _cloudPreferenceProfile.prefersRecentYears ==
            profile.prefersRecentYears &&
        _cloudPreferenceProfile.preferredYearFloor ==
            profile.preferredYearFloor &&
        _cloudPreferenceProfile.primaryLanguage == profile.primaryLanguage &&
        listEquals(
          _cloudPreferenceProfile.artistKeyOrder,
          profile.artistKeyOrder,
        ) &&
        setEquals(_cloudPreferenceProfile.artistKeys, profile.artistKeys) &&
        setEquals(_cloudPreferenceProfile.genreKeys, profile.genreKeys) &&
        setEquals(_cloudPreferenceProfile.moodKeys, profile.moodKeys) &&
        setEquals(_cloudPreferenceProfile.languageKeys, profile.languageKeys) &&
        setEquals(_cloudPreferenceProfile.yearKeys, profile.yearKeys) &&
        setEquals(
          _cloudPreferenceProfile.secondaryLanguages,
          profile.secondaryLanguages,
        ) &&
        mapEquals(_cloudPreferenceProfile.artistScores, profile.artistScores) &&
        mapEquals(_cloudPreferenceProfile.genreScores, profile.genreScores) &&
        mapEquals(_cloudPreferenceProfile.moodScores, profile.moodScores) &&
        mapEquals(
          _cloudPreferenceProfile.languageScores,
          profile.languageScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.languageConfidenceScores,
          profile.languageConfidenceScores,
        ) &&
        mapEquals(_cloudPreferenceProfile.yearScores, profile.yearScores) &&
        mapEquals(
          _cloudPreferenceProfile.avoidedArtistScores,
          profile.avoidedArtistScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.avoidedGenreScores,
          profile.avoidedGenreScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.avoidedMoodScores,
          profile.avoidedMoodScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.avoidedLanguageScores,
          profile.avoidedLanguageScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.avoidedYearScores,
          profile.avoidedYearScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.recentArtistScores,
          profile.recentArtistScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.recentGenreScores,
          profile.recentGenreScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.recentMoodScores,
          profile.recentMoodScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.recentLanguageScores,
          profile.recentLanguageScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.recentYearScores,
          profile.recentYearScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.skipArtistScores,
          profile.skipArtistScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.skipGenreScores,
          profile.skipGenreScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.skipMoodScores,
          profile.skipMoodScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.skipLanguageScores,
          profile.skipLanguageScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.skipYearScores,
          profile.skipYearScores,
        ) &&
        mapEquals(_cloudPreferenceProfile.energyScores, profile.energyScores) &&
        mapEquals(
          _cloudPreferenceProfile.sessionContextScores,
          profile.sessionContextScores,
        ) &&
        mapEquals(
          _cloudPreferenceProfile.sourceWeights,
          profile.sourceWeights,
        ) &&
        _cloudPreferenceProfile.noveltyPreference ==
            profile.noveltyPreference &&
        _cloudPreferenceProfile.popularityPreference ==
            profile.popularityPreference &&
        _cloudPreferenceProfile.repeatAffinity == profile.repeatAffinity;
  }

  void _scheduleCloudPreferenceProfileSync() {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }
    _cloudPreferenceProfileSyncTimer?.cancel();
    _cloudPreferenceProfileSyncTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_syncCloudPreferenceProfile());
    });
  }

  Future<void> _syncCloudPreferenceProfile() async {
    _cloudPreferenceProfileSyncTimer?.cancel();
    _cloudPreferenceProfileSyncTimer = null;

    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }

    final CloudPreferenceProfile profile =
        _buildCloudPreferenceProfileForSync();
    if (_matchesCloudPreferenceProfile(profile)) {
      return;
    }

    try {
      await service.savePreferenceProfile(profile: profile);
      _cloudPreferenceProfile = profile;
    } on FirestoreUserDataException catch (error) {
      if (error.isPermissionDenied) {
        _debugLog(
          'Firestore recommendation profile sync skipped after permission denial; continuing with on-device tuning only.',
        );
        return;
      }
      _queueCloudSyncMessage(
        '${error.message} Recommendation tuning stayed only on this device.',
      );
      notifyListeners();
    } catch (error) {
      _queueCloudSyncMessage(
        'Could not sync your recommendation profile to Firestore. Recommendation tuning stayed only on this device.',
      );
      _debugLog('Firestore recommendation profile sync failed: $error');
      notifyListeners();
    }
  }

  Future<void> _syncPlaylistToCloud(
    UserPlaylist playlist, {
    UserPlaylist? basePlaylist,
    bool allowConflictMerge = true,
  }) async {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }

    try {
      await service.upsertPlaylist(playlist);
      await _markPlaylistCloudSynced(playlist.id, playlist.updatedAt);
    } on FirestoreUserDataException catch (error) {
      if (error.code == 'playlist-conflict' && allowConflictMerge) {
        final UserPlaylist? remotePlaylist = await service.loadPlaylistSongs(
          playlist.id,
        );
        final UserPlaylist? latestLocal = _playlists.firstWhereOrNull(
          (UserPlaylist item) => item.id == playlist.id,
        );
        final UserPlaylist localPlaylist = latestLocal ?? playlist;
        if (remotePlaylist == null) {
          await service.upsertPlaylist(localPlaylist);
          await _markPlaylistCloudSynced(
            localPlaylist.id,
            localPlaylist.updatedAt,
          );
          return;
        }
        final UserPlaylist comparisonBase = basePlaylist ?? remotePlaylist;
        final UserPlaylist mergedPlaylist = _mergePlaylistConflict(
          base: comparisonBase,
          local: localPlaylist,
          remote: remotePlaylist,
        );
        _playlists =
            _playlists
                .map((UserPlaylist item) {
                  return item.id == mergedPlaylist.id ? mergedPlaylist : item;
                })
                .toList(growable: false)
              ..sort(_sortUserPlaylists);
        _markLibraryDataDirty('playlist conflict merged');
        await _saveSnapshot();
        if (!_isDisposed && !_isDisposing) {
          notifyListeners();
        }
        await _syncPlaylistToCloud(
          mergedPlaylist,
          basePlaylist: remotePlaylist,
          allowConflictMerge: false,
        );
        _queueCloudSyncMessage(
          'This playlist changed on another device, so the latest versions were merged before syncing.',
        );
        if (!_isDisposed && !_isDisposing) {
          notifyListeners();
        }
        return;
      }
      _queueCloudSyncMessage(
        '${error.message} The playlist change was kept only on this device.',
      );
      notifyListeners();
    } catch (error) {
      _queueCloudSyncMessage(
        'Could not sync the playlist to Firestore. The change was kept only on this device.',
      );
      _debugLog('Firestore playlist sync failed: $error');
      notifyListeners();
    }
  }

  Future<void> _deletePlaylistFromCloud(String playlistId) async {
    final FirestoreUserDataService? service = _firestoreUserDataService;
    if (service == null || service.currentUserId == null) {
      return;
    }

    try {
      await service.deletePlaylist(playlistId);
    } on FirestoreUserDataException catch (error) {
      _queueCloudSyncMessage(
        '${error.message} The playlist was removed only on this device.',
      );
      notifyListeners();
    } catch (error) {
      _queueCloudSyncMessage(
        'Could not delete the playlist from Firestore. The change was kept only on this device.',
      );
      _debugLog('Firestore playlist delete failed: $error');
      notifyListeners();
    }
  }

  void _scheduleStartupContinuation() {
    if (_startupContinuationScheduled || _isDisposed || _isDisposing) {
      return;
    }
    _startupContinuationScheduled = true;
    unawaited(_completeStartupInitialization());
  }

  Future<void> _completeStartupInitialization() async {
    try {
      AppLogger.info('Startup', 'Background startup continuation started');
      await AppLogger.timeAsync<void>(
        'Startup',
        'Create YT Music client',
        _recreateYtMusicClient,
      );
      await AppLogger.timeAsync<bool>(
        'Startup',
        'Connectivity probe',
        () => refreshConnectivityStatus(notify: false),
      );
      if (_isDisposed || _isDisposing) {
        return;
      }
      _startConnectivityMonitoring();
      notifyListeners();
      unawaited(_refillRestoredSmartQueueIfNeeded());
      if (!_snapshotLoaded || _songs.isEmpty) {
        AppLogger.info(
          'Startup',
          'No local snapshot found, starting library scan',
        );
        unawaited(rescanLibrary());
      } else if (_songs.any(_hasLegacyLocalDurationEncoding)) {
        AppLogger.info(
          'Startup',
          'Legacy local duration metadata detected, starting library rescan',
        );
        unawaited(rescanLibrary());
      } else {
        AppLogger.info(
          'Startup',
          'Skipping automatic startup scan because snapshot library is available',
        );
      }
      _requestStartupHomeRefresh();
      AppLogger.info('Startup', 'Background startup continuation queued');
    } catch (error) {
      _debugLog('Startup continuation failed: $error');
    }
  }

  Future<bool> refreshConnectivityStatus({
    bool notify = true,
    bool syncOfflineMode = true,
    bool announceLoss = false,
  }) async {
    final List<ConnectivityResult> results = await _connectivity
        .checkConnectivity();
    final bool online = await _isNetworkReachable(results);
    _setConnectivityOffline(!online, notify: false, announceLoss: announceLoss);
    if (syncOfflineMode) {
      _setStartupOfflineMode(!online, notify: false);
    }
    if (notify) {
      notifyListeners();
    }
    return online;
  }

  void _startConnectivityMonitoring() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      unawaited(_handleConnectivityChange(results));
    });
  }

  Future<void> _handleConnectivityChange(
    List<ConnectivityResult> results,
  ) async {
    final bool online = await _isNetworkReachable(results);
    final bool wasOffline = _isOffline;
    _setConnectivityOffline(!online, notify: false, announceLoss: true);
    if (!online) {
      _onlineLoading = false;
      _trendingNowLoading = false;
      _onlineError = 'Internet is unavailable right now.';
      _trendingNowError = 'No internet connection.';
      if (_homeFeed.isEmpty) {
        _homeError = 'No internet connection. Reconnect and tap Refresh.';
      }
      final LibrarySong? activeSong = currentSong;
      if (activeSong != null &&
          activeSong.isRemote &&
          offlinePlaybackCacheEnabled &&
          _queueSongIds.isNotEmpty) {
        _debugPlayback(
          'connectivity.offline keeping queue flow simple '
          'current=${_debugSongLabel(activeSong)} '
          'positionMs=${_position.inMilliseconds} '
          'queueIndex=$_queueIndex',
        );
      }
      notifyListeners();
      return;
    }
    _setStartupOfflineMode(false, notify: false);
    if (_offlineQueueWaitingSongId != null) {
      unawaited(_resumeOfflineWaitingQueue());
    }
    unawaited(_refreshOfflinePlaybackCache(anchor: currentSong));
    notifyListeners();
    if (_initialized &&
        wasOffline &&
        _homeFeed.isEmpty &&
        !_homeLoading &&
        !offlineMusicMode) {
      _requestStartupHomeRefresh(force: true);
    }
  }

  Future<bool> _resolveOfflineStateForAction() async {
    if (!_isOffline || _startupOfflineMode || offlineMusicMode) {
      return _isOffline;
    }
    final bool online = await refreshConnectivityStatus(
      notify: false,
      syncOfflineMode: false,
    );
    return !online;
  }

  bool _isNearTrackEndForQueueAdvance(
    LibrarySong song, {
    bool allowStoppedPlayback = false,
  }) {
    final bool detachedResolvedTrack =
        _offlineDetachedQueueMode && songNeedsResolvedPlaybackUrl(song);
    final int measuredDurationMs = _duration.inMilliseconds;
    if (detachedResolvedTrack) {
      if (measuredDurationMs <= 0) {
        return false;
      }
      final int remainingMs = measuredDurationMs - _position.inMilliseconds;
      final int remainingSlackMs = allowStoppedPlayback ? 1200 : 450;
      return remainingMs <= remainingSlackMs;
    }
    final List<int> knownDurationsMs = <int>[
      song.durationMs,
      measuredDurationMs,
    ].where((int value) => value > 0).toList(growable: false);
    final int durationMs = knownDurationsMs.isEmpty
        ? 0
        : allowStoppedPlayback
        ? knownDurationsMs.reduce(math.min)
        : knownDurationsMs.reduce(math.max);
    final double completionThreshold = allowStoppedPlayback ? 0.94 : 0.985;
    if (durationMs <= 0) {
      return _activePlaybackCompletionRatio >= completionThreshold;
    }
    final int remainingMs = durationMs - _position.inMilliseconds;
    final int remainingSlackMs = allowStoppedPlayback ? 3500 : 1500;
    return remainingMs <= remainingSlackMs ||
        _activePlaybackCompletionRatio >= completionThreshold;
  }

  bool _shouldAutoAdvanceQueueAtTrackEnd({
    bool requireCompletedState = false,
    bool allowStoppedPlayback = false,
  }) {
    final bool requiresManualQueueAdvance =
        _isOffline ||
        _offlineDetachedQueueMode ||
        !_playerQueueHasControllerPlaylist();
    if (_offlineQueueAdvancePending ||
        _queueNavigationInFlight ||
        offlineMusicMode ||
        _offlineQueueWaitingSongId != null ||
        _offlineQueueActivationTargetSongId != null ||
        _transitioningSongId != null ||
        _playbackFallbackRecoverySongId != null ||
        !requiresManualQueueAdvance) {
      return false;
    }
    final LibrarySong? song = currentSong;
    if (song == null) {
      return false;
    }
    if (_nextQueueIndex(respectSingleRepeat: false) == null) {
      return false;
    }
    if (requireCompletedState) {
      return true;
    }
    if (!_isPlaying && !allowStoppedPlayback) {
      return false;
    }
    if (!allowStoppedPlayback &&
        _offlineDetachedQueueMode &&
        songNeedsResolvedPlaybackUrl(song) &&
        !_player.state.completed) {
      return false;
    }
    return _isNearTrackEndForQueueAdvance(
      song,
      allowStoppedPlayback: allowStoppedPlayback,
    );
  }

  bool _shouldForceAdvanceAfterUnexpectedPlaybackStop() {
    if (_pauseRequestedByUser) {
      return false;
    }
    return _shouldAutoAdvanceQueueAtTrackEnd(
      requireCompletedState: true,
      allowStoppedPlayback: true,
    );
  }

  void _requestQueueAdvanceAtTrackEnd(
    String reason, {
    bool allowStoppedPlayback = false,
    bool force = false,
  }) {
    if (!force &&
        !_shouldAutoAdvanceQueueAtTrackEnd(
          requireCompletedState: reason == 'completed',
          allowStoppedPlayback: allowStoppedPlayback,
        )) {
      return;
    }
    if (_repeatMode == PlaylistMode.single) {
      _offlineQueueAdvancePending = true;
      unawaited(() async {
        try {
          await _reopenQueueAtIndex(_queueIndex, forcePlay: true);
        } finally {
          _offlineQueueAdvancePending = false;
        }
      }());
      return;
    }
    final int? targetIndex = _nextQueueIndex(respectSingleRepeat: false);
    if (targetIndex == null) {
      return;
    }
    _offlineQueueAdvancePending = true;
    _debugPlayback(
      'queue.autoAdvance reason=$reason '
      'currentIndex=$_queueIndex targetIndex=$targetIndex '
      'completed=${_player.state.completed} playing=$_isPlaying '
      'detached=$_offlineDetachedQueueMode',
    );
    unawaited(() async {
      try {
        await nextTrack(forcePlay: true);
      } finally {
        _offlineQueueAdvancePending = false;
      }
    }());
  }

  void _maybeAdvanceOfflineQueueAtTrackEnd() {
    _maybeAutoDownloadCurrentPlaybackAtEnd();
    _requestQueueAdvanceAtTrackEnd('position');
  }

  void _handleCompletedPlaybackEvent(bool completed) {
    if (!completed || _isDisposing || _isDisposed) {
      return;
    }
    _maybeAutoDownloadCompletedPlayback();
    _requestQueueAdvanceAtTrackEnd('completed');
  }

  void _maybeAutoDownloadCompletedPlayback() {
    _activePlaybackCompletionRatio = math.max(
      _activePlaybackCompletionRatio,
      1,
    );
    final String? songId = _activePlaybackSongId ?? currentSong?.id;
    if (songId == null) {
      return;
    }
    _completedPlaybackSaveEligibleSongIds.add(songId);
    final String? pendingPath = _pendingCompletedPlaybackCachePaths.remove(
      songId,
    );
    if (pendingPath != null) {
      _finalizeCompletedPlaybackCacheSave(
        songId: songId,
        cachedFilePath: pendingPath,
      );
    }
  }

  void _maybeAutoDownloadCurrentPlaybackAtEnd() {
    return;
  }

  void _requestStartupHomeRefresh({bool force = false}) {
    final DateTime now = DateTime.now();
    if (_homeLoading || _homeStartupRefreshConsumed) {
      return;
    }
    if (_lastAutoHomeRefreshAt != null &&
        now.difference(_lastAutoHomeRefreshAt!) <
            const Duration(milliseconds: 1500)) {
      return;
    }
    _homeStartupRefreshConsumed = true;
    _lastAutoHomeRefreshAt = now;
    unawaited(refreshHomeFeed(force: force));
  }

  Future<bool> _isNetworkReachable(List<ConnectivityResult> results) async {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return false;
    }
    try {
      final List<InternetAddress> lookup = await InternetAddress.lookup(
        'youtube.com',
      ).timeout(const Duration(milliseconds: 1200));
      return lookup.isNotEmpty && lookup.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return true;
    }
  }

  Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    final PermissionStatus status = await Permission.notification.status;
    if (status.isGranted || status.isLimited) {
      return;
    }
    await Permission.notification.request();
  }

  Future<void> ensureNotificationPermissionIfNeeded() async {
    await _ensureNotificationPermission();
  }

  Future<void> _ensureLibraryAccessPermissionIfNeeded() async {
    if (!Platform.isAndroid) {
      return;
    }
    final List<Permission> permissions = <Permission>[
      Permission.audio,
      Permission.storage,
    ];
    for (final Permission permission in permissions) {
      final PermissionStatus status = await permission.status;
      if (status.isGranted || status.isLimited) {
        return;
      }
    }
    for (final Permission permission in permissions) {
      await permission.request();
    }
  }

  Future<void> searchOnline(String query) async {
    final int requestId = ++_onlineSearchRequestId;
    final String trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      registerUserActivity(reason: 'search-online', notify: false);
    }
    if (trimmed.isEmpty) {
      _onlineResults = <LibrarySong>[];
      _onlineError = null;
      _onlineLoading = false;
      _onlineQuery = '';
      _onlineResultLimit = 0;
      _onlineHasMore = false;
      notifyListeners();
      return;
    }

    final bool offline = await _resolveOfflineStateForAction();
    if (offline) {
      _onlineResults = <LibrarySong>[];
      _onlineError = 'Internet is unavailable right now.';
      _onlineLoading = false;
      _onlineQuery = trimmed;
      _onlineResultLimit = 0;
      _onlineHasMore = false;
      notifyListeners();
      return;
    }

    if (offlineMusicMode) {
      _onlineResults = <LibrarySong>[];
      _onlineError = 'Offline Music mode is on.';
      _onlineLoading = false;
      _onlineQuery = trimmed;
      _onlineResultLimit = 0;
      _onlineHasMore = false;
      notifyListeners();
      return;
    }

    await _performOnlineSearch(trimmed, limit: 20, requestId: requestId);
  }

  Future<void> loadMoreOnlineResults() async {
    if (_onlineLoading || _onlineQuery.isEmpty || !_onlineHasMore) {
      return;
    }
    await _performOnlineSearch(
      _onlineQuery,
      limit: _onlineResultLimit + 20,
      requestId: _onlineSearchRequestId,
      appendResults: true,
    );
  }

  Future<void> _performOnlineSearch(
    String query, {
    required int limit,
    required int requestId,
    bool appendResults = false,
  }) async {
    _onlineLoading = true;
    _onlineError = null;
    _onlineQuery = query;
    notifyListeners();

    try {
      final List<LibrarySong> results = await _searchSongs(
        query,
        limit: limit,
        force: true,
        usageBucket: _AppNetworkUsageBucket.search,
      );
      if (requestId != _onlineSearchRequestId) {
        return;
      }
      _onlineResults = appendResults
          ? _appendUniqueSearchResults(_onlineResults, results)
          : results;
      _onlineResultLimit = limit;
      _onlineHasMore = results.length >= limit;
      if (_onlineResults.isEmpty) {
        _onlineError = 'No online songs found right now.';
      }
    } catch (error) {
      if (requestId != _onlineSearchRequestId) {
        return;
      }
      _onlineError = _friendlyOnlineError(error);
      if (!appendResults) {
        _onlineResults = <LibrarySong>[];
        _onlineResultLimit = 0;
        _onlineHasMore = false;
      }
    } finally {
      if (requestId == _onlineSearchRequestId) {
        _onlineLoading = false;
        notifyListeners();
      }
    }
  }

  void clearOnlineResults() {
    _onlineResults = <LibrarySong>[];
    _onlineError = null;
    _onlineLoading = false;
    _onlineQuery = '';
    _onlineResultLimit = 0;
    _onlineHasMore = false;
    notifyListeners();
  }

  List<LibrarySong> _appendUniqueSearchResults(
    List<LibrarySong> existing,
    List<LibrarySong> incoming,
  ) {
    if (existing.isEmpty) {
      return incoming;
    }

    final List<LibrarySong> merged = List<LibrarySong>.from(existing);
    final Set<String> seen = existing
        .map(_onlineSearchResultIdentityKey)
        .toSet();
    for (final LibrarySong song in incoming) {
      if (seen.add(_onlineSearchResultIdentityKey(song))) {
        merged.add(song);
      }
    }
    return merged;
  }

  String _onlineSearchResultIdentityKey(LibrarySong song) {
    String normalize(String value) {
      return value
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\([^)]*\)'), ' ')
          .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
          .replaceAll(RegExp(r'[^\w\s]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    final String id = song.id.trim().toLowerCase();
    if (id.isNotEmpty) {
      return id;
    }
    return '${normalize(song.artist)}::${normalize(song.title)}';
  }

  Future<void> loadTrendingNow({
    required String languageCode,
    String? countryCode,
    bool force = false,
  }) async {
    if (offlineMusicMode) {
      _trendingNowSongs = <LibrarySong>[];
      _trendingNowLoading = false;
      _trendingNowError = 'Offline Music mode is on.';
      notifyListeners();
      return;
    }
    final int requestId = ++_trendingNowRequestId;
    final String normalizedLanguage = languageCode.trim().toLowerCase();
    final String normalizedCountry =
        ((countryCode ?? '').trim().isEmpty ? 'LK' : countryCode!)
            .trim()
            .toUpperCase();
    final String languageToken = _localeLanguageQueryToken(normalizedLanguage);
    final String regionLabel = _regionLabelFromCountryCode(normalizedCountry);

    if (_trendingNowSongs.isNotEmpty &&
        !force &&
        !_trendingNowLoading &&
        _trendingNowRegionLabel == regionLabel) {
      return;
    }

    _trendingNowLoading = true;
    _trendingNowError = null;
    _trendingNowRegionLabel = regionLabel;
    notifyListeners();

    try {
      final List<String> queries = <String>[
        if (normalizedCountry.isNotEmpty)
          '$languageToken top songs in $regionLabel last month',
        if (normalizedCountry.isNotEmpty)
          'youtube music trending in $regionLabel last month',
        if (normalizedCountry == 'LK')
          'sinhala trending songs sri lanka last month',
        if (normalizedCountry == 'LK')
          'tamil trending songs sri lanka last month',
        '$languageToken viral songs last month',
        'youtube music charts $languageToken',
        'most popular songs last month',
      ];

      final List<LibrarySong> candidates = <LibrarySong>[];
      for (int index = 0; index < queries.length; index += 1) {
        final List<LibrarySong> results = await _searchSongs(
          queries[index],
          limit: 24,
          force: force || index > 0,
          usageBucket: _AppNetworkUsageBucket.load,
        );
        candidates.addAll(results);
      }

      if (requestId != _trendingNowRequestId) {
        return;
      }

      _trendingNowSongs = _rankTrendingNowCandidates(
        candidates,
        languageCode: normalizedLanguage,
        countryCode: normalizedCountry,
        limit: 18,
      );
      if (_trendingNowSongs.isEmpty) {
        _trendingNowError = 'Trending songs are unavailable right now.';
      }
    } catch (error) {
      if (requestId != _trendingNowRequestId) {
        return;
      }
      _trendingNowError = _friendlyOnlineError(error);
      _trendingNowSongs = <LibrarySong>[];
    } finally {
      if (requestId == _trendingNowRequestId) {
        _trendingNowLoading = false;
        notifyListeners();
      }
    }
  }

  static const double _ytMusicPrimaryRatio = 0.8;
  static const double _youtubeFallbackRatio = 0.1;

  Future<void> _recreateYtMusicClient() async {
    _ytMusic?.close();
    final String? auth = _settings.ytMusicAuthJson?.trim();
    try {
      _ytMusic = await YTMusic.create(
        auth: auth == null || auth.isEmpty ? null : auth,
      );
      _ytMusicAuthError = null;
    } catch (error) {
      _ytMusicAuthError = '$error';
      _ytMusic = await YTMusic.create();
    }
  }

  Future<void> refreshHomeFeed({
    bool force = false,
    bool preserveVisibleContent = false,
  }) async {
    if (_homeLoading) {
      return;
    }

    _homeLoading = true;
    _homeError = null;
    _bumpHomeStateRevision();
    notifyListeners();

    try {
      if (offlineMusicMode) {
        _homeFeed = <HomeFeedSection>[];
        _bumpHomeStateRevision();
        _personalizedHomeRecommendations = <SongRecommendation>[];
        _homeError = 'Offline Music mode is on.';
        return;
      }
      final bool online = await refreshConnectivityStatus(
        notify: false,
        syncOfflineMode: false,
        announceLoss: true,
      );
      if (!online) {
        _homeError = 'No internet connection. Reconnect and tap Refresh.';
        return;
      }
      unawaited(
        loadTrendingNow(
          languageCode: preferredLanguageCode,
          countryCode: preferredCountryCode,
          force: force,
        ),
      );
      final List<HomeFeedSection> previousFeed = List<HomeFeedSection>.from(
        _homeFeed,
      );
      final List<SongRecommendation> previousPersonalized =
          List<SongRecommendation>.from(_personalizedHomeRecommendations);
      if (!preserveVisibleContent) {
        _homeFeed = <HomeFeedSection>[];
        _personalizedHomeRecommendations = <SongRecommendation>[];
        notifyListeners();
      }
      final LibrarySong? seedSong = _primaryRecommendationSeed();
      final List<HomeFeedSection> sections = <HomeFeedSection>[];
      final Set<String> consumedIds = <String>{};
      final Set<String> consumedKeys = <String>{};
      Object? firstRecommendationError;

      void rememberRecommendationError(String source, Object error) {
        firstRecommendationError ??= error;
        _recordHomeRecommendationError(source: source, error: error);
      }

      if (seedSong != null) {
        try {
          final HomeFeedSection? radioSection = await _buildYtMusicRadioSection(
            seedSong,
            excludedIds: consumedIds,
          );
          if (radioSection != null) {
            sections.add(radioSection);
            consumedIds.addAll(
              radioSection.songs.take(4).map((LibrarySong song) => song.id),
            );
            consumedKeys.addAll(
              radioSection.songs
                  .take(8)
                  .map((LibrarySong song) => _songIdentityKey(song)),
            );
            _commitHomeFeedSections(
              List<HomeFeedSection>.from(sections),
              seedSong: seedSong,
            );
          }
        } catch (error) {
          rememberRecommendationError('radio for ${seedSong.title}', error);
        }
      }

      _homeQueryCursor = 0;
      _homeConsumedIds
        ..clear()
        ..addAll(consumedIds);
      _homeConsumedIdentityKeys
        ..clear()
        ..addAll(consumedKeys);

      final List<HomeFeedSection> expanded = await _loadMoreHomeSections(
        seedSong: seedSong,
        force: force,
        already: sections,
        desiredCount: 6,
        onRecommendationError: rememberRecommendationError,
        onSectionsChanged: (List<HomeFeedSection> updated) {
          _commitHomeFeedSections(updated, seedSong: seedSong);
        },
      );
      _commitHomeFeedSections(expanded, seedSong: seedSong);

      if (_homeFeed.isEmpty && _personalizedHomeRecommendations.isEmpty) {
        _homeFeed = previousFeed;
        _personalizedHomeRecommendations = previousPersonalized;
        final Object? recommendationError = firstRecommendationError;
        _homeError = recommendationError != null
            ? _friendlyOnlineError(recommendationError)
            : previousFeed.isEmpty
            ? 'No recommendations available right now.'
            : 'Recommendations could not be refreshed right now.';
      }
    } catch (error) {
      _recordHomeRecommendationError(source: 'home refresh', error: error);
      if (_isConnectivityError(error) && !_isTimeoutError(error)) {
        _setConnectivityOffline(true, notify: false, announceLoss: true);
      }
      _homeError = _friendlyOnlineError(error);
    } finally {
      _homeRefreshResolvedOnce = true;
      _homeLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreHomeFeed({int desiredTotal = 10}) async {
    if (_homeLoading) {
      return;
    }
    if (offlineMusicMode) {
      return;
    }
    if (await _resolveOfflineStateForAction()) {
      return;
    }
    if (_homeFeed.isEmpty) {
      return;
    }

    _homeLoading = true;
    _homeError = null;
    notifyListeners();

    Object? firstRecommendationError;

    void rememberRecommendationError(String source, Object error) {
      firstRecommendationError ??= error;
      _recordHomeRecommendationError(source: source, error: error);
    }

    try {
      final LibrarySong? seedSong = _primaryRecommendationSeed();
      final int previousSectionCount = _homeFeed.length;
      final List<HomeFeedSection> expanded = await _loadMoreHomeSections(
        seedSong: seedSong,
        force: false,
        already: List<HomeFeedSection>.from(_homeFeed),
        desiredCount: desiredTotal,
        onRecommendationError: rememberRecommendationError,
      );
      _commitHomeFeedSections(
        expanded,
        seedSong: seedSong,
        preservePersonalized: true,
      );
      final Object? recommendationError = firstRecommendationError;
      if (recommendationError != null &&
          expanded.length <= previousSectionCount) {
        _homeError = _friendlyOnlineError(recommendationError);
      }
    } catch (error) {
      _recordHomeRecommendationError(source: 'home pagination', error: error);
      _homeError = _friendlyOnlineError(error);
    } finally {
      _homeLoading = false;
      notifyListeners();
    }
  }

  Future<List<HomeFeedSection>> _loadMoreHomeSections({
    required LibrarySong? seedSong,
    required bool force,
    required List<HomeFeedSection> already,
    required int desiredCount,
    void Function(String source, Object error)? onRecommendationError,
    void Function(List<HomeFeedSection> sections)? onSectionsChanged,
  }) async {
    final List<HomeFeedSection> sections = already;
    if (sections.length >= desiredCount) {
      return sections;
    }

    final List<_RecommendationQuery> queries = _orderedHomeQueries(seedSong);
    if (queries.isEmpty) {
      return sections;
    }

    int cursor = _homeQueryCursor;
    bool recycledQueries = cursor >= queries.length;
    cursor = cursor % queries.length;
    int attempts = 0;
    final int maxAttempts = queries.length * 2;

    while (sections.length < desiredCount && attempts < maxAttempts) {
      final _RecommendationQuery query = queries[cursor];
      attempts += 1;
      cursor += 1;
      if (cursor >= queries.length) {
        cursor = 0;
        recycledQueries = true;
      }

      final List<LibrarySong> rawResults;
      try {
        rawResults = await _searchSongs(
          query.query,
          limit: 22,
          force: force || recycledQueries,
          usageBucket: _AppNetworkUsageBucket.load,
        );
      } catch (error) {
        final String source = 'query "${query.query}"';
        if (onRecommendationError != null) {
          onRecommendationError(source, error);
        } else {
          _recordHomeRecommendationError(source: source, error: error);
        }
        continue;
      }
      final List<LibrarySong> ranked = _rankRecommendedSongs(
        rawResults,
        anchor: query.anchor ?? seedSong,
        excludedIds: _homeConsumedIds,
        limit: 14,
      );

      final List<LibrarySong> filtered = <LibrarySong>[
        for (final LibrarySong song in ranked)
          if (_homeConsumedIdentityKeys.add(_songIdentityKey(song)))
            if (_homeConsumedIds.add(song.id)) song,
      ];

      if (filtered.length < 4) {
        continue;
      }

      sections.add(
        HomeFeedSection(
          title: query.title,
          subtitle: query.subtitle,
          query: query.query,
          songs: filtered.take(50).toList(growable: false),
        ),
      );
      onSectionsChanged?.call(List<HomeFeedSection>.unmodifiable(sections));
    }

    _homeQueryCursor = recycledQueries ? cursor + queries.length : cursor;
    return sections;
  }

  List<_RecommendationQuery> _orderedHomeQueries(LibrarySong? seedSong) {
    final List<_RecommendationQuery> queries = List<_RecommendationQuery>.from(
      _buildHomeQueries(seedSong),
    );
    queries.sort((_RecommendationQuery a, _RecommendationQuery b) {
      final int priorityCompare = _homeQueryPriority(
        a,
      ).compareTo(_homeQueryPriority(b));
      if (priorityCompare != 0) {
        return priorityCompare;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return queries;
  }

  int _homeQueryPriority(_RecommendationQuery query) {
    final String title = query.title.trim().toLowerCase();
    if (title.startsWith('from your liked')) {
      return 0;
    }
    if (title.startsWith('because you played') ||
        title.startsWith('because you finished')) {
      return 1;
    }
    if (title.startsWith('more from ')) {
      return 2;
    }
    return 3;
  }

  void _commitHomeFeedSections(
    List<HomeFeedSection> sections, {
    required LibrarySong? seedSong,
    bool preservePersonalized = false,
  }) {
    _bumpHomeStateRevision();
    _homeFeed = _filterHomeFeedSectionsForBrowsing(sections);
    if (!preservePersonalized || _personalizedHomeRecommendations.isEmpty) {
      final List<SongRecommendation> nextRecommendations =
          _buildPersonalizedHomeSongs(sections: _homeFeed, seedSong: seedSong);
      _personalizedHomeRecommendations = _mergeStableHomeRecommendations(
        existing: _personalizedHomeRecommendations,
        incoming: nextRecommendations,
      );
    }
    notifyListeners();
  }

  List<SongRecommendation> _mergeStableHomeRecommendations({
    required List<SongRecommendation> existing,
    required List<SongRecommendation> incoming,
    int limit = 50,
  }) {
    final List<SongRecommendation> safeExisting = existing
        .where(
          (SongRecommendation item) =>
              _shouldUseSongInHomeOrSmartQueue(item.song),
        )
        .toList(growable: false);
    final List<SongRecommendation> safeIncoming = incoming
        .where(
          (SongRecommendation item) =>
              _shouldUseSongInHomeOrSmartQueue(item.song),
        )
        .toList(growable: false);
    if (existing.isEmpty) {
      return safeIncoming.take(limit).toList(growable: false);
    }

    final List<SongRecommendation> merged = <SongRecommendation>[
      ...safeExisting.take(limit),
    ];
    final Set<String> seenKeys = merged
        .map((SongRecommendation item) => _songIdentityKey(item.song))
        .toSet();
    final Set<String> seenIds = merged
        .map((SongRecommendation item) => item.song.id)
        .toSet();

    for (final SongRecommendation item in safeIncoming) {
      if (merged.length >= limit) {
        break;
      }
      final String key = _songIdentityKey(item.song);
      if (!seenKeys.add(key) || !seenIds.add(item.song.id)) {
        continue;
      }
      merged.add(item);
    }

    return List<SongRecommendation>.unmodifiable(merged);
  }

  Future<List<LibrarySong>> _searchSongs(
    String query, {
    int limit = 12,
    bool force = false,
    required _AppNetworkUsageBucket usageBucket,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return <LibrarySong>[];
    }

    final String cacheKey = trimmed.toLowerCase();
    if (!force && _searchCache.containsKey(cacheKey)) {
      return _searchCache[cacheKey]!;
    }

    final LibrarySong? directUrlSong = await _resolveSongFromUrlInput(trimmed);
    if (directUrlSong != null) {
      final List<LibrarySong> directResults = <LibrarySong>[directUrlSong];
      _searchCache[cacheKey] = directResults;
      _rememberTransientSong(directUrlSong);
      return directResults;
    }

    try {
      final List<LibrarySong> songs = await _searchOnlineMusic(
        trimmed,
        limit: limit,
        force: force,
        usageBucket: usageBucket,
      );
      _searchCache[cacheKey] = songs;
      return songs;
    } catch (error) {
      if (_isConnectivityError(error)) {
        _setConnectivityOffline(true, notify: false, announceLoss: true);
      }
      try {
        final List<LibrarySong> fallback = await _searchYouTubeMusicOnly(
          trimmed,
          limit: limit,
          force: force,
          usageBucket: usageBucket,
        );
        _searchCache[cacheKey] = fallback;
        return fallback;
      } catch (fallbackError) {
        if (_isConnectivityError(fallbackError)) {
          _setConnectivityOffline(true, notify: false, announceLoss: true);
        }
        rethrow;
      }
    }
  }

  Future<List<LibrarySong>> _searchOnlineMusic(
    String query, {
    int limit = 12,
    bool force = false,
    required _AppNetworkUsageBucket usageBucket,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty || limit <= 0) {
      return <LibrarySong>[];
    }

    final int ytMusicTarget = math.max(
      1,
      math.min(limit, (limit * _ytMusicPrimaryRatio).round()),
    );
    final int youtubeTarget = math.min(
      math.max(0, (limit * _youtubeFallbackRatio).ceil()),
      math.max(0, limit - ytMusicTarget),
    );

    final List<LibrarySong> ytMusicSongs = await _searchYouTubeMusicOnly(
      trimmed,
      limit: math.max(limit, ytMusicTarget + 4),
      force: force,
      usageBucket: usageBucket,
    );

    final List<LibrarySong> youtubeSongs = ytMusicSongs.length >= limit
        ? <LibrarySong>[]
        : await _searchYouTubeFallbackOnly(
            trimmed,
            limit: math.max(youtubeTarget + 4, limit ~/ 2),
            force: force,
            usageBucket: usageBucket,
          );

    final List<LibrarySong> blended = _blendOnlineResults(
      query: trimmed,
      ytMusicSongs: ytMusicSongs,
      youtubeSongs: youtubeSongs,
      limit: limit,
      preferredYtMusicCount: ytMusicTarget,
      preferredYoutubeCount: youtubeTarget,
    );

    for (final LibrarySong song in blended) {
      _rememberTransientSong(song);
    }
    return blended;
  }

  Future<List<LibrarySong>> _searchYouTubeMusicOnly(
    String query, {
    int limit = 12,
    bool force = false,
    required _AppNetworkUsageBucket usageBucket,
  }) async {
    final YTMusic? client = _ytMusic;
    final String trimmed = query.trim();
    if (client == null || trimmed.isEmpty) {
      return <LibrarySong>[];
    }

    final String cacheKey = trimmed.toLowerCase();
    if (!force && _ytMusicSearchCache.containsKey(cacheKey)) {
      return _ytMusicSearchCache[cacheKey]!;
    }

    try {
      final List<dynamic> songResults = await client.search(
        trimmed,
        filter: ytm.SearchFilter.songs,
        limit: math.max(limit, 8),
      );
      final List<LibrarySong> songs = songResults
          .map((dynamic item) => _ytMusicItemToSong(item, query: trimmed))
          .whereType<LibrarySong>()
          .where(_looksLikeMusic)
          .toList(growable: false);

      if (songs.isEmpty) {
        final List<dynamic> videoResults = await client.search(
          trimmed,
          filter: ytm.SearchFilter.videos,
          limit: math.max(limit, 8),
        );
        _ytMusicSearchCache[cacheKey] = videoResults
            .map((dynamic item) => _ytMusicItemToSong(item, query: trimmed))
            .whereType<LibrarySong>()
            .where(_looksLikeMusic)
            .toList(growable: false);
      } else {
        _ytMusicSearchCache[cacheKey] = songs;
      }
    } catch (error) {
      _debugLog('YTMusic search failed for "$trimmed": $error');
      _ytMusicSearchCache[cacheKey] = <LibrarySong>[];
    }

    _ytMusicSearchCache[cacheKey] = _rankOnlineSearchMatches(
      _ytMusicSearchCache[cacheKey]!,
      query: trimmed,
      limit: limit,
    );

    for (final LibrarySong song in _ytMusicSearchCache[cacheKey]!) {
      _rememberTransientSong(song);
    }
    return _ytMusicSearchCache[cacheKey]!;
  }

  Future<List<LibrarySong>> _searchYouTubeFallbackOnly(
    String query, {
    int limit = 12,
    bool force = false,
    required _AppNetworkUsageBucket usageBucket,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty || limit <= 0) {
      return <LibrarySong>[];
    }

    final String cacheKey = 'yt::$trimmed'.toLowerCase();
    if (!force && _searchCache.containsKey(cacheKey)) {
      return _searchCache[cacheKey]!;
    }

    try {
      final VideoSearchList results = await _yt.search.search(
        '$trimmed audio official music',
      );
      final List<LibrarySong> songs = results
          .map(_videoToSong)
          .where(_looksLikeMusic)
          .toList(growable: false);
      final List<LibrarySong> ranked = _rankOnlineSearchMatches(
        songs,
        query: trimmed,
        limit: limit,
      );
      for (final LibrarySong song in ranked) {
        _rememberTransientSong(song);
      }
      _searchCache[cacheKey] = ranked;
      return ranked;
    } catch (error) {
      _debugLog('YouTube fallback search failed for "$trimmed": $error');
      _searchCache[cacheKey] = <LibrarySong>[];
      return <LibrarySong>[];
    }
  }

  List<LibrarySong> _blendOnlineResults({
    required String query,
    required List<LibrarySong> ytMusicSongs,
    required List<LibrarySong> youtubeSongs,
    required int limit,
    required int preferredYtMusicCount,
    required int preferredYoutubeCount,
  }) {
    final Set<String> excludedIds = <String>{};
    final List<LibrarySong> result = <LibrarySong>[];

    void addFrom(List<LibrarySong> songs, int target) {
      for (final LibrarySong song in songs) {
        if (result.length >= limit || target <= 0) {
          break;
        }
        if (excludedIds.add(song.id) &&
            result.every((LibrarySong item) => !_sameSong(item, song))) {
          result.add(song);
          target -= 1;
        }
      }
    }

    addFrom(
      _rankOnlineSearchMatches(
        ytMusicSongs,
        query: query,
        limit: ytMusicSongs.length,
      ),
      preferredYtMusicCount,
    );
    addFrom(
      _rankOnlineSearchMatches(
        youtubeSongs,
        query: query,
        limit: youtubeSongs.length,
      ),
      preferredYoutubeCount,
    );
    addFrom(
      _rankOnlineSearchMatches(
        ytMusicSongs,
        query: query,
        limit: ytMusicSongs.length,
      ),
      limit,
    );
    addFrom(
      _rankOnlineSearchMatches(
        youtubeSongs,
        query: query,
        limit: youtubeSongs.length,
      ),
      limit,
    );

    return result.take(limit).toList(growable: false);
  }

  Future<List<LibrarySong>> _searchYtMusicSongs(
    String query, {
    int limit = 12,
    bool force = false,
    _AppNetworkUsageBucket usageBucket = _AppNetworkUsageBucket.metadata,
  }) async {
    return _searchYouTubeMusicOnly(
      query,
      limit: limit,
      force: force,
      usageBucket: usageBucket,
    );
  }

  Future<HomeFeedSection?> _buildYtMusicRadioSection(
    LibrarySong anchor, {
    required Set<String> excludedIds,
  }) async {
    final List<LibrarySong> songs = await _ytMusicRadioSongs(anchor, limit: 10);
    final List<LibrarySong> filtered = _dedupeSongs(
      songs,
      excludedIds: excludedIds,
      limit: 10,
    );
    if (filtered.length < 4) {
      return null;
    }
    return HomeFeedSection(
      title: 'Inspired by ${anchor.title}',
      subtitle: 'Built from your recent listening and full-listen history',
      query: '${anchor.artist} ${anchor.title} radio',
      songs: filtered,
    );
  }

  void _recordHomeRecommendationError({
    required String source,
    required Object error,
  }) {
    _debugLog('Home recommendation $source failed: $error');
    if (_isConnectivityError(error) && !_isTimeoutError(error)) {
      _setConnectivityOffline(true, notify: false, announceLoss: true);
    }
  }

  bool _isTimeoutError(Object error) {
    final String message = '$error'.toLowerCase();
    return error is TimeoutException ||
        message.contains('timed out') ||
        message.contains('timeout');
  }

  String _friendlyOnlineError(Object error) {
    final String message = '$error'.toLowerCase();
    if (_isTimeoutError(error)) {
      return 'Online recommendations took too long to respond. Pull to refresh and try again.';
    }
    if (_isConnectivityError(error)) {
      return 'No internet connection. Reconnect and refresh to load online recommendations.';
    }
    if (message.contains('redirect limit exceeded') ||
        message.contains('google_abuse_exemption') ||
        message.contains('clientexception') ||
        message.contains('too many requests') ||
        message.contains('rate limit') ||
        message.contains('quota') ||
        message.contains('status code: 403') ||
        message.contains('status code: 429')) {
      return 'Online recommendations are temporarily limited. The app will retry automatically.';
    }
    if (message.contains('format') ||
        message.contains('type ') ||
        message.contains('unexpected')) {
      return 'Online recommendations returned an unexpected response. Pull to refresh and try again.';
    }
    return 'Online recommendations could not be loaded right now. Pull to refresh or try again shortly.';
  }

  Future<List<LibrarySong>> _ytMusicRadioSongs(
    LibrarySong anchor, {
    int limit = 10,
  }) async {
    final YTMusic? client = _ytMusic;
    if (client == null) {
      return <LibrarySong>[];
    }

    final String? videoId = await _resolveYtMusicVideoId(anchor);
    if (videoId == null) {
      return <LibrarySong>[];
    }

    final Map<String, dynamic> response = await client
        .getWatchPlaylist(videoId: videoId, radio: true, limit: limit + 4)
        .timeout(const Duration(seconds: 8));
    final List<dynamic> tracks =
        response['tracks'] as List<dynamic>? ?? <dynamic>[];
    final List<LibrarySong> songs = tracks
        .map((dynamic item) => _ytMusicItemToSong(item))
        .whereType<LibrarySong>()
        .where((LibrarySong song) => !_sameSong(song, anchor))
        .toList(growable: false);
    for (final LibrarySong song in songs) {
      _rememberTransientSong(song);
    }
    return songs.take(limit).toList(growable: false);
  }

  Future<String?> _resolveYtMusicVideoId(LibrarySong song) async {
    final String cacheKey = _songIdentityKey(song);
    if (_ytMusicVideoIdCache.containsKey(cacheKey)) {
      return _ytMusicVideoIdCache[cacheKey];
    }

    final String? direct = _extractYouTubeVideoId(song);
    if (direct != null) {
      _ytMusicVideoIdCache[cacheKey] = direct;
      return direct;
    }

    final List<LibrarySong> matches = await _searchYtMusicSongs(
      '${song.artist} ${song.title}',
      limit: 5,
    );
    final String? resolved = matches
        .map(_extractYouTubeVideoId)
        .firstWhereOrNull((String? id) => id != null);
    _ytMusicVideoIdCache[cacheKey] = resolved;
    return resolved;
  }

  String? _extractYouTubeVideoId(LibrarySong song) {
    if (song.id.startsWith('yt:')) {
      return song.id.substring(3);
    }

    final Uri? uri = Uri.tryParse(song.externalUrl ?? song.path);
    if (uri == null) {
      return null;
    }
    if (uri.host.contains('youtu.be')) {
      return uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    }
    if (uri.host.contains('youtube.com') ||
        uri.host.contains('music.youtube.com')) {
      return uri.queryParameters['v'];
    }
    return null;
  }

  LibrarySong? _ytMusicItemToSong(dynamic item, {String? query}) {
    if (item is! Map) {
      return null;
    }

    final Map<dynamic, dynamic> data = item;
    final String? videoId = data['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) {
      return null;
    }

    final String title = '${data['title'] ?? 'Unknown title'}'.trim();
    final String artist = _readArtistName(data) ?? 'Unknown artist';
    final String album = _readAlbumName(data) ?? 'Online Music';
    final String? artworkUrl = _readThumbnailUrl(data);
    final int durationMs = _parseDurationMs(
      data['duration'] ?? data['length'] ?? data['lengthSeconds'],
    );

    final LibrarySong song = LibrarySong(
      id: 'yt:$videoId',
      path: 'https://www.youtube.com/watch?v=$videoId',
      title: title.isEmpty ? 'Unknown title' : title,
      artist: artist,
      album: album,
      albumArtist: artist,
      folderName: 'Online Music',
      folderPath: 'ytmusic',
      sourceLabel: 'Online Music',
      addedAt: DateTime.now(),
      durationMs: durationMs,
      isRemote: true,
      artworkUrl: _upgradeArtworkUrl(artworkUrl),
      externalUrl: 'https://music.youtube.com/watch?v=$videoId',
    );
    if (!_looksLikeMusic(song, query: query)) {
      return null;
    }
    return song;
  }

  List<LibrarySong> _rankOnlineSearchMatches(
    List<LibrarySong> songs, {
    required String query,
    required int limit,
  }) {
    final Set<String> excludedIds = <String>{};
    final Set<String> seenKeys = <String>{};
    final List<_ScoredSong> ranked = <_ScoredSong>[];

    for (final LibrarySong song in songs) {
      if (excludedIds.contains(song.id)) {
        continue;
      }
      final String key = _songIdentityKey(song);
      if (!seenKeys.add(key)) {
        continue;
      }
      ranked.add(_ScoredSong(song, _onlineSearchScore(song, query: query)));
      excludedIds.add(song.id);
    }

    ranked.sort((_ScoredSong a, _ScoredSong b) {
      final int compare = b.score.compareTo(a.score);
      if (compare != 0) {
        return compare;
      }
      return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
    });

    return ranked
        .take(limit)
        .map((_ScoredSong item) => item.song)
        .toList(growable: false);
  }

  List<LibrarySong> _rankTrendingNowCandidates(
    List<LibrarySong> songs, {
    required String languageCode,
    required String countryCode,
    required int limit,
  }) {
    final Set<String> seenKeys = <String>{};
    final String expectedLanguage = _localeToLanguageBucket(languageCode);
    final String rankingQuery =
        '$countryCode $languageCode last month top songs'.trim();
    final List<_ScoredSong> ranked = <_ScoredSong>[];

    for (final LibrarySong song in songs) {
      if (_isSongExplicitlyDisliked(song)) {
        continue;
      }
      final String key = _songIdentityKey(song);
      if (!seenKeys.add(key)) {
        continue;
      }

      double score = _onlineSearchScore(song, query: rankingQuery);
      final _LanguageDetection language = _detectSongLanguageSignal(song);
      if (language.code == expectedLanguage) {
        score += 7.5 * language.confidence;
      } else if (expectedLanguage != 'en' &&
          language.code == 'en' &&
          language.confidence >= _strictLanguageGateConfidence) {
        score -= 8.5;
      }
      if ((song.artworkUrl ?? '').trim().isNotEmpty) {
        score += 2.2;
      }
      final int seconds = song.duration.inSeconds;
      if (seconds >= 120 && seconds <= 360) {
        score += 1.4;
      } else if (seconds > 0 && seconds < 75) {
        score -= 2.8;
      }
      ranked.add(_ScoredSong(song, score));
    }

    ranked.sort((_ScoredSong a, _ScoredSong b) {
      final int scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
    });

    return ranked
        .take(limit)
        .map((_ScoredSong item) => item.song)
        .toList(growable: false);
  }

  String _localeLanguageQueryToken(String languageCode) {
    return switch (languageCode) {
      'si' => 'sinhala',
      'ta' => 'tamil',
      'hi' => 'hindi',
      'ur' => 'urdu',
      'bn' => 'bengali',
      'ja' => 'japanese',
      'ko' => 'korean',
      'unknown' => 'songs',
      _ => 'english',
    };
  }

  String _localeToLanguageBucket(String languageCode) {
    return switch (languageCode) {
      'si' => 'si',
      'ta' => 'ta',
      'hi' => 'hi',
      'ur' => 'ur',
      'bn' => 'bn',
      'ja' => 'ja',
      'ko' => 'ko',
      _ => 'en',
    };
  }

  String _queryTokenToLanguageCode(String token) {
    return switch (token.trim().toLowerCase()) {
      'sinhala' => 'si',
      'tamil' => 'ta',
      'hindi' => 'hi',
      'urdu' => 'ur',
      'bengali' => 'bn',
      'japanese' => 'ja',
      'korean' => 'ko',
      _ => 'en',
    };
  }

  String _regionLabelFromCountryCode(String countryCode) {
    final String normalized = _normalizeCountryCode(countryCode);
    final AppRegion? matched = kAppRegions.firstWhereOrNull(
      (AppRegion region) => region.countryCode == normalized,
    );
    return matched?.label ?? (normalized.isEmpty ? 'Your region' : normalized);
  }

  String _normalizeCountryCode(String? value) {
    final String normalized = (value ?? '').trim().toUpperCase();
    if (normalized.isEmpty) {
      return 'LK';
    }
    final AppRegion? matched = kAppRegions.firstWhereOrNull(
      (AppRegion region) => region.countryCode == normalized,
    );
    return matched?.countryCode ?? 'LK';
  }

  AppRegion get preferredRegion {
    final String code = preferredCountryCode;
    return kAppRegions.firstWhere(
      (AppRegion region) => region.countryCode == code,
      orElse: () => kAppRegions.first,
    );
  }

  String get preferredLanguageCode {
    final List<_LanguageSignal> historyLanguages =
        _preferredLanguagesFromValidHistory();
    if (historyLanguages.isNotEmpty) {
      return _queryTokenToLanguageCode(historyLanguages.first.queryToken);
    }
    return preferredRegion.languageCode;
  }

  Future<void> setPreferredRegion(String countryCode) async {
    final String normalized = _normalizeCountryCode(countryCode);
    if (normalized == preferredCountryCode) {
      return;
    }
    _settings = _settings.copyWith(preferredCountryCode: normalized);
    _bumpSettingsStateRevision();
    _trendingNowSongs = <LibrarySong>[];
    _trendingNowRegionLabel = _regionLabelFromCountryCode(normalized);
    _trendingNowError = null;
    await _saveSnapshot();
    notifyListeners();
    _scheduleCloudPreferenceProfileSync();
    await loadTrendingNow(
      languageCode: preferredLanguageCode,
      countryCode: normalized,
      force: true,
    );
  }

  double _onlineSearchScore(LibrarySong song, {required String query}) {
    double score = 0;
    final String normalizedQuery = _normalizeToken(query);
    final String title = _normalizeToken(song.title);
    final String artist = _normalizeToken(song.artist);
    final String album = _normalizeToken(song.album);
    final String haystack = '$title $artist $album';

    if (song.sourceLabel == 'Online Music' ||
        song.sourceLabel == 'YouTube Music') {
      score += 12;
    } else if (song.sourceLabel == 'Online Stream' ||
        song.sourceLabel == 'YouTube') {
      score += 2;
    }

    for (final String token in normalizedQuery.split(RegExp(r'\s+'))) {
      if (token.isEmpty) {
        continue;
      }
      if (title.contains(token)) {
        score += 3.2;
      }
      if (artist.contains(token)) {
        score += 2.4;
      }
      if (album.contains(token)) {
        score += 1.4;
      }
      if (haystack.contains(token)) {
        score += 0.4;
      }
    }

    if (_hasExplicitMusicSignals(song)) {
      score += 3.5;
    }
    if (_looksNonMusicLike(song)) {
      score -= 18;
    }

    final int seconds = song.duration.inSeconds;
    if (seconds >= 90 && seconds <= 480) {
      score += 2.5;
    } else if (seconds > 0 && seconds < 45) {
      score -= 5;
    } else if (seconds > 1200) {
      score -= 8;
    }

    return score;
  }

  bool _looksLikeMusic(LibrarySong song, {String? query}) {
    if (_looksNonMusicLike(song)) {
      return false;
    }

    final int seconds = song.duration.inSeconds;
    if (seconds > 0 && seconds < 45) {
      return false;
    }

    final String normalizedQuery = _normalizeToken(query ?? '');
    if (normalizedQuery.isNotEmpty) {
      final List<String> queryTokens = normalizedQuery
          .split(RegExp(r'\s+'))
          .where((String token) => token.length >= 2)
          .toList(growable: false);
      final String haystack =
          '${_normalizeToken(song.title)} ${_normalizeToken(song.artist)} ${_normalizeToken(song.album)}';
      final int matches = queryTokens
          .where((String token) => haystack.contains(token))
          .length;
      if (queryTokens.isNotEmpty &&
          matches == 0 &&
          !_hasExplicitMusicSignals(song)) {
        return false;
      }
    }

    return true;
  }

  bool _hasExplicitMusicSignals(LibrarySong song) {
    final String text =
        '${song.title} ${song.artist} ${song.album} ${song.sourceLabel}'
            .toLowerCase();
    const List<String> goodTokens = <String>[
      'song',
      'music',
      'audio',
      'official',
      'track',
      'single',
      'album',
      'ep',
      'remix',
      'live',
      'lyrics',
      'radio edit',
    ];
    return goodTokens.any(text.contains);
  }

  bool _looksNonMusicLike(LibrarySong song) {
    final String text =
        '${song.title} ${song.artist} ${song.album} ${song.folderName}'
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    const List<String> badTokens = <String>[
      'gameplay',
      'gaming',
      'walkthrough',
      'walkthroughs',
      'tutorial',
      'lesson',
      'lecture',
      'course',
      'podcast episode',
      'news',
      'review',
      'reaction',
      'interview',
      'stream',
      'livestream',
      'highlights',
      'funny moments',
      'compilation',
      'documentary',
      'explained',
      'how to',
      'education',
      'study guide',
      'minecraft',
      'fortnite',
      'valorant',
      'pubg',
      'free fire',
      'roblox',
      'gta',
    ];
    return badTokens.any(text.contains);
  }

  List<LibrarySong> _dedupeSongs(
    List<LibrarySong> songs, {
    required Set<String> excludedIds,
    int limit = 10,
  }) {
    final Set<String> seenKeys = <String>{};
    final Set<String> seenIds = <String>{};
    final Set<String> dislikedKeys = _decisionDislikedSongs
        .map(_songIdentityKey)
        .toSet();
    final List<LibrarySong> result = <LibrarySong>[];
    for (final LibrarySong song in songs) {
      final String identityKey = _songIdentityKey(song);
      if (excludedIds.contains(song.id) ||
          !_shouldUseSongInHomeOrSmartQueue(song) ||
          song.isDisliked ||
          dislikedKeys.contains(identityKey)) {
        continue;
      }
      if (!seenIds.add(song.id)) {
        continue;
      }
      if (!seenKeys.add(identityKey)) {
        continue;
      }
      result.add(song);
      if (result.length >= limit) {
        break;
      }
    }
    return result;
  }

  String? _readArtistName(Map<dynamic, dynamic> data) {
    final dynamic artists = data['artists'];
    if (artists is List && artists.isNotEmpty) {
      final dynamic first = artists.first;
      if (first is Map && first['name'] != null) {
        return '${first['name']}'.trim();
      }
    }
    if (data['artist'] != null) {
      return '${data['artist']}'.trim();
    }
    return null;
  }

  String? _readArtistResultName(Map<dynamic, dynamic> data) {
    final dynamic title = data['title'] ?? data['artist'] ?? data['name'];
    final String text = '$title'.trim();
    if (text.isNotEmpty && text.toLowerCase() != 'null') {
      return text;
    }

    final dynamic artists = data['artists'];
    if (artists is List && artists.isNotEmpty) {
      final dynamic first = artists.first;
      if (first is Map) {
        final String candidate = '${first['name'] ?? first['title'] ?? ''}'
            .trim();
        if (candidate.isNotEmpty) {
          return candidate;
        }
      }
      final String candidate = '$first'.trim();
      if (candidate.isNotEmpty && candidate.toLowerCase() != 'null') {
        return candidate;
      }
    }
    return null;
  }

  String? _pickArtistImageUrl(
    List<dynamic> results, {
    required String artistName,
  }) {
    final String normalizedTarget = _normalizeToken(artistName);
    String? fallback;

    for (final dynamic item in results) {
      if (item is! Map) {
        continue;
      }
      final Map<dynamic, dynamic> data = item;
      fallback ??= _readThumbnailUrl(data);

      final String candidate = _normalizeToken(
        _readArtistResultName(data) ?? '',
      );
      if (candidate.isEmpty) {
        continue;
      }
      if (candidate == normalizedTarget ||
          candidate.contains(normalizedTarget) ||
          normalizedTarget.contains(candidate)) {
        final String? matched = _readThumbnailUrl(data);
        if ((matched ?? '').trim().isNotEmpty) {
          return matched;
        }
      }
    }

    return fallback;
  }

  String? _readAlbumName(Map<dynamic, dynamic> data) {
    final dynamic album = data['album'];
    if (album is String) {
      final String text = album.trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') {
        return text;
      }
    }
    if (album is Map && album['name'] != null) {
      return '${album['name']}'.trim();
    }
    if (data['category'] != null) {
      return '${data['category']}'.trim();
    }
    return null;
  }

  String? _readThumbnailUrl(Map<dynamic, dynamic> data) {
    final dynamic thumbnails = data['thumbnail'] ?? data['thumbnails'];
    if (thumbnails is List && thumbnails.isNotEmpty) {
      Map<dynamic, dynamic>? best;
      for (final dynamic item in thumbnails) {
        if (item is! Map || item['url'] == null) {
          continue;
        }
        if (best == null) {
          best = item;
          continue;
        }
        final int currentWidth = (item['width'] as num?)?.toInt() ?? 0;
        final int bestWidth = (best['width'] as num?)?.toInt() ?? 0;
        if (currentWidth > bestWidth) {
          best = item;
        }
      }
      best ??= thumbnails.last is Map && thumbnails.last['url'] != null
          ? thumbnails.last as Map<dynamic, dynamic>
          : null;
      if (best != null && best['url'] != null) {
        return _upgradeArtworkUrl('${best['url']}');
      }
    }
    return null;
  }

  String _upgradeArtworkUrl(String? url) {
    return normalizeArtworkUrl(url) ?? '';
  }

  int _parseDurationMs(dynamic rawDuration) {
    if (rawDuration is num) {
      return rawDuration.toInt() * 1000;
    }
    final String value = '${rawDuration ?? ''}'.trim();
    if (value.isEmpty) {
      return 0;
    }
    final List<int> parts = value
        .split(':')
        .map((String item) => int.tryParse(item) ?? 0)
        .toList(growable: false);
    int seconds = 0;
    for (final int part in parts) {
      seconds = (seconds * 60) + part;
    }
    return seconds * 1000;
  }

  Future<String> _normalizeYtMusicAuth(String input) async {
    if (input.startsWith('{')) {
      final Map<String, dynamic> json =
          jsonDecode(input) as Map<String, dynamic>;
      final Map<String, String> normalized = <String, String>{
        for (final MapEntry<String, dynamic> entry in json.entries)
          entry.key.toLowerCase(): '${entry.value}',
      };
      return jsonEncode(normalized);
    }

    return ytm_browser.setupBrowser(headersRaw: input);
  }

  void _scheduleSmartQueueWindowRefill({LibrarySong? seed}) {
    if (_isDisposing || _isDisposed) {
      return;
    }
    _debugPlayback(
      'smartQueue.schedule '
      'seed=${_debugSongLabel(seed)} '
      'loading=$_smartQueueLoading '
      'queueLen=${_queueSongIds.length} '
      'queueIndex=$_queueIndex '
      'detached=$_offlineDetachedQueueMode '
      'playerSynced=${_playerQueueHasControllerPlaylist()}',
    );
    if (_smartQueueLoading) {
      _smartQueueRefillQueued = true;
      _debugPlayback('smartQueue.schedule queued refill while busy');
      return;
    }
    final bool syncPlayerQueue =
        !_offlineDetachedQueueMode && _playerQueueHasControllerPlaylist();
    unawaited(
      _maybeExtendSmartQueue(
        seed: seed,
        force: true,
        syncPlayerQueue: syncPlayerQueue,
      ),
    );
  }

  Future<void> _refillRestoredSmartQueueIfNeeded() async {
    if (_queueSongIds.isEmpty ||
        _queueIndex < 0 ||
        _queueIndex >= _queueSongIds.length) {
      return;
    }

    final LibrarySong? anchor = currentSong;
    if (anchor == null) {
      return;
    }

    final int previousQueueLength = _queueSongIds.length;
    await _maybeExtendSmartQueue(
      seed: anchor,
      force: true,
      syncPlayerQueue: false,
    );
    if (_queueSongIds.length > previousQueueLength) {
      _scheduleSnapshotSave();
    }
  }

  Future<void> _maybeExtendSmartQueue({
    LibrarySong? seed,
    bool force = false,
    bool syncPlayerQueue = true,
  }) async {
    if (_isDisposing ||
        _isDisposed ||
        _isOffline ||
        offlineMusicMode ||
        (!_settings.smartQueueEnabled && !force) ||
        _smartQueueLoading) {
      _debugPlayback(
        'smartQueue.skip '
        'seed=${_debugSongLabel(seed)} '
        'force=$force '
        'loading=$_smartQueueLoading '
        'offline=$_isOffline '
        'offlineMode=$offlineMusicMode '
        'enabled=${_settings.smartQueueEnabled}',
      );
      return;
    }

    final LibrarySong? current = currentSong;
    final LibrarySong? anchor =
        (seed != null && _shouldUseSongInHomeOrSmartQueue(seed))
        ? seed
        : (current != null && _shouldUseSongInHomeOrSmartQueue(current))
        ? current
        : null;
    if (anchor == null) {
      _debugPlayback(
        'smartQueue.skip no anchor '
        'seed=${_debugSongLabel(seed)} '
        'current=${_debugSongLabel(current)} '
        'queueLen=${_queueSongIds.length}',
      );
      return;
    }

    final int remaining = _queueSongIds.length - _queueIndex - 1;
    if (remaining >= _smartQueueBatchSize) {
      _debugPlayback(
        'smartQueue.skip enough queued '
        'anchor=${_debugSongLabel(anchor)} '
        'remaining=$remaining '
        'batch=$_smartQueueBatchSize',
      );
      return;
    }

    _debugPlayback(
      'smartQueue.extend '
      'anchor=${_debugSongLabel(anchor)} '
      'remaining=$remaining '
      'request=${_smartQueueBatchSize - remaining} '
      'syncPlayerQueue=$syncPlayerQueue '
      'force=$force',
    );
    await _appendSmartQueuePredictions(
      anchor,
      limit: _smartQueueBatchSize - remaining,
      syncPlayerQueue: syncPlayerQueue,
    );
  }

  Future<void> _appendSmartQueuePredictions(
    LibrarySong anchor, {
    int limit = 6,
    bool syncPlayerQueue = true,
  }) async {
    if (limit <= 0 || _isDisposing || _isDisposed) {
      return;
    }

    _smartQueueLoading = true;
    notifyListeners();

    try {
      _debugPlayback(
        'smartQueue.append start '
        'anchor=${_debugSongLabel(anchor)} '
        'limit=$limit '
        'syncPlayerQueue=$syncPlayerQueue '
        'queueLen=${_queueSongIds.length} '
        'queueIndex=$_queueIndex',
      );
      List<LibrarySong> predictions = await _predictNextSongs(
        anchor,
        limit: limit,
      );
      _debugPlayback(
        'smartQueue.append predicted primary=${predictions.length} '
        'anchor=${_debugSongLabel(anchor)}',
      );
      if (_isDisposing || _isDisposed) {
        return;
      }
      final LibrarySong? current = currentSong;
      final LibrarySong? fallbackAnchor =
          current != null &&
              current.isRemote &&
              _shouldUseSongInHomeOrSmartQueue(current)
          ? current
          : null;
      if (predictions.isEmpty &&
          fallbackAnchor != null &&
          fallbackAnchor.id != anchor.id) {
        predictions = await _predictNextSongs(fallbackAnchor, limit: limit);
        _debugPlayback(
          'smartQueue.append predicted fallback=${predictions.length} '
          'fallbackAnchor=${_debugSongLabel(fallbackAnchor)}',
        );
      }
      if (predictions.isEmpty) {
        // Hard fallback so queue always grows for better UX.
        final LibrarySong fallbackSeed = fallbackAnchor ?? anchor;
        final String fallbackLanguage = _anchorRecommendationLanguage(
          fallbackSeed,
        );
        final List<LibrarySong> fallback = await _searchSongs(
          fallbackLanguage == 'unknown'
              ? '${fallbackSeed.artist} ${fallbackSeed.title} top songs'
              : '${_languageQueryToken(fallbackLanguage)} top songs',
          limit: limit * 2,
          force: true,
          usageBucket: _AppNetworkUsageBucket.load,
        );
        predictions = _dedupeSongs(
          fallback,
          excludedIds: <String>{..._queueSongIds, anchor.id},
          limit: limit,
        );
        _debugPlayback(
          'smartQueue.append fallback search results=${fallback.length} '
          'deduped=${predictions.length} '
          'fallbackSeed=${_debugSongLabel(fallbackSeed)} '
          'fallbackLanguage=$fallbackLanguage',
        );
      }
      if (predictions.isEmpty) {
        _debugPlayback(
          'smartQueue.append no predictions '
          'anchor=${_debugSongLabel(anchor)} '
          'queueLen=${_queueSongIds.length}',
        );
        return;
      }

      final Set<String> dislikedKeys = _decisionDislikedSongs
          .map(_songIdentityKey)
          .toSet();
      final Set<String> queuedIds = <String>{..._queueSongIds};
      final Set<String> queuedKeys = queueSongs.map(_songIdentityKey).toSet();
      int addedCount = 0;
      for (final LibrarySong song in predictions) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        if (!_shouldUseSongInHomeOrSmartQueue(song)) {
          continue;
        }
        if (song.isDisliked || dislikedKeys.contains(_songIdentityKey(song))) {
          continue;
        }
        final String preparedKey = _songIdentityKey(song);
        if (dislikedKeys.contains(preparedKey) ||
            !queuedIds.add(song.id) ||
            !queuedKeys.add(preparedKey)) {
          continue;
        }

        _queueSongIds = <String>[..._queueSongIds, song.id];
        _smartQueueSongIds.add(song.id);
        final bool shouldSyncPlayerQueueNow =
            syncPlayerQueue &&
            !_offlineDetachedQueueMode &&
            _playerQueueHasControllerPlaylist();
        if (shouldSyncPlayerQueueNow) {
          await _player.add(_mediaForSong(song));
        }
        addedCount += 1;
        _debugPlayback(
          'smartQueue.append added '
          'song=${_debugSongLabel(song)} '
          'queueLen=${_queueSongIds.length} '
          'syncNow=$shouldSyncPlayerQueueNow',
        );
      }

      if (addedCount > 0 && _queueSongIds.length > 1) {
        if (_queueLabel == 'Song' ||
            _queueLabel == 'Now Playing' ||
            _queueLabel == 'Online Music' ||
            _queueLabel == 'YouTube' ||
            _queueLabel == 'URL Stream') {
          _queueLabel = 'Smart queue';
        }
      }
      _debugPlayback(
        'smartQueue.append done '
        'anchor=${_debugSongLabel(anchor)} '
        'predictions=${predictions.length} '
        'added=$addedCount '
        'queueLen=${_queueSongIds.length} '
        'label=$_queueLabel',
      );
    } catch (error) {
      _debugLog('Smart queue failed: $error');
    } finally {
      _smartQueueLoading = false;
      notifyListeners();
      if (_smartQueueRefillQueued) {
        _smartQueueRefillQueued = false;
        _scheduleSmartQueueWindowRefill(seed: currentSong);
      }
    }
  }

  Future<List<LibrarySong>> _predictNextSongs(
    LibrarySong anchor, {
    int limit = 6,
  }) async {
    final Set<String> excludedIds = <String>{
      ..._queueSongIds,
      anchor.id,
      ..._songs
          .where((LibrarySong song) => song.isDisliked)
          .map((LibrarySong song) => song.id),
    };
    final List<LibrarySong> prioritizedSeed = _dedupeSongs(
      await _ytMusicRadioSongs(anchor, limit: limit + 4),
      excludedIds: excludedIds,
      limit: limit + 4,
    );
    final List<LibrarySong> prioritized = _rankRecommendedSongs(
      prioritizedSeed,
      anchor: anchor,
      excludedIds: excludedIds,
      limit: limit,
    );
    if (prioritized.length >= limit) {
      return prioritized;
    }

    final List<_RecommendationQuery> queries = _buildPredictionQueries(anchor);
    final List<LibrarySong> collected = <LibrarySong>[...prioritized];
    for (final _RecommendationQuery query in queries) {
      final List<LibrarySong> results = await _searchSongs(
        query.query,
        limit: 12,
        usageBucket: _AppNetworkUsageBucket.load,
      );
      collected.addAll(results);
      if (collected.length >= 36) {
        break;
      }
    }

    final List<LibrarySong> fallback = _rankRecommendedSongs(
      collected,
      anchor: anchor,
      excludedIds: excludedIds,
      limit: limit * 2,
    );
    final List<LibrarySong> merged = _dedupeSongs(
      <LibrarySong>[...prioritized, ...fallback],
      excludedIds: excludedIds,
      limit: limit,
    );
    return merged;
  }

  LibrarySong? _primaryRecommendationSeed() {
    final LibrarySong? current = currentSong;
    if (current != null &&
        current.isRemote &&
        shouldShowSongOutsideSearch(current)) {
      return current;
    }
    return _validHistorySongs().firstOrNull ??
        _rankedPreferenceSongs().firstOrNull;
  }

  List<_RecommendationQuery> _buildHomeQueries(LibrarySong? seedSong) {
    final List<_TasteSignal> artists = _preferenceArtists();
    final List<_TasteSignal> genres = _preferenceGenres();
    final List<_LanguageSignal> languages =
        _preferredLanguagesFromValidHistory();
    final _TasteProfile profile = _buildTasteProfile();
    final _SessionContext session = _sessionContext();
    final List<_RecommendationQuery> queries = <_RecommendationQuery>[];
    final String recommendationLanguage = _activeRecommendationLanguage(
      anchor: seedSong,
      profile: profile,
    );
    final String languageToken = _languageQueryToken(recommendationLanguage);

    void addQuery(_RecommendationQuery query) {
      final String key = query.query.trim().toLowerCase();
      if (key.isEmpty ||
          queries.any(
            (_RecommendationQuery item) =>
                item.query.trim().toLowerCase() == key,
          )) {
        return;
      }
      queries.add(query);
    }

    if (seedSong != null) {
      addQuery(
        _RecommendationQuery(
          title: 'Because you played - ${seedSong.title}',
          subtitle: 'Closest match to what you are into right now',
          query: '${seedSong.artist} ${seedSong.title} similar songs',
          anchor: seedSong,
        ),
      );
      addQuery(
        _RecommendationQuery(
          title: 'More from ${seedSong.artist}',
          subtitle: 'Artists and songs adjacent to your recent play',
          query: '${seedSong.artist} popular songs',
          anchor: seedSong,
        ),
      );
    }

    for (final _TasteSignal artist in artists.take(2)) {
      addQuery(
        _RecommendationQuery(
          title: 'Personalized Artist Feed',
          subtitle: 'Artists you return to most often',
          query: '${artist.label} top songs',
        ),
      );
    }

    for (final _TasteSignal genre in genres.take(2)) {
      addQuery(
        _RecommendationQuery(
          title: '${genre.label} for you',
          subtitle: 'Genre picks driven by your listening patterns',
          query: '$languageToken ${genre.label} songs',
        ),
      );
    }

    for (final _LanguageSignal language in languages.take(1)) {
      addQuery(
        _RecommendationQuery(
          title: '${language.label} picks',
          subtitle: 'Matches the language you finish most',
          query: '${language.queryToken} songs you may like',
        ),
      );
    }

    final String topYear = profile.yearKeys.firstOrNull ?? '';
    if (topYear.isNotEmpty) {
      addQuery(
        _RecommendationQuery(
          title: '$topYear favorites',
          subtitle: 'Release years that fit your listening pattern',
          query: '$languageToken $topYear songs',
          anchor: seedSong,
        ),
      );
    }

    addQuery(
      _RecommendationQuery(
        title: '${session.label} for you',
        subtitle: 'Session-aware music picked for this moment',
        query: '$languageToken ${session.query} songs',
        anchor: seedSong,
      ),
    );

    if (queries.isEmpty) {
      addQuery(
        _RecommendationQuery(
          title: 'Fresh discoveries',
          subtitle:
              'Start listening, liking, and finishing songs to personalize this section',
          query: '$languageToken best songs playlist',
        ),
      );
      addQuery(
        _RecommendationQuery(
          title: 'New for your library',
          subtitle:
              'A fallback shelf until your taste profile becomes stronger',
          query: '$languageToken new music songs',
        ),
      );
    }

    return queries;
  }

  List<SongRecommendation> _buildPersonalizedHomeSongs({
    required List<HomeFeedSection> sections,
    LibrarySong? seedSong,
  }) {
    final List<LibrarySong> fullListenSongs = _validHistorySongs();
    final _TasteProfile profile = _buildTasteProfile();
    final List<LibrarySong> sectionSongs = <LibrarySong>[
      for (final HomeFeedSection section in sections)
        ...section.songs.where((LibrarySong song) => song.isRemote).take(12),
    ];
    final Map<String, int> sectionHits = <String, int>{};
    final Map<String, HomeFeedSection> primarySectionBySong =
        <String, HomeFeedSection>{};
    final Set<String> recentIds = recentlyPlayedSongs
        .take(24)
        .map((LibrarySong song) => song.id)
        .toSet();
    final Set<String> recentKeys = recentlyPlayedSongs
        .take(24)
        .map(_songIdentityKey)
        .toSet();
    final Set<String> skippedSongIds = _recentSkippedSongIds();
    final Map<String, int> recentArtistCounts = <String, int>{};

    for (final LibrarySong song in recentlyPlayedSongs.take(16)) {
      final String artistKey = _normalizeToken(song.artist);
      if (artistKey.isEmpty) {
        continue;
      }
      recentArtistCounts[artistKey] = (recentArtistCounts[artistKey] ?? 0) + 1;
    }

    for (final HomeFeedSection section in sections) {
      for (final LibrarySong song in section.songs.take(12)) {
        final String key = _songIdentityKey(song);
        sectionHits[key] = (sectionHits[key] ?? 0) + 1;
        primarySectionBySong.putIfAbsent(key, () => section);
      }
    }

    final Set<String> fullListenIds = validPlaybackHistory
        .map((PlaybackEntry entry) => entry.songId)
        .toSet();
    final Set<String> likedArtistKeys = _decisionLikedSongs
        .map((LibrarySong song) => _normalizeToken(song.artist))
        .where((String key) => key.isNotEmpty)
        .toSet();
    final Set<String> fullListenArtistKeys = fullListenSongs
        .map((LibrarySong song) => _normalizeToken(song.artist))
        .where((String key) => key.isNotEmpty)
        .toSet();

    final List<LibrarySong> seedSongs = _dedupeSongs(
      <LibrarySong>[
        if (currentSong case final LibrarySong current
            when current.isRemote && shouldShowSongOutsideSearch(current))
          current,
        if (seedSong case final LibrarySong seed
            when seed.isRemote && shouldShowSongOutsideSearch(seed))
          seed,
        ...fullListenSongs.take(4),
        ..._decisionLikedSongs.take(4),
      ],
      excludedIds: <String>{},
      limit: 10,
    );
    final List<LibrarySong> candidates = _dedupeSongs(
      sectionSongs
          .where((LibrarySong song) {
            if (song.isDisliked) {
              return false;
            }
            if (recentIds.contains(song.id) ||
                recentKeys.contains(_songIdentityKey(song)) ||
                skippedSongIds.contains(song.id)) {
              return false;
            }
            if (seedSongs.any((LibrarySong seed) => _sameSong(seed, song))) {
              return false;
            }
            if (_isStronglyAvoidedCandidate(song, profile: profile)) {
              return false;
            }
            if (!_shouldKeepCandidateForLanguage(
              song,
              anchor: seedSong ?? currentSong,
              profile: profile,
            )) {
              return false;
            }
            return true;
          })
          .toList(growable: false),
      excludedIds: <String>{},
      limit: 140,
    );

    final LibrarySong? anchor = seedSongs.firstOrNull;
    final List<_ScoredRecommendation> scored = candidates
        .map((LibrarySong song) {
          final String key = _songIdentityKey(song);
          final String artistKey = _normalizeToken(song.artist);
          double score = _recommendationScore(
            song,
            anchor: anchor,
            profile: profile,
          );
          score += (sectionHits[key] ?? 0) * 5.5;
          if (profile.genreKeys.contains(_normalizeToken(song.genre ?? ''))) {
            score += 7;
          }
          final _LanguageDetection languageSignal = _detectSongLanguageSignal(
            song,
          );
          if (_shouldUseLanguageSignal(languageSignal) &&
              profile.languageKeys.contains(languageSignal.code)) {
            score += 4.5 * languageSignal.confidence;
          }
          if (profile.moodKeys.intersection(_vibeTokens(song)).isNotEmpty) {
            score += 5.5;
          }
          score += profile.yearAffinity(song.year) * 3.2;
          score += profile.preferredYearWindowBoost(song.year);
          if (profile.prefersRecentYears && (song.year ?? 0) >= 2018) {
            score += 2.4;
          }
          if (!profile.prefersRecentYears &&
              song.year != null &&
              song.year! > 0 &&
              song.year! < 2016) {
            score += 2.4;
          }
          if (likedArtistKeys.contains(artistKey) ||
              fullListenArtistKeys.contains(artistKey)) {
            score += 6;
          }
          final int recentArtistCount = recentArtistCounts[artistKey] ?? 0;
          if (recentArtistCount >= 2) {
            score -= 5.5 * recentArtistCount;
          }
          if ((song.artworkUrl ?? '').trim().isNotEmpty) {
            score += 1.2;
          }
          if (song.sourceLabel == 'Online Music' ||
              song.sourceLabel == 'YouTube Music') {
            score += 1.8;
          }
          if (!fullListenIds.contains(song.id) &&
              !likedArtistKeys.contains(artistKey) &&
              !fullListenArtistKeys.contains(artistKey)) {
            score += 2.8;
          }
          final bool exploratory = _isExploratoryCandidate(
            song,
            profile: profile,
            artistKey: artistKey,
            fullListenArtistKeys: fullListenArtistKeys,
            likedArtistKeys: likedArtistKeys,
          );
          return _ScoredRecommendation(
            song: song,
            score: score,
            reason: _recommendationReason(
              song,
              profile: profile,
              exploratory: exploratory,
              section: primarySectionBySong[key],
              artistKey: artistKey,
              likedArtistKeys: likedArtistKeys,
              fullListenArtistKeys: fullListenArtistKeys,
            ),
            isExploratory: exploratory,
          );
        })
        .toList(growable: false);

    return _selectPersonalizedRecommendations(scored, limit: 50);
  }

  Set<String> _recentSkippedSongIds() {
    final Set<String> result = <String>{};
    for (final PlaybackEntry entry in _history.take(80)) {
      if (_shouldUseSongIdForHistorySignals(entry.songId) &&
          !entry.listenedToEnd &&
          entry.completionRatio < 0.45) {
        result.add(entry.songId);
      }
    }
    return result;
  }

  _TasteProfile _buildTasteProfile() {
    final Map<String, double> artistScores = Map<String, double>.from(
      _cloudPreferenceProfile.artistScores,
    );
    final Map<String, double> genreScores = Map<String, double>.from(
      _cloudPreferenceProfile.genreScores,
    );
    final Map<String, double> moodScores = Map<String, double>.from(
      _cloudPreferenceProfile.moodScores,
    );
    final Map<String, double> languageScores = Map<String, double>.from(
      _cloudPreferenceProfile.languageScores,
    );
    final Map<String, double> languageConfidenceScores =
        Map<String, double>.from(
          _cloudPreferenceProfile.languageConfidenceScores,
        );
    final Map<String, double> yearScores = Map<String, double>.from(
      _cloudPreferenceProfile.yearScores,
    );
    final Map<String, double> avoidedArtistScores = Map<String, double>.from(
      _cloudPreferenceProfile.avoidedArtistScores,
    );
    final Map<String, double> avoidedGenreScores = Map<String, double>.from(
      _cloudPreferenceProfile.avoidedGenreScores,
    );
    final Map<String, double> avoidedMoodScores = Map<String, double>.from(
      _cloudPreferenceProfile.avoidedMoodScores,
    );
    final Map<String, double> avoidedLanguageScores = Map<String, double>.from(
      _cloudPreferenceProfile.avoidedLanguageScores,
    );
    final Map<String, double> avoidedYearScores = Map<String, double>.from(
      _cloudPreferenceProfile.avoidedYearScores,
    );
    final Map<String, double> recentArtistScores = Map<String, double>.from(
      _cloudPreferenceProfile.recentArtistScores,
    );
    final Map<String, double> recentGenreScores = Map<String, double>.from(
      _cloudPreferenceProfile.recentGenreScores,
    );
    final Map<String, double> recentMoodScores = Map<String, double>.from(
      _cloudPreferenceProfile.recentMoodScores,
    );
    final Map<String, double> recentLanguageScores = Map<String, double>.from(
      _cloudPreferenceProfile.recentLanguageScores,
    );
    final Map<String, double> recentYearScores = Map<String, double>.from(
      _cloudPreferenceProfile.recentYearScores,
    );
    final Map<String, double> skipArtistScores = Map<String, double>.from(
      _cloudPreferenceProfile.skipArtistScores,
    );
    final Map<String, double> skipGenreScores = Map<String, double>.from(
      _cloudPreferenceProfile.skipGenreScores,
    );
    final Map<String, double> skipMoodScores = Map<String, double>.from(
      _cloudPreferenceProfile.skipMoodScores,
    );
    final Map<String, double> skipLanguageScores = Map<String, double>.from(
      _cloudPreferenceProfile.skipLanguageScores,
    );
    final Map<String, double> skipYearScores = Map<String, double>.from(
      _cloudPreferenceProfile.skipYearScores,
    );
    final Map<String, double> energyScores = Map<String, double>.from(
      _cloudPreferenceProfile.energyScores,
    );
    final Map<String, double> sessionContextScores = Map<String, double>.from(
      _cloudPreferenceProfile.sessionContextScores,
    );
    final Map<String, double> sourceWeights = Map<String, double>.from(
      _defaultRecommendationSourceWeights(),
    )..addAll(_cloudPreferenceProfile.sourceWeights);

    void addSongFeatureSignals(
      LibrarySong song,
      double weight, {
      required Map<String, double> artistTarget,
      required Map<String, double> genreTarget,
      required Map<String, double> moodTarget,
      required Map<String, double> languageTarget,
      required Map<String, double> yearTarget,
      double artistMultiplier = 1,
      double genreMultiplier = 1,
      double moodMultiplier = 1,
      double languageMultiplier = 1,
      double yearMultiplier = 1,
    }) {
      final String artistKey = _normalizeToken(song.artist);
      if (artistKey.isNotEmpty && artistKey != 'unknown artist') {
        _addScore(artistTarget, artistKey, weight * artistMultiplier);
      }

      final String genreKey = _normalizeToken(song.genre ?? '');
      if (genreKey.isNotEmpty) {
        _addScore(genreTarget, genreKey, weight * genreMultiplier);
      }

      for (final String mood in _vibeTokens(song)) {
        _addScore(moodTarget, mood, weight * moodMultiplier);
      }

      final _LanguageDetection language = _detectSongLanguageSignal(song);
      if (_shouldUseLanguageSignal(language)) {
        _addScore(
          languageTarget,
          language.code,
          weight * languageMultiplier * language.confidence,
        );
      }
      final String? yearKey = _songYearKey(song);
      if (yearKey != null) {
        _addScore(yearTarget, yearKey, weight * yearMultiplier);
      }
    }

    void addPositiveSignals(
      LibrarySong song,
      double weight, {
      double artistMultiplier = 1,
      double genreMultiplier = 1,
      double moodMultiplier = 1,
      double languageMultiplier = 1,
      double yearMultiplier = 1,
      bool trackRecent = false,
      String? sessionKey,
    }) {
      addSongFeatureSignals(
        song,
        weight,
        artistTarget: artistScores,
        genreTarget: genreScores,
        moodTarget: moodScores,
        languageTarget: languageScores,
        yearTarget: yearScores,
        artistMultiplier: artistMultiplier,
        genreMultiplier: genreMultiplier,
        moodMultiplier: moodMultiplier,
        languageMultiplier: languageMultiplier,
        yearMultiplier: yearMultiplier,
      );

      final _LanguageDetection language = _detectSongLanguageSignal(song);
      if (_shouldUseLanguageSignal(language)) {
        _addScore(
          languageConfidenceScores,
          language.code,
          language.confidence * math.min(weight, 3),
        );
      }
      _addScore(energyScores, _energyBucketForSong(song), weight);
      if (sessionKey != null && sessionKey.isNotEmpty) {
        _addScore(sessionContextScores, sessionKey, weight);
      }
      if (trackRecent) {
        addSongFeatureSignals(
          song,
          weight,
          artistTarget: recentArtistScores,
          genreTarget: recentGenreScores,
          moodTarget: recentMoodScores,
          languageTarget: recentLanguageScores,
          yearTarget: recentYearScores,
          artistMultiplier: artistMultiplier,
          genreMultiplier: genreMultiplier,
          moodMultiplier: moodMultiplier,
          languageMultiplier: languageMultiplier,
          yearMultiplier: yearMultiplier,
        );
      }
    }

    void addNegativeSignals(
      LibrarySong song,
      double weight, {
      double artistMultiplier = 1,
      double genreMultiplier = 1,
      double moodMultiplier = 1,
      double languageMultiplier = 1,
      double yearMultiplier = 1,
      bool trackSkip = false,
    }) {
      addSongFeatureSignals(
        song,
        weight,
        artistTarget: avoidedArtistScores,
        genreTarget: avoidedGenreScores,
        moodTarget: avoidedMoodScores,
        languageTarget: avoidedLanguageScores,
        yearTarget: avoidedYearScores,
        artistMultiplier: artistMultiplier,
        genreMultiplier: genreMultiplier,
        moodMultiplier: moodMultiplier,
        languageMultiplier: languageMultiplier,
        yearMultiplier: yearMultiplier,
      );
      if (trackSkip) {
        addSongFeatureSignals(
          song,
          weight,
          artistTarget: skipArtistScores,
          genreTarget: skipGenreScores,
          moodTarget: skipMoodScores,
          languageTarget: skipLanguageScores,
          yearTarget: skipYearScores,
          artistMultiplier: artistMultiplier,
          genreMultiplier: genreMultiplier,
          moodMultiplier: moodMultiplier,
          languageMultiplier: languageMultiplier,
          yearMultiplier: yearMultiplier,
        );
      }
    }

    final Map<String, int> playlistAddCounts = <String, int>{};
    for (final UserPlaylist playlist in _playlists) {
      if (!playlist.songIdsComplete) {
        continue;
      }
      for (final String songId in playlist.songIds) {
        playlistAddCounts[songId] = (playlistAddCounts[songId] ?? 0) + 1;
      }
    }

    for (final LibrarySong song in _rankedPreferenceSongs().take(60)) {
      final DateTime reference = song.lastPlayedAt ?? song.addedAt;
      final double recency = _timeDecayWeight(reference, halfLifeDays: 24);
      final double baseWeight =
          _songPreferenceWeight(song) *
          recency *
          (sourceWeights['taste_seed'] ?? 1.0);
      addPositiveSignals(
        song,
        baseWeight,
        artistMultiplier: 1.25,
        genreMultiplier: 1.0,
        moodMultiplier: 0.95,
        languageMultiplier: 0.85,
        yearMultiplier: 1.2,
        trackRecent: recency >= 0.72,
      );
    }

    final List<PlaybackEntry> recentHistory = _history
        .take(180)
        .toList(growable: false);
    for (final PlaybackEntry entry in recentHistory) {
      final LibrarySong? song = songById(entry.songId);
      if (song == null || !song.isRemote || song.isDisliked) {
        continue;
      }
      final double recency = _timeDecayWeight(entry.playedAt, halfLifeDays: 18);
      final String sessionKey = _sessionContextAt(
        entry.playedAt,
      ).label.toLowerCase();
      if (entry.listenedToEnd || entry.completionRatio >= 0.88) {
        final double positiveWeight =
            (entry.listenedToEnd ? 4.2 : 2.7) *
            recency *
            (entry.listenedToEnd
                ? (sourceWeights['full_listen'] ?? 1.0)
                : (sourceWeights['recent_full_listen'] ?? 1.15)) *
            math.max(0.65, entry.completionRatio.clamp(0, 1));
        addPositiveSignals(
          song,
          positiveWeight,
          artistMultiplier: 1.25,
          genreMultiplier: 1.0,
          moodMultiplier: 1.15,
          languageMultiplier: 1.1,
          yearMultiplier: 1.2,
          trackRecent: true,
          sessionKey: sessionKey,
        );
      } else if (entry.completionRatio < 0.45) {
        final double negativeWeight =
            (1.1 - entry.completionRatio.clamp(0, 1)) *
            3.8 *
            recency *
            (sourceWeights['skip'] ?? 1.05);
        addNegativeSignals(
          song,
          negativeWeight,
          artistMultiplier: 0.8,
          genreMultiplier: 1.0,
          moodMultiplier: 1.05,
          languageMultiplier: 0.9,
          yearMultiplier: 1.0,
          trackSkip: true,
        );
      }
    }

    for (final LibrarySong song in _decisionLikedSongs.take(40)) {
      final DateTime reference = song.lastPlayedAt ?? song.addedAt;
      final double recency = _timeDecayWeight(reference, halfLifeDays: 40);
      addPositiveSignals(
        song,
        8.5 * recency * (sourceWeights['like'] ?? 1.3),
        artistMultiplier: _likedArtistRankMultiplier,
        genreMultiplier: 1.05,
        moodMultiplier: 1.05,
        languageMultiplier: 0.85,
        yearMultiplier: 1.0,
        trackRecent: recency >= 0.68,
      );
    }

    for (final LibrarySong song in _decisionDislikedSongs.take(40)) {
      final DateTime reference = song.lastPlayedAt ?? song.addedAt;
      final double recency = _timeDecayWeight(reference, halfLifeDays: 40);
      addNegativeSignals(
        song,
        10.5 * recency * (sourceWeights['dislike'] ?? 1.45),
        artistMultiplier: 1.75,
        genreMultiplier: 1.15,
        moodMultiplier: 1.2,
        languageMultiplier: 0.9,
        yearMultiplier: 1.2,
        trackSkip: true,
      );
    }

    for (final MapEntry<String, int> entry in playlistAddCounts.entries) {
      final LibrarySong? song = songById(entry.key);
      if (song == null || !song.isRemote || song.isDisliked) {
        continue;
      }
      final double recency = _timeDecayWeight(
        song.lastPlayedAt ?? song.addedAt,
        halfLifeDays: 50,
      );
      addPositiveSignals(
        song,
        entry.value * recency * 2.2 * (sourceWeights['playlist_add'] ?? 1.1),
        artistMultiplier: 1.1,
        genreMultiplier: 1.0,
        moodMultiplier: 1.0,
        languageMultiplier: 0.8,
        yearMultiplier: 0.95,
      );
    }

    final Map<String, double> netArtistScores = _netScoreMap(
      positive: artistScores,
      negative: avoidedArtistScores,
      negativeWeight: 1.15,
    );
    final Map<String, double> netGenreScores = _netScoreMap(
      positive: genreScores,
      negative: avoidedGenreScores,
      negativeWeight: 1.1,
    );
    final Map<String, double> netMoodScores = _netScoreMap(
      positive: moodScores,
      negative: avoidedMoodScores,
      negativeWeight: 1.1,
    );
    final List<String> artistOrder = _topScoreKeys(netArtistScores, limit: 6);
    final List<String> genreOrder = _topScoreKeys(netGenreScores, limit: 5);
    final List<String> moodOrder = _topScoreKeys(netMoodScores, limit: 4);
    final List<String> recentArtistOrder = _topScoreKeys(
      recentArtistScores,
      limit: 6,
    );
    final String regionalLanguage = preferredRegion.languageCode.trim();
    final String forcedLanguage = regionalLanguage.isEmpty
        ? 'unknown'
        : regionalLanguage;
    final Map<String, double> forcedLanguagePositiveScores =
        forcedLanguage == 'unknown'
        ? const <String, double>{}
        : <String, double>{forcedLanguage: 1.0};
    final Map<String, double> forcedLanguageNeutralScores =
        forcedLanguage == 'unknown'
        ? const <String, double>{}
        : <String, double>{forcedLanguage: 0.0};
    final int currentYear = DateTime.now().year;
    final String currentYearKey = '$currentYear';
    final Map<String, double> currentYearPositiveScores = <String, double>{
      currentYearKey: 1.0,
    };
    final Map<String, double> currentYearNeutralScores = <String, double>{
      currentYearKey: 0.0,
    };
    final Set<String> repeatedSongs = <String>{};
    final Set<String> seenSongs = <String>{};
    int positiveKnownPlays = 0;
    int positiveFreshPlays = 0;
    double mainstreamPositiveWeight = 0;
    double independentPositiveWeight = 0;
    for (final PlaybackEntry entry in recentHistory.take(80)) {
      final LibrarySong? song = songById(entry.songId);
      if (song == null || !song.isRemote || song.isDisliked) {
        continue;
      }
      final bool positive =
          entry.listenedToEnd || entry.completionRatio >= 0.88;
      if (!positive) {
        continue;
      }
      if (!seenSongs.add(song.id)) {
        repeatedSongs.add(song.id);
      }
      if (song.playCount > 0 || _completionAffinity(song.id) >= 0.65) {
        positiveKnownPlays += 1;
      } else {
        positiveFreshPlays += 1;
      }
      if (song.sourceLabel == 'Online Music' ||
          song.sourceLabel == 'YouTube Music') {
        mainstreamPositiveWeight += 1.2;
      } else if (song.sourceLabel == 'Online Stream' ||
          song.sourceLabel == 'YouTube' ||
          song.sourceLabel == 'URL') {
        independentPositiveWeight += 1.0;
      }
    }
    final double noveltyPreference = _normalizedPreference(
      (positiveFreshPlays /
                  math.max(1, positiveFreshPlays + positiveKnownPlays) +
              (1 - _familiarityNeed())) /
          2,
    );
    final double repeatAffinity = _normalizedPreference(
      repeatedSongs.length / math.max(1, seenSongs.length),
    );
    final double popularityPreference = _normalizedPreference(
      mainstreamPositiveWeight /
          math.max(1, mainstreamPositiveWeight + independentPositiveWeight),
    );

    return _TasteProfile(
      artistKeys: artistOrder.toSet(),
      genreKeys: genreOrder.toSet(),
      moodKeys: moodOrder.toSet(),
      languageKeys: forcedLanguage == 'unknown'
          ? const <String>{}
          : <String>{forcedLanguage},
      yearKeys: <String>{currentYearKey},
      prefersRecentYears: true,
      artistScores: _trimScoreMap(netArtistScores, limit: 12),
      genreScores: _trimScoreMap(netGenreScores, limit: 10),
      moodScores: _trimScoreMap(netMoodScores, limit: 8),
      languageScores: forcedLanguagePositiveScores,
      languageConfidenceScores: forcedLanguagePositiveScores,
      yearScores: currentYearPositiveScores,
      avoidedArtistScores: _trimScoreMap(avoidedArtistScores, limit: 8),
      avoidedGenreScores: _trimScoreMap(avoidedGenreScores, limit: 8),
      avoidedMoodScores: _trimScoreMap(avoidedMoodScores, limit: 8),
      avoidedLanguageScores: forcedLanguageNeutralScores,
      avoidedYearScores: currentYearNeutralScores,
      recentArtistScores: _trimScoreMap(recentArtistScores, limit: 8),
      recentGenreScores: _trimScoreMap(recentGenreScores, limit: 6),
      recentMoodScores: _trimScoreMap(recentMoodScores, limit: 6),
      recentLanguageScores: forcedLanguagePositiveScores,
      recentYearScores: currentYearPositiveScores,
      skipArtistScores: _trimScoreMap(skipArtistScores, limit: 8),
      skipGenreScores: _trimScoreMap(skipGenreScores, limit: 6),
      skipMoodScores: _trimScoreMap(skipMoodScores, limit: 6),
      skipLanguageScores: forcedLanguageNeutralScores,
      skipYearScores: currentYearNeutralScores,
      energyScores: _trimScoreMap(energyScores, limit: 3),
      sessionContextScores: _trimScoreMap(sessionContextScores, limit: 5),
      sourceWeights: {
        for (final String key in _topScoreKeys(sourceWeights, limit: 12))
          key: sourceWeights[key] ?? 0,
      },
      noveltyPreference:
          recentArtistOrder.isEmpty &&
              _cloudPreferenceProfile.completedListenCount > 0
          ? _cloudPreferenceProfile.noveltyPreference
          : noveltyPreference,
      popularityPreference:
          mainstreamPositiveWeight == 0 && independentPositiveWeight == 0
          ? _cloudPreferenceProfile.popularityPreference
          : popularityPreference,
      repeatAffinity:
          repeatedSongs.isEmpty &&
              _cloudPreferenceProfile.completedListenCount > 0
          ? _cloudPreferenceProfile.repeatAffinity
          : repeatAffinity,
      primaryLanguage: forcedLanguage,
      secondaryLanguages: const <String>{},
      preferredYearFloor: currentYear,
    );
  }

  CloudPreferenceProfile _buildCloudPreferenceProfileForSync() {
    final _TasteProfile tasteProfile = _buildTasteProfile();
    return CloudPreferenceProfile(
      profileVersion: _recommendationProfileVersion,
      artistKeys: tasteProfile.artistKeys.take(6).toSet(),
      artistKeyOrder: tasteProfile.artistKeys.take(6).toList(growable: false),
      genreKeys: tasteProfile.genreKeys.take(5).toSet(),
      moodKeys: tasteProfile.moodKeys.take(4).toSet(),
      languageKeys: tasteProfile.languageKeys.take(3).toSet(),
      yearKeys: tasteProfile.yearKeys.take(4).toSet(),
      prefersRecentYears: tasteProfile.prefersRecentYears,
      completedListenCount: validPlaybackHistory.length,
      artistScores: _trimScoreMap(tasteProfile.artistScores, limit: 10),
      genreScores: _trimScoreMap(tasteProfile.genreScores, limit: 8),
      moodScores: _trimScoreMap(tasteProfile.moodScores, limit: 6),
      languageScores: _trimScoreMap(tasteProfile.languageScores, limit: 4),
      languageConfidenceScores: _trimScoreMap(
        tasteProfile.languageConfidenceScores,
        limit: 4,
      ),
      yearScores: _trimScoreMap(tasteProfile.yearScores, limit: 6),
      avoidedArtistScores: _trimScoreMap(
        tasteProfile.avoidedArtistScores,
        limit: 6,
      ),
      avoidedGenreScores: _trimScoreMap(
        tasteProfile.avoidedGenreScores,
        limit: 6,
      ),
      avoidedMoodScores: _trimScoreMap(
        tasteProfile.avoidedMoodScores,
        limit: 6,
      ),
      avoidedLanguageScores: _trimScoreMap(
        tasteProfile.avoidedLanguageScores,
        limit: 4,
      ),
      avoidedYearScores: _trimScoreMap(
        tasteProfile.avoidedYearScores,
        limit: 4,
      ),
      recentArtistScores: _trimScoreMap(
        tasteProfile.recentArtistScores,
        limit: 6,
      ),
      recentGenreScores: _trimScoreMap(
        tasteProfile.recentGenreScores,
        limit: 5,
      ),
      recentMoodScores: _trimScoreMap(tasteProfile.recentMoodScores, limit: 5),
      recentLanguageScores: _trimScoreMap(
        tasteProfile.recentLanguageScores,
        limit: 4,
      ),
      recentYearScores: _trimScoreMap(tasteProfile.recentYearScores, limit: 4),
      skipArtistScores: _trimScoreMap(tasteProfile.skipArtistScores, limit: 6),
      skipGenreScores: _trimScoreMap(tasteProfile.skipGenreScores, limit: 5),
      skipMoodScores: _trimScoreMap(tasteProfile.skipMoodScores, limit: 5),
      skipLanguageScores: _trimScoreMap(
        tasteProfile.skipLanguageScores,
        limit: 4,
      ),
      skipYearScores: _trimScoreMap(tasteProfile.skipYearScores, limit: 4),
      energyScores: _trimScoreMap(tasteProfile.energyScores, limit: 3),
      sessionContextScores: _trimScoreMap(
        tasteProfile.sessionContextScores,
        limit: 5,
      ),
      sourceWeights: _trimScoreMap(tasteProfile.sourceWeights, limit: 12),
      noveltyPreference: tasteProfile.noveltyPreference,
      popularityPreference: tasteProfile.popularityPreference,
      repeatAffinity: tasteProfile.repeatAffinity,
      primaryLanguage: tasteProfile.primaryLanguage,
      secondaryLanguages: tasteProfile.secondaryLanguages,
      preferredYearFloor: tasteProfile.preferredYearFloor,
    );
  }

  void _addScore(Map<String, double> target, String key, double value) {
    final String normalizedKey = key.trim();
    if (normalizedKey.isEmpty || value <= 0) {
      return;
    }
    target[normalizedKey] = (target[normalizedKey] ?? 0) + value;
  }

  double _timeDecayWeight(DateTime timestamp, {double halfLifeDays = 21}) {
    final double ageDays = math.max(
      0,
      DateTime.now().difference(timestamp).inHours / 24,
    );
    return math.pow(0.5, ageDays / halfLifeDays).toDouble().clamp(0.2, 1.0);
  }

  Map<String, double> _netScoreMap({
    required Map<String, double> positive,
    required Map<String, double> negative,
    double negativeWeight = 1,
  }) {
    final Set<String> keys = <String>{...positive.keys, ...negative.keys};
    final Map<String, double> result = <String, double>{};
    for (final String key in keys) {
      final double net =
          (positive[key] ?? 0) - ((negative[key] ?? 0) * negativeWeight);
      if (net > 0.15) {
        result[key] = net;
      }
    }
    return result;
  }

  List<String> _topScoreKeys(Map<String, double> values, {required int limit}) {
    final List<MapEntry<String, double>> sorted = values.entries.toList()
      ..sort(
        (MapEntry<String, double> a, MapEntry<String, double> b) =>
            b.value.compareTo(a.value),
      );
    return sorted
        .where((MapEntry<String, double> entry) => entry.key.isNotEmpty)
        .take(limit)
        .map((MapEntry<String, double> entry) => entry.key)
        .toList(growable: false);
  }

  Map<String, double> _trimScoreMap(
    Map<String, double> values, {
    required int limit,
  }) {
    final List<String> keys = _topScoreKeys(values, limit: limit);
    return <String, double>{
      for (final String key in keys) key: (values[key] ?? 0),
    };
  }

  String? _songYearKey(LibrarySong song) {
    final int? year = song.year;
    if (year == null || year <= 0) {
      return null;
    }
    return '$year';
  }

  bool _isExploratoryCandidate(
    LibrarySong song, {
    required _TasteProfile profile,
    required String artistKey,
    required Set<String> fullListenArtistKeys,
    required Set<String> likedArtistKeys,
  }) {
    final bool knownArtist =
        likedArtistKeys.contains(artistKey) ||
        fullListenArtistKeys.contains(artistKey) ||
        profile.artistKeys.contains(artistKey);
    final bool knownGenre = profile.genreKeys.contains(
      _normalizeToken(song.genre ?? ''),
    );
    final bool knownMood = profile.moodKeys
        .intersection(_vibeTokens(song))
        .isNotEmpty;
    return !knownArtist || (!knownGenre && !knownMood);
  }

  List<SongRecommendation> _selectPersonalizedRecommendations(
    List<_ScoredRecommendation> scored, {
    int limit = 50,
  }) {
    final List<_ScoredRecommendation> familiar =
        scored.where((item) => !item.isExploratory).toList(growable: false)
          ..sort(_compareScoredRecommendations);
    final List<_ScoredRecommendation> exploratory =
        scored.where((item) => item.isExploratory).toList(growable: false)
          ..sort(_compareScoredRecommendations);

    final Map<String, int> artistCounts = <String, int>{};
    final Set<String> seenKeys = <String>{};
    final List<SongRecommendation> result = <SongRecommendation>[];
    final int targetTotal = math.min(limit, scored.length);
    final int exploratoryTarget = math.min(
      exploratory.length,
      math.max(1, (targetTotal * 0.25).round()),
    );
    final int familiarTarget = math.max(0, targetTotal - exploratoryTarget);

    void addFrom(List<_ScoredRecommendation> pool, int target) {
      for (final _ScoredRecommendation item in pool) {
        if (result.length >= targetTotal || target <= 0) {
          return;
        }
        final String key = _songIdentityKey(item.song);
        final String artistKey = _normalizeToken(item.song.artist);
        if (!seenKeys.add(key)) {
          continue;
        }
        if ((artistCounts[artistKey] ?? 0) >= 2) {
          continue;
        }
        result.add(
          SongRecommendation(
            song: item.song,
            reason: item.reason,
            isExploratory: item.isExploratory,
          ),
        );
        artistCounts[artistKey] = (artistCounts[artistKey] ?? 0) + 1;
        target -= 1;
      }
    }

    addFrom(familiar, familiarTarget);
    addFrom(exploratory, exploratoryTarget);
    addFrom(
      <_ScoredRecommendation>[...familiar, ...exploratory]
        ..sort(_compareScoredRecommendations),
      targetTotal - result.length,
    );

    return result;
  }

  int _compareScoredRecommendations(
    _ScoredRecommendation a,
    _ScoredRecommendation b,
  ) {
    final int scoreCompare = b.score.compareTo(a.score);
    if (scoreCompare != 0) {
      return scoreCompare;
    }
    return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
  }

  String _recommendationReason(
    LibrarySong song, {
    required _TasteProfile profile,
    required bool exploratory,
    required HomeFeedSection? section,
    required String artistKey,
    required Set<String> likedArtistKeys,
    required Set<String> fullListenArtistKeys,
  }) {
    if (likedArtistKeys.contains(artistKey) ||
        fullListenArtistKeys.contains(artistKey)) {
      return 'Artist match with your repeat listens';
    }
    final String genreKey = _normalizeToken(song.genre ?? '');
    if (profile.genreKeys.contains(genreKey) &&
        profile.moodKeys.intersection(_vibeTokens(song)).isNotEmpty) {
      return 'Genre and mood match for your listening pattern';
    }
    final _LanguageDetection languageSignal = _detectSongLanguageSignal(song);
    if (_shouldUseLanguageSignal(languageSignal) &&
        profile.languageKeys.contains(languageSignal.code)) {
      return exploratory
          ? 'Fresh pick in a language you finish often'
          : 'Language match from your full-listen history';
    }
    if (section != null && section.title.trim().isNotEmpty) {
      return exploratory
          ? 'Discovery pull from ${section.title}'
          : 'Strong fit surfaced in ${section.title}';
    }
    return exploratory
        ? 'Discovery pick close to your usual vibe'
        : 'Fits the sound you usually stay with';
  }

  bool _isConnectivityError(Object error) {
    if (error is SocketException || error is TimeoutException) {
      return true;
    }
    final String message = '$error'.toLowerCase();
    return message.contains('failed host lookup') ||
        message.contains('network is unreachable') ||
        message.contains('connection refused') ||
        message.contains('socketexception');
  }

  void _setConnectivityOffline(
    bool value, {
    bool notify = true,
    bool announceLoss = false,
  }) {
    if (_isOffline == value) {
      return;
    }
    _isOffline = value;
    if (value && announceLoss && !_startupOfflineMode && !offlineMusicMode) {
      _connectivityMessage =
          'Connection lost. Online features may not work until internet returns.';
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _setStartupOfflineMode(bool value, {bool notify = true}) {
    if (_startupOfflineMode == value) {
      return;
    }
    _startupOfflineMode = value;
    if (notify) {
      notifyListeners();
    }
  }

  List<_RecommendationQuery> _buildPredictionQueries(LibrarySong anchor) {
    final List<_TasteSignal> artists = _preferenceArtists();
    final List<_LanguageSignal> languages =
        _preferredLanguagesFromValidHistory();
    final _TasteProfile profile = _buildTasteProfile();
    final _SessionContext session = _sessionContext();
    final String anchorLanguage = _anchorRecommendationLanguage(anchor);
    final String languageToken = anchorLanguage == 'unknown'
        ? ''
        : _languageQueryToken(anchorLanguage);
    String composeQuery(List<String> parts) {
      return parts
          .map((String part) => part.trim())
          .where((String part) => part.isNotEmpty)
          .join(' ');
    }

    final List<_RecommendationQuery> queries = <_RecommendationQuery>[
      _RecommendationQuery(
        title: 'Related to ${anchor.title}',
        subtitle: 'Auto queue',
        query: composeQuery(<String>[
          anchor.artist,
          anchor.title,
          languageToken,
          'song radio',
        ]),
        anchor: anchor,
      ),
      _RecommendationQuery(
        title: 'More from ${anchor.artist}',
        subtitle: 'Auto queue',
        query: composeQuery(<String>[
          anchor.artist,
          languageToken,
          'popular songs',
        ]),
        anchor: anchor,
      ),
    ];

    if ((anchor.genre ?? '').trim().isNotEmpty) {
      queries.add(
        _RecommendationQuery(
          title: '${anchor.genre} mix',
          subtitle: 'Auto queue',
          query: composeQuery(<String>[
            languageToken,
            anchor.genre ?? '',
            anchor.artist,
            'songs',
          ]),
          anchor: anchor,
        ),
      );
    }

    final String topGenre = profile.genreKeys.firstOrNull ?? '';
    if (topGenre.isNotEmpty &&
        topGenre != _normalizeToken(anchor.genre ?? '')) {
      queries.add(
        _RecommendationQuery(
          title: 'Your $topGenre lane',
          subtitle: 'Auto queue',
          query: composeQuery(<String>[
            anchor.artist,
            languageToken,
            topGenre,
            'songs',
          ]),
          anchor: anchor,
        ),
      );
    }

    final String topMood = profile.moodKeys.firstOrNull ?? '';
    if (topMood.isNotEmpty) {
      queries.add(
        _RecommendationQuery(
          title: '$topMood flow',
          subtitle: 'Auto queue',
          query: composeQuery(<String>[
            anchor.artist,
            languageToken,
            topMood,
            'songs',
          ]),
          anchor: anchor,
        ),
      );
    }

    for (final _TasteSignal artist in artists.take(2)) {
      if (_normalizeToken(artist.label) == _normalizeToken(anchor.artist)) {
        continue;
      }
      queries.add(
        _RecommendationQuery(
          title: 'Matches your taste',
          subtitle: 'Auto queue',
          query: composeQuery(<String>[
            artist.label,
            languageToken,
            'top songs',
          ]),
          anchor: anchor,
        ),
      );
    }

    if (anchorLanguage == 'unknown') {
      for (final _LanguageSignal language in languages.take(1)) {
        queries.add(
          _RecommendationQuery(
            title: '${language.label} queue',
            subtitle: 'Auto queue',
            query: composeQuery(<String>[
              anchor.artist,
              language.queryToken,
              'songs',
            ]),
            anchor: anchor,
          ),
        );
      }
    }
    if (anchorLanguage == 'unknown' &&
        profile.primaryLanguage.isNotEmpty &&
        profile.primaryLanguage != 'unknown') {
      queries.add(
        _RecommendationQuery(
          title: '${_languageLabel(profile.primaryLanguage)} pulse',
          subtitle: 'Auto queue',
          query: composeQuery(<String>[
            anchor.artist,
            _languageQueryToken(profile.primaryLanguage),
            topMood.isEmpty ? 'songs' : '$topMood songs',
          ]),
          anchor: anchor,
        ),
      );
    }
    final String topYear = profile.yearKeys.firstOrNull ?? '';
    if (topYear.isNotEmpty) {
      queries.add(
        _RecommendationQuery(
          title: '$topYear picks',
          subtitle: 'Auto queue',
          query: composeQuery(<String>[anchor.artist, topYear, 'songs']),
          anchor: anchor,
        ),
      );
    }
    queries.add(
      _RecommendationQuery(
        title: '${session.label} flow',
        subtitle: 'Auto queue',
        query: composeQuery(<String>[anchor.artist, session.query, 'songs']),
        anchor: anchor,
      ),
    );

    queries.add(
      _RecommendationQuery(
        title: 'Fallback mix',
        subtitle: 'Auto queue',
        query: composeQuery(<String>[languageToken, 'trending songs']),
        anchor: anchor,
      ),
    );
    return queries;
  }

  List<LibrarySong> _rankRecommendedSongs(
    List<LibrarySong> songs, {
    LibrarySong? anchor,
    Set<String>? excludedIds,
    int limit = 10,
  }) {
    final Set<String> blockedIds = excludedIds ?? <String>{};
    final _TasteProfile profile = _buildTasteProfile();
    final Set<String> seenKeys = <String>{};
    final List<_ScoredSong> ranked = <_ScoredSong>[];

    for (final LibrarySong song in songs) {
      if (blockedIds.contains(song.id)) {
        continue;
      }
      if (!_shouldUseSongInHomeOrSmartQueue(song)) {
        continue;
      }
      if (song.isDisliked) {
        continue;
      }
      if (_isStronglyAvoidedCandidate(song, profile: profile)) {
        continue;
      }
      if (!_shouldKeepCandidateForLanguage(
        song,
        anchor: anchor,
        profile: profile,
      )) {
        continue;
      }

      final String key = _songIdentityKey(song);
      if (!seenKeys.add(key)) {
        continue;
      }

      if (anchor != null && _sameSong(anchor, song)) {
        continue;
      }

      ranked.add(
        _ScoredSong(
          song,
          _recommendationScore(song, anchor: anchor, profile: profile),
        ),
      );
    }

    ranked.sort((_ScoredSong a, _ScoredSong b) {
      final int scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return a.song.title.toLowerCase().compareTo(b.song.title.toLowerCase());
    });

    return _spaceArtistsInRankedSongs(
      ranked,
    ).take(limit).map((_ScoredSong item) => item.song).toList(growable: false);
  }

  double _recommendationScore(
    LibrarySong song, {
    LibrarySong? anchor,
    _TasteProfile? profile,
  }) {
    final _TasteProfile tasteProfile = profile ?? _buildTasteProfile();
    if (song.isDisliked) {
      return -1000000;
    }
    double score = song.playCount.toDouble();
    if (song.isLiked) {
      score += 18;
    }
    final String title = _normalizeToken(song.title);
    final String artist = _normalizeToken(song.artist);
    final String genre = _normalizeToken(song.genre ?? '');
    final _LanguageDetection languageSignal = _detectSongLanguageSignal(song);
    final String language = languageSignal.code;
    final _SessionContext session = _sessionContext();
    final Set<String> recentQueueArtists = _recentQueueArtistKeys();
    final Set<String> recentQueueSongs = _recentQueueSongKeys();
    final Set<String> songMoods = _vibeTokens(song);
    final _LanguageDetection? anchorLanguageSignal = anchor == null
        ? null
        : _detectSongLanguageSignal(anchor);
    final bool hasReliableAnchorLanguage =
        anchorLanguageSignal != null &&
        _shouldUseLanguageSignal(anchorLanguageSignal);
    final String anchorLanguage = hasReliableAnchorLanguage
        ? anchorLanguageSignal.code
        : 'unknown';

    if (anchor != null) {
      final String anchorTitle = _normalizeToken(anchor.title);
      final String anchorArtist = _normalizeToken(anchor.artist);
      if (artist == anchorArtist) {
        score += 9;
      } else if (artist.contains(anchorArtist) ||
          anchorArtist.contains(artist)) {
        score += 4;
      }

      if (title.contains(anchorTitle) || anchorTitle.contains(title)) {
        score -= 6;
      }
      if (hasReliableAnchorLanguage && language == anchorLanguage) {
        score +=
            5.6 *
            math.min(
              languageSignal.confidence,
              anchorLanguageSignal.confidence,
            );
      } else if (anchorLanguage != 'unknown' &&
          language == 'en' &&
          languageSignal.confidence >= _strictLanguageGateConfidence) {
        score -= anchorLanguage == 'en' ? 0 : 18;
      }
      score += _vibeSimilarityScore(anchor, song);
    }

    for (final _TasteSignal taste in _preferenceArtists().take(4)) {
      final String preferredArtist = _normalizeToken(taste.label);
      if (artist == preferredArtist) {
        score += taste.score * 3;
      } else if (artist.contains(preferredArtist) ||
          preferredArtist.contains(artist)) {
        score += taste.score * 1.4;
      }
    }

    score += tasteProfile.artistAffinity(artist) * 2.6;
    score += tasteProfile.genreAffinity(genre) * 2.1;
    score += tasteProfile.recentArtistAffinity(artist) * 1.6;
    score += tasteProfile.recentGenreAffinity(genre) * 1.2;
    if (_shouldUseLanguageSignal(languageSignal) &&
        (!hasReliableAnchorLanguage || language == anchorLanguage)) {
      score +=
          tasteProfile.languageAffinity(language) *
          3.1 *
          languageSignal.confidence;
      score +=
          tasteProfile.recentLanguageAffinity(language) *
          1.8 *
          languageSignal.confidence;
    }
    score += tasteProfile.yearAffinity(song.year) * 2.8;
    score += tasteProfile.recentYearAffinity(song.year) * 1.4;
    for (final String mood in songMoods) {
      score += tasteProfile.moodAffinity(mood) * 1.8;
      score += tasteProfile.recentMoodAffinity(mood) * 1.1;
    }

    score -= tasteProfile.artistAvoidance(artist) * 4.2;
    score -= tasteProfile.genreAvoidance(genre) * 3.2;
    score -= tasteProfile.skipArtistPenalty(artist) * 2.4;
    score -= tasteProfile.skipGenrePenalty(genre) * 1.9;
    if (_shouldUseLanguageSignal(languageSignal) &&
        (!hasReliableAnchorLanguage || language == anchorLanguage)) {
      score -=
          tasteProfile.languageAvoidance(language) *
          2.4 *
          languageSignal.confidence;
      score -=
          tasteProfile.skipLanguagePenalty(language) *
          1.6 *
          languageSignal.confidence;
    }
    score -= tasteProfile.yearAvoidance(song.year) * 2.8;
    score -= tasteProfile.skipYearPenalty(song.year) * 1.8;
    for (final String mood in songMoods) {
      score -= tasteProfile.moodAvoidance(mood) * 2.4;
      score -= tasteProfile.skipMoodPenalty(mood) * 1.6;
    }

    if (!hasReliableAnchorLanguage &&
        language != 'unknown' &&
        language == tasteProfile.primaryLanguage) {
      score += 5.2 * languageSignal.confidence;
    } else if (!hasReliableAnchorLanguage &&
        tasteProfile.secondaryLanguages.contains(language)) {
      score += 2.4 * languageSignal.confidence;
    } else if (hasReliableAnchorLanguage &&
        language != 'unknown' &&
        language == anchorLanguage) {
      score += 4.8 * languageSignal.confidence;
    }

    for (final LibrarySong recent in _validHistorySongs().take(4)) {
      final String recentArtist = _normalizeToken(recent.artist);
      if (artist == recentArtist) {
        score += 2.2;
      }
    }

    final double completionAffinity = _completionAffinity(song.id);
    score += completionAffinity * 10.5;
    if (completionAffinity >= 0.92) {
      score += 2.4;
    }
    if (completionAffinity < 0.25) {
      score -= 5.5;
    }

    // Psychology-inspired balance:
    // - Familiarity (known artists/songs) builds comfort.
    // - Novelty (new but adjacent songs) prevents boredom.
    score += _noveltyBalanceBoost(
      song,
      completionAffinity: completionAffinity,
      profile: tasteProfile,
    );

    final String energyBucket = _energyBucketForSong(song);
    score += tasteProfile.energyAffinity(energyBucket) * 1.4;

    // Avoid fatigue from repeating same artist/song too tightly in queue.
    if (recentQueueArtists.contains(artist)) {
      score -= 7.2 * (1 - (tasteProfile.repeatAffinity * 0.45));
    }
    if (recentQueueSongs.contains(_songIdentityKey(song))) {
      score -= 12 * (1 - (tasteProfile.repeatAffinity * 0.55));
    }

    // Session-aware mood tuning (time/day context) similar to autoplay systems.
    if (_vibeTokens(song).contains(session.vibeToken)) {
      score +=
          2.6 *
          tasteProfile.sourceWeight('session_match') *
          (1 +
              tasteProfile.sessionContextAffinity(session.label.toLowerCase()) *
                  0.08);
    }

    if (song.durationMs > 0) {
      score += 0.4;
      score += _durationContinuityBoost(song, anchor: anchor);
    }

    if (tasteProfile.prefersRecentYears && (song.year ?? 0) >= 2019) {
      score += 1.4;
    } else if (!tasteProfile.prefersRecentYears &&
        song.year != null &&
        song.year! > 0 &&
        song.year! < 2016) {
      score += 1.2;
    }
    score += tasteProfile.preferredYearWindowBoost(song.year);

    if (song.sourceLabel == 'Online Music' ||
        song.sourceLabel == 'YouTube Music') {
      score += (tasteProfile.popularityPreference - 0.5) * 4.0;
    } else if (song.sourceLabel == 'Online Stream' ||
        song.sourceLabel == 'YouTube' ||
        song.sourceLabel == 'URL') {
      score += (0.5 - tasteProfile.popularityPreference) * 2.8;
    }

    return _applyArtistRecommendationMultiplier(
      score,
      _explicitArtistPreferenceMultiplier(artist, profile: tasteProfile),
    );
  }

  bool _isStronglyAvoidedCandidate(
    LibrarySong song, {
    required _TasteProfile profile,
  }) {
    final String artist = _normalizeToken(song.artist);
    final String genre = _normalizeToken(song.genre ?? '');
    final _LanguageDetection languageSignal = _detectSongLanguageSignal(song);
    final String language = languageSignal.code;
    final Set<String> moods = _vibeTokens(song);
    final double positive =
        (profile.artistAffinity(artist) * 2.2) +
        (profile.genreAffinity(genre) * 1.8) +
        (_shouldUseLanguageSignal(languageSignal)
            ? profile.languageAffinity(language) *
                  2.0 *
                  languageSignal.confidence
            : 0) +
        (profile.yearAffinity(song.year) * 1.8) +
        moods.fold<double>(
          0,
          (double sum, String mood) => sum + (profile.moodAffinity(mood) * 1.4),
        );
    final double negative =
        (profile.artistAvoidance(artist) * 5.2) +
        (profile.skipArtistPenalty(artist) * 2.4) +
        (profile.genreAvoidance(genre) * 3.6) +
        (profile.skipGenrePenalty(genre) * 1.8) +
        (_shouldUseLanguageSignal(languageSignal)
            ? profile.languageAvoidance(language) *
                      2.8 *
                      languageSignal.confidence +
                  profile.skipLanguagePenalty(language) *
                      1.4 *
                      languageSignal.confidence
            : 0) +
        (profile.yearAvoidance(song.year) * 2.4) +
        (profile.skipYearPenalty(song.year) * 1.5) +
        moods.fold<double>(
          0,
          (double sum, String mood) =>
              sum +
              (profile.moodAvoidance(mood) * 2.8) +
              (profile.skipMoodPenalty(mood) * 1.4),
        );
    return negative >= math.max(10, positive + 6);
  }

  List<_ScoredSong> _spaceArtistsInRankedSongs(List<_ScoredSong> ranked) {
    final List<_ScoredSong> remaining = List<_ScoredSong>.from(ranked);
    final List<_ScoredSong> result = <_ScoredSong>[];
    while (remaining.isNotEmpty) {
      final Set<String> blockedArtists = result
          .skip(math.max(0, result.length - 2))
          .map((_ScoredSong item) => _normalizeToken(item.song.artist))
          .where((String artist) => artist.isNotEmpty)
          .toSet();
      final int candidateIndex = remaining.indexWhere(
        (_ScoredSong item) =>
            !blockedArtists.contains(_normalizeToken(item.song.artist)),
      );
      result.add(remaining.removeAt(candidateIndex >= 0 ? candidateIndex : 0));
    }
    return result;
  }

  double _completionAffinity(String songId) {
    double total = 0;
    double weighted = 0;
    for (final PlaybackEntry entry in _history.take(220)) {
      if (entry.songId != songId) {
        continue;
      }
      final double weight = entry.listenedToEnd ? 1.4 : 1;
      total += weight;
      weighted += weight * entry.completionRatio.clamp(0, 1);
    }
    if (total <= 0) {
      return 0.5;
    }
    return (weighted / total).clamp(0, 1);
  }

  double _noveltyBalanceBoost(
    LibrarySong song, {
    required double completionAffinity,
    required _TasteProfile profile,
  }) {
    final bool known = song.playCount > 0 || completionAffinity >= 0.65;
    final bool fresh = song.playCount == 0 && completionAffinity < 0.45;
    final double familiarityNeed =
        ((_familiarityNeed()) + (1 - profile.noveltyPreference)) / 2;
    if (known) {
      return (3.0 + (profile.repeatAffinity * 1.8)) * familiarityNeed;
    }
    if (fresh) {
      return (3.0 + (profile.noveltyPreference * 1.8)) * (1 - familiarityNeed);
    }
    return 1.2;
  }

  double _familiarityNeed() {
    final List<PlaybackEntry> recent = validPlaybackHistory
        .take(30)
        .toList(growable: false);
    if (recent.isEmpty) {
      return 0.55;
    }
    final double avgCompletion =
        recent.fold<double>(
          0,
          (double sum, PlaybackEntry e) => sum + e.completionRatio,
        ) /
        recent.length;
    // If recent completion is low, lean more familiar.
    return (0.75 - (avgCompletion * 0.35)).clamp(0.35, 0.8);
  }

  Set<String> _recentQueueArtistKeys() {
    final int start = math.max(0, _queueIndex - 3);
    final int end = math.min(_queueSongIds.length, _queueIndex + 3);
    final Set<String> result = <String>{};
    for (int i = start; i < end; i += 1) {
      final LibrarySong? song = songById(_queueSongIds[i]);
      if (song == null ||
          !song.isRemote ||
          !shouldShowSongOutsideSearch(song)) {
        continue;
      }
      result.add(_normalizeToken(song.artist));
    }
    return result;
  }

  Set<String> _recentQueueSongKeys() {
    final int start = math.max(0, _queueIndex - 3);
    final int end = math.min(_queueSongIds.length, _queueIndex + 3);
    final Set<String> result = <String>{};
    for (int i = start; i < end; i += 1) {
      final LibrarySong? song = songById(_queueSongIds[i]);
      if (song == null ||
          !song.isRemote ||
          !shouldShowSongOutsideSearch(song)) {
        continue;
      }
      result.add(_songIdentityKey(song));
    }
    return result;
  }

  double _vibeSimilarityScore(LibrarySong anchor, LibrarySong candidate) {
    final Set<String> left = _vibeTokens(anchor);
    final Set<String> right = _vibeTokens(candidate);
    if (left.isEmpty || right.isEmpty) {
      return 0;
    }
    final int overlap = left.intersection(right).length;
    return overlap * 1.7;
  }

  Set<String> _vibeTokens(LibrarySong song) {
    final String text =
        '${song.title} ${song.artist} ${song.album} ${song.genre ?? ''}'
            .toLowerCase();
    const Map<String, List<String>> map = <String, List<String>>{
      'chill': <String>['chill', 'calm', 'ambient', 'lofi', 'acoustic', 'soft'],
      'focus': <String>['focus', 'study', 'instrumental', 'piano'],
      'energy': <String>['party', 'dance', 'edm', 'remix', 'club', 'hype'],
      'sad': <String>['sad', 'heartbreak', 'broken', 'lonely'],
      'romance': <String>['love', 'romance', 'feel', 'kiss'],
      'devotional': <String>['worship', 'devotional', 'spiritual', 'bhakti'],
    };
    final Set<String> result = <String>{};
    for (final MapEntry<String, List<String>> entry in map.entries) {
      if (entry.value.any(text.contains)) {
        result.add(entry.key);
      }
    }
    return result;
  }

  String _energyBucketForSong(LibrarySong song) {
    final Set<String> moods = _vibeTokens(song);
    if (moods.contains('energy')) {
      return 'high';
    }
    if (moods.contains('chill') ||
        moods.contains('focus') ||
        moods.contains('sad') ||
        moods.contains('devotional')) {
      return 'low';
    }
    return 'mid';
  }

  double _durationContinuityBoost(LibrarySong song, {LibrarySong? anchor}) {
    final int seconds = song.duration.inSeconds;
    if (seconds <= 0) {
      return 0;
    }
    if (anchor == null || anchor.duration.inSeconds <= 0) {
      return (seconds >= 120 && seconds <= 300) ? 1.2 : 0.2;
    }
    final int delta = (seconds - anchor.duration.inSeconds).abs();
    if (delta <= 40) {
      return 2.1;
    }
    if (delta <= 90) {
      return 1.1;
    }
    if (delta > 220) {
      return -0.8;
    }
    return 0;
  }

  _SessionContext _sessionContext() {
    return _sessionContextAt(DateTime.now());
  }

  _SessionContext _sessionContextAt(DateTime time) {
    final int hour = time.hour;
    final bool weekend =
        time.weekday == DateTime.saturday || time.weekday == DateTime.sunday;
    if (hour < 6) {
      return const _SessionContext(
        label: 'Late night',
        query: 'chill night',
        vibeToken: 'chill',
      );
    }
    if (hour < 11) {
      return const _SessionContext(
        label: 'Morning',
        query: 'fresh upbeat',
        vibeToken: 'focus',
      );
    }
    if (hour < 17) {
      return const _SessionContext(
        label: 'Daytime',
        query: 'focus vibe',
        vibeToken: 'focus',
      );
    }
    if (hour < 22) {
      return _SessionContext(
        label: weekend ? 'Weekend evening' : 'Evening',
        query: weekend ? 'party energy' : 'chill evening',
        vibeToken: weekend ? 'energy' : 'chill',
      );
    }
    return const _SessionContext(
      label: 'Night',
      query: 'mellow songs',
      vibeToken: 'chill',
    );
  }

  Map<String, double> _defaultRecommendationSourceWeights() {
    return const <String, double>{
      'taste_seed': 1.0,
      'full_listen': 1.0,
      'recent_full_listen': 1.15,
      'skip': 1.05,
      'like': 1.3,
      'dislike': 1.45,
      'replay': 0.9,
      'playlist_add': 1.1,
      'session_match': 1.0,
    };
  }

  double _normalizedPreference(double value, {double fallback = 0.5}) {
    if (value.isNaN || value.isInfinite) {
      return fallback;
    }
    return value.clamp(0.0, 1.0);
  }

  List<_TasteSignal> _preferenceArtists() {
    final Map<String, double> scores = Map<String, double>.from(
      _cloudPreferenceProfile.artistScores,
    );
    final Map<String, String> labels = <String, String>{};

    for (final String key in _cloudPreferenceProfile.artistKeyOrder) {
      if (key.trim().isEmpty) {
        continue;
      }
      labels[key] ??= _displayArtistNameFromKey(key);
    }

    for (final LibrarySong song in _rankedPreferenceSongs()) {
      final String key = _normalizeToken(song.artist);
      if (key.isEmpty || key == 'unknown artist') {
        continue;
      }
      labels[key] ??= song.artist;
      scores[key] = (scores[key] ?? 0) + _songPreferenceWeight(song);
    }

    return scores.entries
        .map(
          (MapEntry<String, double> entry) =>
              _TasteSignal(labels[entry.key] ?? entry.key, entry.value),
        )
        .toList()
      ..sort((_TasteSignal a, _TasteSignal b) => b.score.compareTo(a.score));
  }

  List<_TasteSignal> _preferenceGenres() {
    final Map<String, double> scores = Map<String, double>.from(
      _cloudPreferenceProfile.genreScores,
    );
    final Map<String, String> labels = <String, String>{
      for (final String key in _cloudPreferenceProfile.genreKeys) key: key,
    };

    for (final LibrarySong song in _rankedPreferenceSongs()) {
      final String rawGenre = song.genre?.trim() ?? '';
      if (rawGenre.isEmpty) {
        continue;
      }
      final String key = _normalizeToken(rawGenre);
      labels[key] ??= rawGenre;
      scores[key] = (scores[key] ?? 0) + _songPreferenceWeight(song);
    }

    return scores.entries
        .map(
          (MapEntry<String, double> entry) =>
              _TasteSignal(labels[entry.key] ?? entry.key, entry.value),
        )
        .toList()
      ..sort((_TasteSignal a, _TasteSignal b) => b.score.compareTo(a.score));
  }

  List<LibrarySong> _rankedPreferenceSongs() {
    final Map<String, double> validHistoryBoost = <String, double>{};
    for (final PlaybackEntry entry in validPlaybackHistory.take(120)) {
      validHistoryBoost[entry.songId] =
          (validHistoryBoost[entry.songId] ?? 0) + (1 + entry.completionRatio);
    }
    final Map<String, LibrarySong> allSongs = <String, LibrarySong>{
      for (final LibrarySong song in _songs) song.id: song,
      ..._transientSongsById,
    };
    final List<LibrarySong> ranked = allSongs.values
        .where(
          (LibrarySong song) =>
              song.isRemote && _songPreferenceWeight(song) > 0,
        )
        .toList();
    ranked.sort((LibrarySong a, LibrarySong b) {
      final double leftScore =
          _songPreferenceWeight(a) + (validHistoryBoost[a.id] ?? 0) * 2.5;
      final double rightScore =
          _songPreferenceWeight(b) + (validHistoryBoost[b.id] ?? 0) * 2.5;
      final int scoreCompare = rightScore.compareTo(leftScore);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return b.addedAt.compareTo(a.addedAt);
    });
    return ranked;
  }

  List<LibrarySong> _validHistorySongs() {
    final Set<String> seen = <String>{};
    final List<LibrarySong> result = <LibrarySong>[];
    for (final PlaybackEntry entry in validPlaybackHistory.take(120)) {
      if (!seen.add(entry.songId)) {
        continue;
      }
      final LibrarySong? song = songById(entry.songId);
      if (song != null) {
        result.add(song);
      }
    }
    return result;
  }

  List<_LanguageSignal> _preferredLanguagesFromValidHistory() {
    final Map<String, double> scores = <String, double>{};
    for (final PlaybackEntry entry in validPlaybackHistory.take(120)) {
      final LibrarySong? song = songById(entry.songId);
      if (song == null) {
        continue;
      }
      final _LanguageDetection language = _detectSongLanguageSignal(song);
      if (!_shouldUseLanguageSignal(language)) {
        continue;
      }
      final double weight = entry.listenedToEnd
          ? 1.8
          : math.max(0.3, entry.completionRatio);
      scores[language.code] =
          (scores[language.code] ?? 0) + (weight * language.confidence);
    }
    final double total = scores.values.fold(
      0,
      (double sum, double v) => sum + v,
    );
    if (total <= 0) {
      return const <_LanguageSignal>[];
    }
    return scores.entries
        .map(
          (MapEntry<String, double> entry) => _LanguageSignal(
            label: _languageLabel(entry.key),
            queryToken: _languageQueryToken(entry.key),
            score: entry.value / total,
          ),
        )
        .toList()
      ..sort(
        (_LanguageSignal a, _LanguageSignal b) => b.score.compareTo(a.score),
      );
  }

  _LanguageDetection _detectSongLanguageSignal(LibrarySong song) {
    final String rawText = '${song.title} ${song.artist} ${song.album}';
    final String normalized = _normalizeToken(rawText);
    if (RegExp(r'[\u0D80-\u0DFF]').hasMatch(rawText)) {
      return const _LanguageDetection('si', 0.98);
    }
    if (RegExp(r'[\u0B80-\u0BFF]').hasMatch(rawText)) {
      return const _LanguageDetection('ta', 0.96);
    }
    if (RegExp(r'[\u0900-\u097F]').hasMatch(rawText)) {
      return const _LanguageDetection('hi', 0.94);
    }

    final int sinhalaSignals = _languagePhraseHits(normalized, const <String>[
      'sinhala',
      'sinhalese',
      'hela',
      'sri lanka',
      'lankan',
      'sl song',
      'mage',
      'oba',
      'oya',
      'adare',
      'aadare',
      'pem',
      'sitha',
      'hitha',
      'nethu',
      'sanda',
      'tharu',
      'hiru',
      'manike',
      'kandulu',
      'susum',
      'ridena',
      'riduna',
      'dasa',
      'datha',
      'ma nisa',
      'numbe',
      'nubata',
      'uvindu',
      'ayshcharya',
      'chamel',
      'mihiran',
      'dilu beats',
      'ramidu',
      'malith sanjaya',
    ]);
    if (sinhalaSignals >= 2) {
      return const _LanguageDetection('si', 0.78);
    }
    if (sinhalaSignals == 1) {
      return const _LanguageDetection('si', 0.62);
    }

    final int tamilSignals = _languagePhraseHits(normalized, const <String>[
      'tamil',
      'kollywood',
      'anbe',
      'kadhal',
      'kanave',
    ]);
    if (tamilSignals > 0) {
      return _LanguageDetection('ta', tamilSignals >= 2 ? 0.74 : 0.62);
    }

    final int hindiSignals = _languagePhraseHits(normalized, const <String>[
      'hindi',
      'bollywood',
      'dil',
      'pyar',
      'pyaar',
      'ishq',
    ]);
    if (hindiSignals > 0) {
      return _LanguageDetection('hi', hindiSignals >= 2 ? 0.74 : 0.62);
    }

    final int englishSignals = _languagePhraseHits(normalized, const <String>[
      'english',
      'pop',
      'rock',
      'rap',
      'hip hop',
      'country',
      'love',
      'baby',
      'tonight',
      'forever',
      'heart',
      'dream',
      'dance',
      'girl',
      'boy',
    ]);
    if (englishSignals >= 2) {
      return const _LanguageDetection('en', 0.72);
    }
    if (englishSignals == 1) {
      return const _LanguageDetection('en', 0.52);
    }
    return const _LanguageDetection('unknown', 0);
  }

  int _languagePhraseHits(String normalizedText, List<String> phrases) {
    int count = 0;
    for (final String phrase in phrases) {
      final String normalizedPhrase = _normalizeToken(phrase);
      if (normalizedPhrase.isEmpty) {
        continue;
      }
      if (RegExp(
        '(^|\\s)${RegExp.escape(normalizedPhrase)}(\\s|\$)',
      ).hasMatch(normalizedText)) {
        count += 1;
      }
    }
    return count;
  }

  bool _shouldUseLanguageSignal(_LanguageDetection detection) {
    return detection.code != 'unknown' &&
        detection.confidence >= _minimumProfileLanguageConfidence;
  }

  String _activeRecommendationLanguage({
    LibrarySong? anchor,
    _TasteProfile? profile,
  }) {
    final String anchorLanguage = _anchorRecommendationLanguage(anchor);
    if (anchorLanguage != 'unknown') {
      return anchorLanguage;
    }
    final _TasteProfile tasteProfile = profile ?? _buildTasteProfile();
    if (tasteProfile.primaryLanguage.isNotEmpty &&
        tasteProfile.primaryLanguage != 'unknown') {
      return tasteProfile.primaryLanguage;
    }
    final String regionalLanguage = _localeToLanguageBucket(
      preferredLanguageCode,
    );
    return regionalLanguage.isEmpty ? 'unknown' : regionalLanguage;
  }

  String _anchorRecommendationLanguage(LibrarySong? anchor) {
    if (anchor == null) {
      return 'unknown';
    }
    final _LanguageDetection anchorLanguage = _detectSongLanguageSignal(anchor);
    if (_shouldUseLanguageSignal(anchorLanguage)) {
      return anchorLanguage.code;
    }
    return 'unknown';
  }

  bool _shouldKeepCandidateForLanguage(
    LibrarySong song, {
    LibrarySong? anchor,
    required _TasteProfile profile,
  }) {
    final String anchorLanguage = _anchorRecommendationLanguage(anchor);
    if (anchor != null && anchorLanguage == 'unknown') {
      return true;
    }
    final String targetLanguage = _activeRecommendationLanguage(
      anchor: anchor,
      profile: profile,
    );
    if (targetLanguage == 'unknown') {
      return true;
    }
    final _LanguageDetection candidateLanguage = _detectSongLanguageSignal(
      song,
    );
    if (candidateLanguage.code == 'unknown' ||
        candidateLanguage.confidence < _strictLanguageGateConfidence) {
      return true;
    }
    if (candidateLanguage.code == targetLanguage) {
      return true;
    }
    final String artistKey = _normalizeToken(song.artist);
    final bool strongArtistMatch =
        profile.artistAffinity(artistKey) >= 4 ||
        profile.artistKeys.contains(artistKey);
    if (strongArtistMatch) {
      return true;
    }
    return false;
  }

  String _languageLabel(String language) {
    return switch (language) {
      'si' => 'Sinhala',
      'ta' => 'Tamil',
      'hi' => 'Hindi',
      'unknown' => 'Music',
      _ => 'English',
    };
  }

  String _languageQueryToken(String language) {
    return switch (language) {
      'si' => 'sinhala',
      'ta' => 'tamil',
      'hi' => 'hindi',
      'unknown' => _localeLanguageQueryToken(preferredLanguageCode),
      _ => 'english',
    };
  }

  double _songPreferenceWeight(LibrarySong song) {
    double score = song.playCount * 2.0;
    if (song.isLiked) {
      score += 8;
    }
    if (song.isFavorite) {
      score += 6;
    }
    if (song.lastPlayedAt != null) {
      final int ageHours = DateTime.now()
          .difference(song.lastPlayedAt!)
          .inHours;
      score += ageHours <= 24
          ? 4
          : ageHours <= 168
          ? 2
          : 0.5;
    }
    return score;
  }

  double _explicitArtistPreferenceMultiplier(
    String artistKey, {
    _TasteProfile? profile,
  }) {
    if (artistKey.isEmpty || artistKey == 'unknown artist') {
      return 1;
    }
    final _TasteProfile resolvedProfile = profile ?? _buildTasteProfile();
    final int likedCount = _decisionLikedSongs
        .where((LibrarySong song) => _normalizeToken(song.artist) == artistKey)
        .length;
    final int dislikedCount = _decisionDislikedSongs
        .where((LibrarySong song) => _normalizeToken(song.artist) == artistKey)
        .length;
    if (likedCount <= 0 && dislikedCount <= 0) {
      final double affinity = resolvedProfile.artistAffinity(artistKey);
      final double recentAffinity = resolvedProfile.recentArtistAffinity(
        artistKey,
      );
      final double avoidance =
          resolvedProfile.artistAvoidance(artistKey) +
          resolvedProfile.skipArtistPenalty(artistKey);
      if (affinity <= 0 && recentAffinity <= 0 && avoidance <= 0) {
        return 1;
      }
      final double multiplier =
          1 +
          ((affinity * 0.045) + (recentAffinity * 0.03)) -
          (avoidance * 0.06);
      return multiplier.clamp(0.45, 3.2);
    }

    final double likedBoost = math
        .pow(_likedArtistRankMultiplier, likedCount)
        .toDouble();
    final double dislikedPenalty = math
        .pow(_dislikedArtistRankMultiplier, dislikedCount)
        .toDouble();
    return (likedBoost * dislikedPenalty).clamp(0.01, 1000);
  }

  double _applyArtistRecommendationMultiplier(double score, double multiplier) {
    if (multiplier == 1) {
      return score;
    }
    if (score >= 0) {
      return score * multiplier;
    }
    return score / multiplier;
  }

  bool _sameSong(LibrarySong left, LibrarySong right) {
    return _songIdentityKey(left) == _songIdentityKey(right);
  }

  String _songIdentityKey(LibrarySong song) {
    return '${_normalizeToken(song.artist)}::${_normalizeToken(song.title)}';
  }

  String _normalizeToken(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(official|video|audio|lyrics|lyric|hd|hq|visualizer|remaster(ed)?|version|full song|music video)\b',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> playFromUrl(String input) async {
    final String value = input.trim();
    if (value.isEmpty) {
      return;
    }

    try {
      final LibrarySong? resolvedSong = await _resolveSongFromUrlInput(value);
      if (resolvedSong == null) {
        throw const FormatException('Enter a valid URL.');
      }

      final int selectionRevision = _startPlaybackSelection(resolvedSong);
      await _clearPreparedPlaybackState();
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playFromUrl.after-clear',
      )) {
        return;
      }
      final LibrarySong prepared = await _preparePlayableSong(resolvedSong);
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playFromUrl.after-prepare',
      )) {
        return;
      }
      await _openPreparedSong(
        prepared,
        label: 'URL Stream',
        selectionRevision: selectionRevision,
      );
    } catch (error) {
      _errorMessage = '$error';
      notifyListeners();
    }
  }

  Future<void> playOnlineSong(LibrarySong song) async {
    registerUserActivity(reason: 'play-online-song', notify: false);
    if (offlineMusicMode) {
      _errorMessage = 'Offline Music mode is on.';
      notifyListeners();
      return;
    }
    if (await _resolveOfflineStateForAction()) {
      _errorMessage = offlineMusicMode
          ? 'Offline Music mode is on.'
          : 'Internet is unavailable right now.';
      notifyListeners();
      return;
    }
    final int selectionRevision = _startPlaybackSelection(song);
    try {
      await _interruptCurrentPlayback();
      notifyListeners();
      await _clearPreparedPlaybackState();
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playOnlineSong.after-clear',
      )) {
        return;
      }
      _beginPlaybackActivation(song, resetMetrics: true, notify: false);
      final LibrarySong prepared = await _preparePlayableSong(song);
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playOnlineSong.after-prepare',
      )) {
        return;
      }
      await _openPreparedSong(
        prepared,
        label: 'Online Music',
        selectionRevision: selectionRevision,
      );
    } catch (error) {
      if (_isCurrentPlaybackSelection(selectionRevision)) {
        _pendingSelectionSong = null;
        _clearPlaybackActivation();
        _errorMessage = _friendlyPlaybackErrorMessage(error);
        notifyListeners();
      }
      _debugLog('Playback failed for ${song.id}: $error');
    }
  }

  void _attachPlayerListeners([Player? playerInstance]) {
    final Player player = playerInstance ?? _player;
    _subscriptions.add(
      player.stream.playing.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        final bool wasPlaying = _isPlaying;
        _isPlaying = value as bool;
        if (_isPlaying) {
          _pauseRequestedByUser = false;
          _suppressAutoAdvanceOnNextStop = false;
          _resumeSleepTimerCountdown(notify: sleepTimerEnabled);
        }
        if (wasPlaying && !_isPlaying) {
          _pauseSleepTimerCountdown();
          final bool completed = player.state.completed;
          final bool pausedByUser = _pauseRequestedByUser;
          final bool suppressedByController = _suppressAutoAdvanceOnNextStop;
          _pauseRequestedByUser = false;
          _suppressAutoAdvanceOnNextStop = false;
          if (suppressedByController) {
            _debugPlayback(
              'player.playing stop ignored '
              'reason=controller-interrupt '
              'completed=$completed queueIndex=$_queueIndex '
              'transitionSong=$_transitioningSongId '
              'pending=${_debugSongLabel(_pendingSelectionSong)}',
            );
          } else if (!pausedByUser) {
            _requestQueueAdvanceAtTrackEnd(
              completed ? 'completed' : 'playing-stopped',
              allowStoppedPlayback: !completed,
              force:
                  !completed &&
                  _shouldForceAdvanceAfterUnexpectedPlaybackStop(),
            );
          }
        }
        _maybeResolvePlaybackActivation();
        _publishNotificationState();
        _syncPlaybackNotifiers();
      }),
    );

    _subscriptions.add(
      player.stream.completed.listen((dynamic value) {
        _handleCompletedPlaybackEvent(value as bool);
      }),
    );

    _subscriptions.add(
      player.stream.position.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        if (_shouldHoldTransitionMetrics()) {
          return;
        }
        _position = value as Duration;
        _maybeResolvePlaybackActivation();
        _updateActivePlaybackProgress();
        _syncQueueIndexFromPlayerState();
        _maybeAdvanceOfflineQueueAtTrackEnd();
        _publishNotificationState();
        _syncPlaybackNotifiers();
      }),
    );

    _subscriptions.add(
      player.stream.duration.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        if (_shouldHoldTransitionMetrics()) {
          return;
        }
        _duration = value as Duration;
        _maybeResolvePlaybackActivation();
        _publishNotificationState();
        _syncPlaybackNotifiers();
      }),
    );

    _subscriptions.add(
      player.stream.shuffle.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        _isShuffleEnabled = value as bool;
        _syncPlaybackNotifiers();
      }),
    );

    _subscriptions.add(
      player.stream.playlistMode.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        _repeatMode = value as PlaylistMode;
        _syncPlaybackNotifiers();
      }),
    );

    _subscriptions.add(
      player.stream.error.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        _errorMessage = value as String;
        _debugPlayback(
          'player.error message="$_errorMessage" '
          'current=${_debugSongLabel(currentSong)} '
          'pending=${_debugSongLabel(_pendingSelectionSong)} '
          'transitionSong=$_transitioningSongId '
          'transitionIndex=$_transitioningQueueIndex '
          'queueIndex=$_queueIndex '
          'playerIndex=${player.state.playlist.index}',
        );
        final LibrarySong? failedSong = _preferredPlaybackRecoverySong();
        if (_isPlayableOpenFailure(_errorMessage!) &&
            failedSong != null &&
            _schedulePlaybackFallbackRecovery(
              failedSong,
              bypassPlaybackProxy:
                  _isLocalPlaybackProxyFailure(_errorMessage!) ||
                  _isSongUsingPlaybackProxy(failedSong.id),
            )) {
          return;
        }
        if (_isConnectivityError(_errorMessage!)) {
          _setConnectivityOffline(true, notify: false, announceLoss: true);
        }
        if (_isOffline || offlineMusicMode) {
          final int? transitionIndex = _transitioningQueueIndex;
          if (_offlineQueueActivationTargetSongId == null &&
              transitionIndex != null &&
              transitionIndex >= 0 &&
              transitionIndex < _queueSongIds.length) {
            final LibrarySong? target = songById(
              _queueSongIds[transitionIndex],
            );
            if (target != null &&
                _offlinePlaybackCachePathForSong(target.id) != null) {
              _debugPlayback(
                'player.error reopening cached target '
                'index=$transitionIndex song=${_debugSongLabel(target)}',
              );
              unawaited(_reopenQueueAtIndex(transitionIndex));
              notifyListeners();
              return;
            }
          }
          _debugPlayback(
            'player.error offline mode active without full queue activation '
            'current=${_debugSongLabel(currentSong)} '
            'queueIndex=$_queueIndex',
          );
        }
        _clearPlaybackActivation();
        notifyListeners();
      }),
    );

    _subscriptions.add(
      player.stream.playlist.listen((dynamic value) {
        if (_isDisposing || _isDisposed) {
          return;
        }
        // Strict lock: completely ignore all playlist events during recovery
        if (_playbackRecoveryQueueLocked) {
          _debugPlayback('player.playlist ignored - recovery queue locked');
          return;
        }
        final Playlist playlist = value as Playlist;
        final List<String> nextQueueSongIds = playlist.medias
            .map((Media media) => media.extras?['songId'] as String?)
            .whereType<String>()
            .toList();
        final int nextQueueIndex = playlist.index.clamp(
          0,
          nextQueueSongIds.isEmpty ? 0 : nextQueueSongIds.length - 1,
        );
        _debugPlayback(
          'player.playlist event '
          'playerIndex=${playlist.index} '
          'nextIndex=$nextQueueIndex '
          'nextSong=${nextQueueSongIds.isEmpty ? 'null' : nextQueueSongIds[nextQueueIndex]} '
          'queueLen=${nextQueueSongIds.length} '
          'activationTarget=$_offlineQueueActivationTargetSongId '
          'fallbackTarget=$_playbackFallbackRecoverySongId '
          'transitionSong=$_transitioningSongId '
          'transitionIndex=$_transitioningQueueIndex',
        );
        if (nextQueueSongIds.isEmpty &&
            (_transitioningSongId != null ||
                _queueNavigationInFlight ||
                _pendingSelectionSong != null)) {
          _debugPlayback(
            'player.playlist ignored temporary empty playlist during manual transition',
          );
          return;
        }
        final bool hasRestrictedSong = nextQueueSongIds.any((String songId) {
          final LibrarySong? song = songById(songId);
          return song == null || !shouldShowSongOutsideSearch(song);
        });
        if (hasRestrictedSong) {
          _debugPlayback(
            'player.playlist ignored restricted stale queue '
            'playerIndex=${playlist.index} queueLen=${nextQueueSongIds.length}',
          );
          return;
        }
        if (_shouldIgnorePlaylistEventForPendingSelection(
          nextQueueSongIds,
          nextQueueIndex,
        )) {
          return;
        }
        if (_queueNavigationInFlight) {
          _debugPlayback(
            'player.playlist ignored while queue navigation is in flight '
            'playerIndex=${playlist.index} nextIndex=$nextQueueIndex',
          );
          return;
        }
        if (_playbackFallbackRecoverySongId != null) {
          final String? activeSongId = nextQueueSongIds.isEmpty
              ? null
              : nextQueueSongIds[nextQueueIndex];
          final bool recoveryResolved =
              activeSongId == _playbackFallbackRecoverySongId &&
              (_playbackFallbackRecoveryIndex == null ||
                  nextQueueIndex == _playbackFallbackRecoveryIndex);
          if (!recoveryResolved) {
            _debugPlayback(
              'player.playlist ignored during fallback recovery '
              'active=$activeSongId '
              'expected=$_playbackFallbackRecoverySongId '
              'expectedIndex=$_playbackFallbackRecoveryIndex',
            );
            return;
          }
          _debugPlayback(
            'player.playlist fallback recovery resolved '
            'song=$activeSongId index=$nextQueueIndex',
          );
        }
        if (_offlineQueueActivationTargetSongId != null) {
          final String? activeSongId = nextQueueSongIds.isEmpty
              ? null
              : nextQueueSongIds[nextQueueIndex];
          final bool activationResolved =
              activeSongId == _offlineQueueActivationTargetSongId &&
              nextQueueIndex == _offlineQueueActivationTargetIndex &&
              listEquals(nextQueueSongIds, _offlineQueueActivationSongIds);
          if (!activationResolved) {
            _debugPlayback(
              'player.playlist ignored during activation '
              'active=$activeSongId '
              'expected=$_offlineQueueActivationTargetSongId '
              'expectedIndex=$_offlineQueueActivationTargetIndex',
            );
            return;
          }
          _debugPlayback(
            'player.playlist activation resolved '
            'song=$activeSongId index=$nextQueueIndex',
          );
        }
        if (_offlineDetachedQueueMode) {
          final LibrarySong? song = currentSong;
          _resolveTrackTransition(song);
          if (song != null && song.id != _lastTrackedSongId) {
            _trackPlayback(song.id);
          }
          _scheduleSmartQueueWindowRefill(seed: song);
          _publishNotificationState();
          notifyListeners();
          return;
        }
        if (_offlineQueueWaitingSongId != null) {
          final String? activeSongId = nextQueueSongIds.isEmpty
              ? null
              : nextQueueSongIds[nextQueueIndex];
          if (activeSongId != _offlineQueueWaitingSongId ||
              nextQueueIndex != _offlineQueueWaitingIndex) {
            _debugPlayback(
              'player.playlist ignored during offline wait '
              'active=$activeSongId waiting=$_offlineQueueWaitingSongId '
              'waitingIndex=$_offlineQueueWaitingIndex',
            );
            return;
          }
          _debugPlayback(
            'player.playlist offline wait resolved '
            'song=$activeSongId index=$nextQueueIndex',
          );
        }
        // Validate queue progression to prevent rapid skipping
        if (!_isShuffleEnabled &&
            nextQueueIndex < _queueIndex &&
            _queueIndex != 0 &&
            !(_repeatMode == PlaylistMode.loop)) {
          // Queue went backwards unexpectedly - could be player error
          _debugPlayback(
            'player.playlist detected backward progression '
            'from $_queueIndex to $nextQueueIndex - normalizing',
          );
          return;
        }
        // Prevent skipping multiple songs in one update
        if (!_isShuffleEnabled &&
            nextQueueIndex > _queueIndex + 1 &&
            _isPlaying &&
            _transitioningSongId == null &&
            _playbackFallbackRecoverySongId == null) {
          _debugPlayback(
            'player.playlist detected large skip '
            'from $_queueIndex to $nextQueueIndex - limiting to next song',
          );
          _queueSongIds = nextQueueSongIds;
          _queueIndex = _queueIndex + 1;
        } else {
          _queueSongIds = nextQueueSongIds;
          _queueIndex = nextQueueIndex;
        }
        if (!_isShuffleEnabled || _detachedSequentialQueueSongIds.isEmpty) {
          _detachedSequentialQueueSongIds = List<String>.from(_queueSongIds);
        }
        final LibrarySong? song = currentSong;
        if (_offlineQueueActivationTargetSongId == null) {
          _resolveTrackTransition(song);
        }
        if (song != null && song.id != _lastTrackedSongId) {
          _trackPlayback(song.id);
        }
        _scheduleSmartQueueWindowRefill(seed: song);
        unawaited(_refreshOfflinePlaybackCache(anchor: song));
        _invalidateStandbyPreloads();
        _publishNotificationState();
        notifyListeners();
      }),
    );
  }

  void _bindNotificationActions() {
    _notificationActionSubscription?.cancel();
    _notificationActionSubscription = null;
    if (AndroidMediaNotificationBridge.isSupported) {
      _notificationActionSubscription =
          AndroidMediaNotificationBridge.actionStream().listen((String action) {
            if (AndroidMediaNotificationBridge.isToggleAction(action)) {
              unawaited(togglePlayback());
            } else if (AndroidMediaNotificationBridge.isPlayAction(action)) {
              // Ignore stale play events from a previous Android media session.
              if (!_hasPublishedPlaybackNotification && !_isPlaying) {
                return;
              }
              unawaited(play());
            } else if (AndroidMediaNotificationBridge.isPauseAction(action)) {
              unawaited(pause());
            } else if (AndroidMediaNotificationBridge.isNextAction(action)) {
              unawaited(nextTrack());
            } else if (AndroidMediaNotificationBridge.isPreviousAction(
              action,
            )) {
              unawaited(previousTrack());
            }
          });
    }

    _windowsMediaActionSubscription?.cancel();
    _windowsMediaActionSubscription = null;
    if (WindowsMediaControlsBridge.isSupported) {
      _windowsMediaActionSubscription =
          WindowsMediaControlsBridge.actionStream().listen((String action) {
            if (WindowsMediaControlsBridge.isToggleAction(action)) {
              unawaited(togglePlayback());
            } else if (WindowsMediaControlsBridge.isPlayAction(action)) {
              unawaited(play());
            } else if (WindowsMediaControlsBridge.isPauseAction(action)) {
              unawaited(pause());
            } else if (WindowsMediaControlsBridge.isNextAction(action)) {
              unawaited(nextTrack());
            } else if (WindowsMediaControlsBridge.isPreviousAction(action)) {
              unawaited(previousTrack());
            }
          });
    }
  }

  void _publishNotificationState() {
    final LibrarySong? song = currentSong;
    if (song == null) {
      _hasPublishedPlaybackNotification = false;
      unawaited(AndroidMediaNotificationBridge.stop());
      unawaited(WindowsMediaControlsBridge.stop());
      return;
    }

    if (_isPlaying) {
      _hasPublishedPlaybackNotification = true;
    }

    if (!_hasPublishedPlaybackNotification) {
      unawaited(AndroidMediaNotificationBridge.stop());
      unawaited(WindowsMediaControlsBridge.stop());
      return;
    }

    unawaited(
      AndroidMediaNotificationBridge.updatePlayback(
        song: song,
        isPlaying: _isPlaying,
        isLoading: miniPlayerSelectionLoading,
        position: _position,
        duration: _duration,
      ),
    );
    unawaited(
      WindowsMediaControlsBridge.updatePlayback(
        song: song,
        isPlaying: _isPlaying,
        position: _position,
        duration: _duration,
        queueIndex: _queueIndex,
        queueLength: _queueSongIds.length,
      ),
    );
  }

  void _syncQueueIndexFromPlayerState() {
    if (_isDisposing || _isDisposed) {
      return;
    }
    if (_offlineQueueActivationTargetSongId != null ||
        _playbackFallbackRecoverySongId != null ||
        _offlineDetachedQueueMode ||
        _offlineQueueWaitingSongId != null ||
        _queueNavigationInFlight ||
        _transitioningSongId != null) {
      _debugPlayback(
        'player.position queue sync skipped '
        'activation=$_offlineQueueActivationTargetSongId '
        'fallback=$_playbackFallbackRecoverySongId '
        'detached=$_offlineDetachedQueueMode '
        'waiting=$_offlineQueueWaitingSongId '
        'navigation=$_queueNavigationInFlight '
        'transitionSong=$_transitioningSongId '
        'transitionIndex=$_transitioningQueueIndex '
        'queueIndex=$_queueIndex '
        'playerIndex=${_player.state.playlist.index}',
      );
      return;
    }
    if (_queueSongIds.isEmpty) {
      return;
    }
    if (!_playerQueueHasControllerPlaylist()) {
      return;
    }
    final int nextIndex = _player.state.playlist.index.clamp(
      0,
      _queueSongIds.length - 1,
    );
    if (nextIndex == _queueIndex) {
      return;
    }
    _debugPlayback(
      'player.position queue sync apply '
      'queueIndex=$_queueIndex -> $nextIndex '
      'playerIndex=${_player.state.playlist.index}',
    );
    _queueIndex = nextIndex;
    final LibrarySong? song = currentSong;
    if (song != null && song.id != _lastTrackedSongId) {
      _trackPlayback(song.id);
    }
    _scheduleSmartQueueWindowRefill(seed: song);
    unawaited(_refreshOfflinePlaybackCache(anchor: song));
  }

  LibrarySong? songById(String id) {
    _ensureDerivedLibraryData();
    return _songLookupCache[id];
  }

  List<LibrarySong> songsForPlaylist(UserPlaylist playlist) {
    _ensureDerivedLibraryData();
    return List<LibrarySong>.unmodifiable(
      _playlistSongsCache[playlist.id] ?? const <LibrarySong>[],
    );
  }

  Future<void> importFiles() async {
    if (!supportsLocalFileImport) {
      return;
    }
    final FilePickerResult? result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: supportedExtensions,
    );
    if (result == null) {
      return;
    }

    final List<String> picked = result.paths
        .whereType<String>()
        .where((String path) => !isExcludedLocalAudioPath(path))
        .toList();
    if (picked.isEmpty) {
      return;
    }

    _sources = <String>{..._sources, ...picked}.toList()..sort();
    await _rescanAllSources();
  }

  Future<void> importFolder() async {
    if (!supportsLocalFileImport) {
      return;
    }
    final String? folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Pick a music folder',
    );
    if (folder == null || folder.isEmpty) {
      return;
    }

    _sources = <String>{..._sources, folder}.toList()..sort();
    await _rescanAllSources();
  }

  Future<void> rescanLibrary() async {
    await _rescanAllSources();
  }

  Future<void> removeSource(String source) async {
    _sources = _sources.where((String item) => item != source).toList();
    await _rescanAllSources();
  }

  Future<void> clearLibrary() async {
    _sources = <String>[];
    _songs = <LibrarySong>[];
    _playlists = <UserPlaylist>[];
    _history = <PlaybackEntry>[];
    _onlineResults = <LibrarySong>[];
    _trendingNowSongs = <LibrarySong>[];
    _trendingNowRegionLabel = 'Your region';
    _trendingNowError = null;
    _trendingNowLoading = false;
    _homeFeed = <HomeFeedSection>[];
    _personalizedHomeRecommendations = <SongRecommendation>[];
    _transientSongsById.clear();
    _searchCache.clear();
    _ytMusicSearchCache.clear();
    _ytMusicVideoIdCache.clear();
    _ytMusicArtistImageCache.clear();
    _ytMusicArtistCollectionCache.clear();
    _queueSongIds = <String>[];
    _detachedSequentialQueueSongIds = <String>[];
    _queueIndex = 0;
    _queueLabel = 'Now Playing';
    _lastTrackedSongId = null;
    _smartQueueSongIds.clear();
    _markLibraryDataDirty('library cleared');
    await _player.stop();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> clearPlaybackHistory() async {
    _history = <PlaybackEntry>[];
    _songs = _songs
        .map(
          (LibrarySong song) =>
              song.copyWith(playCount: 0, clearLastPlayedAt: true),
        )
        .toList(growable: false);
    _transientSongsById.updateAll(
      (_, LibrarySong song) =>
          song.copyWith(playCount: 0, clearLastPlayedAt: true),
    );
    _activePlaybackSongId = null;
    _activePlaybackCompletionRatio = 0;
    _lastTrackedSongId = null;
    _startupMiniPlayerSongId = null;
    _homeFeed = <HomeFeedSection>[];
    _personalizedHomeRecommendations = <SongRecommendation>[];
    _scheduleSnapshotSave();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> _rescanAllSources() async {
    final Stopwatch stopwatch = Stopwatch()..start();
    _scanning = true;
    _statusMessage = 'Scanning device audio...';
    _errorMessage = null;
    notifyListeners();
    AppLogger.info('LibraryScan', 'Device library scan started');

    try {
      await _ensureLibraryAccessPermissionIfNeeded();
      _autoSources = await _discoverAutomaticSources();
      final List<String> activeSources = <String>{
        ..._autoSources,
        ..._sources,
      }.toList()..sort();
      final List<String> files = await _expandSourceFiles(activeSources);
      final Map<String, LibrarySong> previousByPath = <String, LibrarySong>{
        for (final LibrarySong song in _songs) song.path: song,
      };
      final List<LibrarySong> scanned = <LibrarySong>[];

      for (final String filePath in files) {
        if (isExcludedLocalAudioPath(filePath)) {
          continue;
        }
        scanned.add(
          await _buildSongFromPath(filePath, previousByPath[filePath]),
        );
      }

      _songs = scanned
          .map(_withKnownCloudPreferenceState)
          .toList(growable: false);
      _playlists = _playlists
          .map(
            (UserPlaylist playlist) => playlist.copyWith(
              songIds: playlist.songIds
                  .where(
                    (String songId) =>
                        scanned.any((LibrarySong song) => song.id == songId),
                  )
                  .toList(),
              updatedAt: DateTime.now(),
            ),
          )
          .toList();
      _history = _history
          .where(
            (PlaybackEntry entry) =>
                scanned.any((LibrarySong song) => song.id == entry.songId),
          )
          .toList();
      _prunePlaybackHistory();
      _purgeRestrictedDurationOfflinePlaybackCacheEntries();
      _markLibraryDataDirty('device library scan completed');

      _statusMessage = scanned.isEmpty
          ? 'No supported audio files found on this device.'
          : 'Loaded ${scanned.length} songs from device storage.';
      await _saveSnapshot();
    } catch (error) {
      _errorMessage = '$error';
      _statusMessage = 'Device scan failed.';
    } finally {
      stopwatch.stop();
      _scanning = false;
      notifyListeners();
      AppLogger.info(
        'LibraryScan',
        'Device library scan finished in ${stopwatch.elapsedMilliseconds}ms',
      );
    }
  }

  Future<List<String>> _discoverAutomaticSources() async {
    final Set<String> results = <String>{};
    if (Platform.isAndroid) {
      results.addAll(await _discoverAndroidAudioRoots());
    } else if (Platform.isWindows) {
      results.addAll(_discoverWindowsAudioRoots());
    }
    return results.toList()..sort();
  }

  Future<List<String>> _discoverAndroidAudioRoots() async {
    final Set<String> candidates = <String>{
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/storage/emulated/0/Podcasts',
      '/sdcard/Music',
      '/sdcard/Download',
      '/sdcard/Downloads',
      '/sdcard/Podcasts',
    };
    for (final String key in <String>[
      'EXTERNAL_STORAGE',
      'SECONDARY_STORAGE',
      'EMULATED_STORAGE_TARGET',
    ]) {
      final String? raw = Platform.environment[key];
      if (raw == null || raw.trim().isEmpty) {
        continue;
      }
      for (final String root in raw.split(':')) {
        final String trimmed = root.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        candidates.add(trimmed);
        candidates.add(p.join(trimmed, 'Music'));
        candidates.add(p.join(trimmed, 'Download'));
        candidates.add(p.join(trimmed, 'Downloads'));
        candidates.add(p.join(trimmed, 'Podcasts'));
      }
    }

    final Set<String> existing = <String>{};
    for (final String path in candidates) {
      final Directory directory = Directory(path);
      if (await directory.exists()) {
        existing.add(directory.path);
      }
    }
    return existing.toList()..sort();
  }

  List<String> _discoverWindowsAudioRoots() {
    final String? userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.trim().isEmpty) {
      return <String>[];
    }
    final Set<String> candidates = <String>{
      p.join(userProfile, 'Music'),
      p.join(userProfile, 'Downloads'),
      p.join(userProfile, 'Desktop'),
      p.join(userProfile, 'Videos'),
    };
    return candidates
        .where((String path) => Directory(path).existsSync())
        .toList()
      ..sort();
  }

  Future<List<String>> _expandSourceFiles(List<String> sources) async {
    return expandAudioSourceFiles(
      sources: sources,
      supportedExtensions: supportedExtensions,
    );
  }

  Future<LibrarySong> _buildSongFromPath(
    String filePath,
    LibrarySong? previous,
  ) async {
    Tag? tag;
    try {
      tag = await AudioTags.read(filePath);
    } catch (_) {
      tag = null;
    }

    final File file = File(filePath);
    final FileStat stat = await file.stat();
    final String baseName = p.basenameWithoutExtension(filePath);
    final _FallbackTitle fallback = _fallbackFromFilename(baseName);
    final String folderPath = p.dirname(filePath);
    final String folderName = p.basename(folderPath);

    final String title = _cleanText(tag?.title) ?? fallback.title;
    final String artist =
        _cleanText(tag?.trackArtist) ?? fallback.artist ?? 'Unknown artist';
    final String album = _cleanText(tag?.album) ?? folderName;
    final String albumArtist = _cleanText(tag?.albumArtist) ?? artist;

    return LibrarySong(
      id: previous?.id ?? filePath,
      path: filePath,
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      folderName: folderName.isEmpty ? 'Library' : folderName,
      folderPath: folderPath,
      sourceLabel: _sourceLabelForPath(filePath),
      addedAt: previous?.addedAt ?? stat.changed,
      durationMs:
          _durationMsFromAudioTag(tag?.duration) ??
          _normalizeLegacyDurationMs(previous?.durationMs) ??
          0,
      genre: _cleanText(tag?.genre) ?? previous?.genre,
      year: tag?.year ?? previous?.year,
      trackNumber: tag?.trackNumber ?? previous?.trackNumber,
      discNumber: tag?.discNumber ?? previous?.discNumber,
      isFavorite: previous?.isFavorite ?? false,
      playCount: previous?.playCount ?? 0,
      lastPlayedAt: previous?.lastPlayedAt,
    );
  }

  int? _durationMsFromAudioTag(int? tagDurationSeconds) {
    if (tagDurationSeconds == null || tagDurationSeconds <= 0) {
      return null;
    }
    return tagDurationSeconds * 1000;
  }

  int? _normalizeLegacyDurationMs(int? durationMs) {
    if (durationMs == null || durationMs <= 0) {
      return null;
    }
    // Older scans stored audiotags duration (seconds) directly as durationMs.
    if (durationMs < 10000) {
      return durationMs * 1000;
    }
    return durationMs;
  }

  bool _hasLegacyLocalDurationEncoding(LibrarySong song) {
    final int durationMs = song.durationMs;
    return !song.isRemote && durationMs > 0 && durationMs < 10000;
  }

  LibrarySong _videoToSong(Video video) {
    // Avoid thumbnail 404s: maxRes is not always available.
    final String artwork = _upgradeArtworkUrl(
      video.thumbnails.highResUrl.isNotEmpty
          ? video.thumbnails.highResUrl
          : video.thumbnails.standardResUrl,
    );
    return LibrarySong(
      id: 'yt:${video.id.value}',
      path: 'https://www.youtube.com/watch?v=${video.id.value}',
      title: video.title,
      artist: video.author,
      album: 'Online Stream',
      albumArtist: video.author,
      folderName: 'Online Stream',
      folderPath: 'youtube',
      sourceLabel: 'Online Stream',
      addedAt: DateTime.now(),
      durationMs: video.duration?.inMilliseconds ?? 0,
      isRemote: true,
      artworkUrl: artwork,
      externalUrl: 'https://music.youtube.com/watch?v=${video.id.value}',
    );
  }

  LibrarySong _urlToSong(Uri uri) {
    return LibrarySong(
      id: 'url:${uri.toString()}',
      path: uri.toString(),
      title: p.basename(uri.path).isEmpty ? uri.host : p.basename(uri.path),
      artist: uri.host,
      album: 'Online Stream',
      albumArtist: uri.host,
      folderName: 'Online',
      folderPath: uri.toString(),
      sourceLabel: 'URL',
      addedAt: DateTime.now(),
      durationMs: 0,
      isRemote: true,
      externalUrl: uri.toString(),
    );
  }

  Future<LibrarySong?> _resolveSongFromUrlInput(String input) async {
    final String value = input.trim();
    if (value.isEmpty) {
      return null;
    }

    try {
      if (_looksLikeYouTube(value)) {
        final Video video = await _yt.videos.get(value);
        return _withKnownCloudPreferenceState(_videoToSong(video));
      }

      final Uri? uri = Uri.tryParse(value);
      if (uri == null || !uri.hasScheme) {
        return null;
      }
      return _withKnownCloudPreferenceState(_urlToSong(uri));
    } catch (error) {
      _debugLog('URL song resolution failed for "$value": $error');
      return null;
    }
  }

  bool _looksLikeYouTube(String value) {
    return looksLikeYouTubePlaybackSource(value);
  }

  _FallbackTitle _fallbackFromFilename(String baseName) {
    if (baseName.contains(' - ')) {
      final List<String> parts = baseName.split(' - ');
      if (parts.length >= 2) {
        return _FallbackTitle(
          artist: parts.first.trim(),
          title: parts.skip(1).join(' - ').trim(),
        );
      }
    }
    return _FallbackTitle(title: baseName.replaceAll('_', ' ').trim());
  }

  String? _cleanText(String? text) {
    if (text == null) {
      return null;
    }
    final String value = text.trim();
    return value.isEmpty ? null : value;
  }

  String _sourceLabelForPath(String path) {
    String? bestMatch;
    for (final String source in <String>{..._autoSources, ..._sources}) {
      if (path.startsWith(source) &&
          (bestMatch == null || source.length > bestMatch.length)) {
        bestMatch = source;
      }
    }
    if (bestMatch == null) {
      return 'Library';
    }
    return p.basename(bestMatch).isEmpty ? bestMatch : p.basename(bestMatch);
  }

  Future<void> playSongs(
    List<LibrarySong> songs, {
    int startIndex = 0,
    String label = 'Now Playing',
  }) async {
    registerUserActivity(reason: 'play-songs', notify: false);
    if (songs.isEmpty) {
      return;
    }

    final int safeIndex = startIndex.clamp(0, songs.length - 1);
    _clearOfflineQueueWait(notify: false);
    _offlineDetachedQueueMode = false;
    final int selectionRevision = _startPlaybackSelection(songs[safeIndex]);
    try {
      await _interruptCurrentPlayback();
      notifyListeners();
      await _clearPreparedPlaybackState();
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playSongs.after-clear',
      )) {
        return;
      }
      _beginPlaybackActivation(
        songs[safeIndex],
        resetMetrics: true,
        notify: false,
      );
      final List<LibrarySong> preparedSongs = List<LibrarySong>.from(songs);
      preparedSongs[safeIndex] = await _preparePlayableSong(songs[safeIndex]);
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playSongs.after-prepare',
      )) {
        return;
      }

      // Keep the native player on a single prepared track for queues that
      // still require resolved YouTube playback URLs. This prevents native
      // auto-advance from racing ahead of cache/prepare work.
      _offlineDetachedQueueMode =
          !_isOffline &&
          !offlineMusicMode &&
          _queueRequiresDetachedSequentialPlayback(songs);

      _smartQueueSongIds.clear();
      _queueSongIds = preparedSongs.map((LibrarySong song) => song.id).toList();
      _detachedSequentialQueueSongIds = List<String>.from(_queueSongIds);
      _queueLabel = label;
      _queueIndex = safeIndex;
      await _ensureSequentialPlayback();
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playSongs.after-queue-setup',
      )) {
        return;
      }
      // Cache only the selected track as it starts playback. Queue entries are
      // left untouched until they become the active song.
      await _enableProxyCachingForSong(preparedSongs[safeIndex]);
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playSongs.after-proxy',
      )) {
        return;
      }
      if (_offlineDetachedQueueMode) {
        await _player.open(
          Playlist(<Media>[_mediaForSong(preparedSongs[safeIndex])]),
          play: false,
        );
      } else {
        final List<Media> medias = preparedSongs.map(_mediaForSong).toList();
        await _player.open(Playlist(medias, index: safeIndex), play: false);
      }
      await _syncPlayerPlaybackModes(_player);
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'playSongs.after-open',
      )) {
        return;
      }
      await _player.play();
      _trackPlayback(preparedSongs[safeIndex].id);
      if (!_isOffline && !offlineMusicMode) {
        _scheduleSmartQueueWindowRefill(seed: preparedSongs[safeIndex]);
      }
      _invalidateStandbyPreloads();
      notifyListeners();
    } catch (_) {
      if (_isCurrentPlaybackSelection(selectionRevision)) {
        _pendingSelectionSong = null;
        _clearPlaybackActivation();
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> playSong(LibrarySong song, {String label = 'Song'}) async {
    await playSongs(<LibrarySong>[song], label: label);
  }

  Future<void> playAlbum(AlbumCollection album, {int startIndex = 0}) async {
    await playSongs(album.songs, startIndex: startIndex, label: album.title);
  }

  Future<void> playArtist(ArtistCollection artist, {int startIndex = 0}) async {
    await playSongs(artist.songs, startIndex: startIndex, label: artist.name);
  }

  Future<void> playFolder(FolderCollection folder, {int startIndex = 0}) async {
    await playSongs(folder.songs, startIndex: startIndex, label: folder.name);
  }

  Future<void> playPlaylist(UserPlaylist playlist, {int startIndex = 0}) async {
    final List<LibrarySong> songs = songsForPlaylist(playlist);
    await playSongs(songs, startIndex: startIndex, label: playlist.name);
  }

  Future<String?> resolveArtistImage(String artistName) async {
    final YTMusic? client = _ytMusic;
    final String normalized = _normalizeToken(artistName);
    if (normalized.isEmpty || client == null || _isDisposed || _isDisposing) {
      AppLogger.trace(
        'ArtistImage',
        'Skipped image resolve for "${artistName.trim()}"',
      );
      return null;
    }
    if (_ytMusicArtistImageCache.containsKey(normalized)) {
      AppLogger.trace('ArtistImage', 'Cache hit for "${artistName.trim()}"');
      return _ytMusicArtistImageCache[normalized];
    }

    String? resolved;
    try {
      final List<dynamic> artistResults = await client.search(
        artistName.trim(),
        filter: ytm.SearchFilter.artists,
        limit: 5,
      );
      resolved = _pickArtistImageUrl(artistResults, artistName: artistName);
      if ((resolved ?? '').trim().isEmpty) {
        final List<dynamic> profileResults = await client.search(
          artistName.trim(),
          filter: ytm.SearchFilter.profiles,
          limit: 5,
        );
        resolved = _pickArtistImageUrl(profileResults, artistName: artistName);
      }
    } catch (error) {
      AppLogger.warn(
        'ArtistImage',
        'Resolve failed for "${artistName.trim()}": $error',
      );
      resolved = null;
    }

    if (_isDisposed || _isDisposing) {
      return null;
    }
    final String upgraded = _upgradeArtworkUrl(resolved);
    AppLogger.info(
      'ArtistImage',
      upgraded.isEmpty
          ? 'No image resolved for "${artistName.trim()}"'
          : 'Resolved image for "${artistName.trim()}"',
    );
    _ytMusicArtistImageCache[normalized] = upgraded;
    return upgraded;
  }

  Future<ArtistCollection?> fetchOnlineArtistCollection(
    String artistKey, {
    String? artistName,
    bool force = false,
  }) async {
    final OnlineArtistCollectionPage? page =
        await fetchOnlineArtistCollectionPage(
          artistKey,
          artistName: artistName,
          force: force,
          minimumSongCount: 100,
        );
    return page?.artist;
  }

  Future<OnlineArtistCollectionPage?> fetchOnlineArtistCollectionPage(
    String artistKey, {
    String? artistName,
    bool force = false,
    int minimumSongCount = 10,
  }) async {
    final YTMusic? client = _ytMusic;
    final String fallbackName = (artistName ?? '').trim().isNotEmpty
        ? artistName!.trim()
        : _displayArtistNameFromKey(artistKey);
    final String normalizedKey = _normalizeToken(artistName ?? artistKey);
    if (normalizedKey.isEmpty ||
        client == null ||
        _isDisposed ||
        _isDisposing) {
      return null;
    }
    final int targetSongCount = math.max(1, minimumSongCount);

    if (force) {
      _ytMusicArtistCollectionCache.remove(normalizedKey);
      _ytMusicArtistCollectionSessionCache.remove(normalizedKey);
    }

    if (!force &&
        _ytMusicArtistCollectionCache.containsKey(normalizedKey) &&
        _ytMusicArtistCollectionCache[normalizedKey] == null) {
      return null;
    }

    final _OnlineArtistCollectionSession? cachedSession =
        _ytMusicArtistCollectionSessionCache[normalizedKey];
    if (cachedSession != null) {
      await _expandOnlineArtistCollectionSession(
        client,
        session: cachedSession,
        minimumSongCount: targetSongCount,
      );
      if (cachedSession.songs.isEmpty && cachedSession.fullyLoaded) {
        _ytMusicArtistCollectionCache[normalizedKey] = null;
        _ytMusicArtistCollectionSessionCache.remove(normalizedKey);
        return null;
      }
      final ArtistCollection collection = ArtistCollection(
        id: normalizedKey,
        name: cachedSession.resolvedName,
        songs: List<LibrarySong>.unmodifiable(cachedSession.songs),
      );
      _ytMusicArtistCollectionCache[normalizedKey] = collection;
      return OnlineArtistCollectionPage(
        artist: collection,
        hasMore: !cachedSession.fullyLoaded,
      );
    }

    try {
      final List<dynamic> artistResults = await client.search(
        fallbackName,
        filter: ytm.SearchFilter.artists,
      );
      final Map<dynamic, dynamic>? artistMatch = _pickArtistResult(
        artistResults,
        artistName: fallbackName,
      );
      if (artistMatch == null) {
        _ytMusicArtistCollectionCache[normalizedKey] = null;
        return null;
      }

      final String browseId = '${artistMatch['browseId'] ?? ''}'.trim();
      if (browseId.isEmpty) {
        _ytMusicArtistCollectionCache[normalizedKey] = null;
        return null;
      }

      final Map<String, dynamic> artistProfile = await client.getArtist(
        browseId,
      );
      final String resolvedName =
          '${artistProfile['name'] ?? fallbackName}'.trim().isNotEmpty
          ? '${artistProfile['name'] ?? fallbackName}'.trim()
          : fallbackName;
      final _OnlineArtistCollectionSession session =
          _OnlineArtistCollectionSession(
            normalizedKey: normalizedKey,
            fallbackArtistName: fallbackName,
            resolvedName: resolvedName,
            songsSection: _readArtistSection(artistProfile, 'songs'),
            albums: _buildOnlineArtistReleaseState(artistProfile, 'albums'),
            singles: _buildOnlineArtistReleaseState(artistProfile, 'singles'),
          );
      _ytMusicArtistCollectionSessionCache[normalizedKey] = session;
      await _expandOnlineArtistCollectionSession(
        client,
        session: session,
        minimumSongCount: targetSongCount,
      );
      if (session.songs.isEmpty && session.fullyLoaded) {
        _ytMusicArtistCollectionCache[normalizedKey] = null;
        _ytMusicArtistCollectionSessionCache.remove(normalizedKey);
        return null;
      }
      final ArtistCollection collection = ArtistCollection(
        id: normalizedKey,
        name: session.resolvedName,
        songs: List<LibrarySong>.unmodifiable(session.songs),
      );
      _ytMusicArtistCollectionCache[normalizedKey] = collection;
      return OnlineArtistCollectionPage(
        artist: collection,
        hasMore: !session.fullyLoaded,
      );
    } catch (_) {
      _ytMusicArtistCollectionSessionCache.remove(normalizedKey);
      rethrow;
    }
  }

  void disposeOnlineArtistCollectionSession(
    String artistKey, {
    String? artistName,
    bool clearResolvedCollection = true,
  }) {
    final String normalizedKey = _normalizeToken(artistName ?? artistKey);
    if (normalizedKey.isEmpty) {
      return;
    }
    _ytMusicArtistCollectionSessionCache.remove(normalizedKey);
    if (clearResolvedCollection) {
      _ytMusicArtistCollectionCache.remove(normalizedKey);
    }
  }

  Map<dynamic, dynamic>? _pickArtistResult(
    List<dynamic> results, {
    required String artistName,
  }) {
    final String normalizedTarget = _normalizeToken(artistName);
    Map<dynamic, dynamic>? best;
    double bestScore = double.negativeInfinity;

    for (final dynamic item in results) {
      if (item is! Map) {
        continue;
      }
      final String candidateName = _readArtistResultName(item) ?? '';
      final String candidate = _normalizeToken(candidateName);
      if (candidate.isEmpty) {
        continue;
      }

      double score = 0;
      if (candidate == normalizedTarget) {
        score += 100;
      } else if (candidate.startsWith(normalizedTarget) ||
          normalizedTarget.startsWith(candidate)) {
        score += 70;
      } else if (candidate.contains(normalizedTarget) ||
          normalizedTarget.contains(candidate)) {
        score += 40;
      }
      if (score <= 0) {
        continue;
      }

      final String subscribers = '${item['subscribers'] ?? ''}';
      if (subscribers.contains('M')) {
        score += 5;
      } else if (subscribers.contains('K')) {
        score += 2;
      }

      if (score > bestScore) {
        bestScore = score;
        best = Map<dynamic, dynamic>.from(item);
      }
    }

    return best;
  }

  Map<dynamic, dynamic>? _readArtistSection(
    Map<String, dynamic> artistProfile,
    String key,
  ) {
    return artistProfile[key] is Map
        ? Map<dynamic, dynamic>.from(artistProfile[key] as Map)
        : null;
  }

  _OnlineArtistReleaseState _buildOnlineArtistReleaseState(
    Map<String, dynamic> artistProfile,
    String key,
  ) {
    final Map<dynamic, dynamic>? section = _readArtistSection(
      artistProfile,
      key,
    );
    return _OnlineArtistReleaseState(
      browseId: '${section?['browseId'] ?? ''}'.trim(),
      params: '${section?['params'] ?? ''}'.trim(),
    );
  }

  Future<void> _expandOnlineArtistCollectionSession(
    YTMusic client, {
    required _OnlineArtistCollectionSession session,
    required int minimumSongCount,
  }) async {
    final int targetSongCount = math.max(1, minimumSongCount);
    while (session.songs.length < targetSongCount && !session.fullyLoaded) {
      final int beforeCount = session.songs.length;
      await _loadNextArtistSongsChunk(
        client,
        session: session,
        minimumSongCount: targetSongCount,
      );
      if (session.songs.length >= targetSongCount) {
        break;
      }
      await _loadNextArtistReleaseChunk(
        client,
        session: session,
        releaseState: session.singles,
        minimumSongCount: targetSongCount,
      );
      if (session.songs.length >= targetSongCount) {
        break;
      }
      await _loadNextArtistReleaseChunk(
        client,
        session: session,
        releaseState: session.albums,
        minimumSongCount: targetSongCount,
      );
      final bool exhaustedAllSources =
          session.playlistExhausted &&
          session.singles.exhausted &&
          session.albums.exhausted &&
          session.singles.pendingBrowseIds.isEmpty &&
          session.albums.pendingBrowseIds.isEmpty;
      if (exhaustedAllSources || session.songs.length == beforeCount) {
        session.fullyLoaded = true;
      }
    }

    session.songs.sort((LibrarySong a, LibrarySong b) {
      final int compare = _onlineSearchScore(
        b,
        query: session.resolvedName,
      ).compareTo(_onlineSearchScore(a, query: session.resolvedName));
      if (compare != 0) {
        return compare;
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }

  Future<void> _loadNextArtistSongsChunk(
    YTMusic client, {
    required _OnlineArtistCollectionSession session,
    required int minimumSongCount,
  }) async {
    if (session.playlistExhausted) {
      return;
    }

    final Map<dynamic, dynamic>? songsSection = session.songsSection;
    if (songsSection == null) {
      session.playlistExhausted = true;
      return;
    }

    final String browseId = '${songsSection['browseId'] ?? ''}'.trim();
    if (browseId.isEmpty) {
      _appendOnlineArtistSongs(
        session,
        songsSection['results'] as List<dynamic>? ?? const <dynamic>[],
        maxAdditionalSongs: math.max(
          0,
          minimumSongCount - session.songs.length,
        ),
      );
      session.playlistExhausted = true;
      return;
    }

    final int chunkSize = math.max(10, minimumSongCount - session.songs.length);
    final int requestLimit = session.playlistRequestedLimit + chunkSize;
    final Map<String, dynamic> playlist = await client.getPlaylist(
      browseId,
      limit: requestLimit,
    );
    final List<dynamic> tracks =
        playlist['tracks'] as List<dynamic>? ?? const <dynamic>[];
    _appendOnlineArtistSongs(
      session,
      tracks,
      maxAdditionalSongs: math.max(0, minimumSongCount - session.songs.length),
    );
    session.playlistRequestedLimit = requestLimit;
    if (tracks.length < requestLimit) {
      session.playlistExhausted = true;
    }
  }

  Future<void> _loadNextArtistReleaseChunk(
    YTMusic client, {
    required _OnlineArtistCollectionSession session,
    required _OnlineArtistReleaseState releaseState,
    required int minimumSongCount,
  }) async {
    if (!releaseState.isAvailable) {
      releaseState.exhausted = true;
      return;
    }

    while (session.songs.length < minimumSongCount) {
      if (releaseState.pendingBrowseIds.isNotEmpty) {
        final String albumBrowseId = releaseState.pendingBrowseIds.removeAt(0);
        if (!session.processedReleaseBrowseIds.add(albumBrowseId)) {
          continue;
        }
        try {
          final Map<String, dynamic> album = await client.getAlbum(
            albumBrowseId,
          );
          final List<dynamic> tracks =
              album['tracks'] as List<dynamic>? ?? const <dynamic>[];
          _appendOnlineArtistSongs(
            session,
            tracks,
            maxAdditionalSongs: math.max(
              0,
              minimumSongCount - session.songs.length,
            ),
          );
        } catch (_) {
          continue;
        }
        continue;
      }

      if (releaseState.exhausted) {
        return;
      }

      final int requestLimit = releaseState.requestedLimit + 6;
      final List<dynamic> releases = await client.getArtistAlbums(
        releaseState.browseId,
        releaseState.params,
        limit: requestLimit,
      );
      for (final dynamic release in releases) {
        if (release is! Map) {
          continue;
        }
        final String albumBrowseId = '${release['browseId'] ?? ''}'.trim();
        if (albumBrowseId.isEmpty ||
            !albumBrowseId.startsWith('MPRE') ||
            releaseState.queuedBrowseIds.contains(albumBrowseId) ||
            session.processedReleaseBrowseIds.contains(albumBrowseId)) {
          continue;
        }
        releaseState.queuedBrowseIds.add(albumBrowseId);
        releaseState.pendingBrowseIds.add(albumBrowseId);
      }
      releaseState.requestedLimit = requestLimit;
      if (releases.length < requestLimit) {
        releaseState.exhausted = true;
      }
      if (releaseState.pendingBrowseIds.isEmpty) {
        if (releaseState.exhausted) {
          return;
        }
        continue;
      }
    }
  }

  void _appendOnlineArtistSongs(
    _OnlineArtistCollectionSession session,
    Iterable<dynamic> items, {
    int? maxAdditionalSongs,
  }) {
    int added = 0;
    for (final dynamic item in items) {
      if (maxAdditionalSongs != null && added >= maxAdditionalSongs) {
        break;
      }
      if (item is! Map) {
        continue;
      }
      final Map<dynamic, dynamic> data = Map<dynamic, dynamic>.from(item);
      final LibrarySong? song = _ytMusicItemToSong(data);
      if (song == null ||
          !_ytMusicItemMatchesArtist(
            data,
            song: song,
            artistName: session.resolvedName,
          )) {
        continue;
      }
      final String key = _songIdentityKey(song);
      if (!session.seenSongKeys.add(key)) {
        continue;
      }
      session.songs.add(song);
      _rememberTransientSong(song);
      added += 1;
    }
  }

  bool _ytMusicItemMatchesArtist(
    Map<dynamic, dynamic> data, {
    required LibrarySong song,
    required String artistName,
  }) {
    final String normalizedTarget = _normalizeToken(artistName);
    if (normalizedTarget.isEmpty) {
      return true;
    }

    final Set<String> candidates = <String>{};

    void addCandidate(String rawValue) {
      final String raw = rawValue.trim();
      if (raw.isEmpty || raw.toLowerCase() == 'null') {
        return;
      }
      candidates.add(_normalizeToken(raw));
      for (final String part in raw.split(
        RegExp(r'\s*(?:,|&|/|;| and | with | feat\.? | ft\.? | x )\s*'),
      )) {
        final String normalizedPart = _normalizeToken(part);
        if (normalizedPart.isNotEmpty) {
          candidates.add(normalizedPart);
        }
      }
    }

    final dynamic artists = data['artists'];
    if (artists is List) {
      for (final dynamic artist in artists) {
        if (artist is Map) {
          addCandidate('${artist['name'] ?? artist['title'] ?? ''}');
        } else {
          addCandidate('$artist');
        }
      }
    }
    if (data['artist'] != null) {
      addCandidate('${data['artist']}');
    }
    addCandidate(song.artist);

    for (final String candidate in candidates) {
      if (candidate.isEmpty) {
        continue;
      }
      final String paddedCandidate = ' $candidate ';
      final String paddedTarget = ' $normalizedTarget ';
      if (candidate == normalizedTarget ||
          paddedCandidate.contains(paddedTarget) ||
          paddedTarget.contains(paddedCandidate)) {
        return true;
      }
    }
    return false;
  }

  int _manualQueueInsertionIndex() {
    if (_queueSongIds.isEmpty) {
      return 0;
    }
    final int anchorIndex = visibleQueueIndex.clamp(
      0,
      _queueSongIds.length - 1,
    );
    final int preloadCount = _settings.preloadNextSongCount.clamp(0, 3);
    return math.min(_queueSongIds.length, anchorIndex + preloadCount + 1);
  }

  int? _shiftQueueIndexAfterRemoval(int? value, int removedIndex) {
    if (value == null) {
      return null;
    }
    if (value == removedIndex) {
      return null;
    }
    if (value > removedIndex) {
      return value - 1;
    }
    return value;
  }

  void _normalizeQueueStateAfterRemoval({
    required int removedIndex,
    required String removedSongId,
  }) {
    _offlineQueueWaitingIndex = _shiftQueueIndexAfterRemoval(
      _offlineQueueWaitingIndex,
      removedIndex,
    );
    if (_offlineQueueWaitingSongId == removedSongId) {
      _offlineQueueWaitingSongId = null;
      _offlineQueueWaitingShouldResume = false;
      _statusMessage = null;
    }

    _transitioningQueueIndex = _shiftQueueIndexAfterRemoval(
      _transitioningQueueIndex,
      removedIndex,
    );
    if (_transitioningSongId == removedSongId) {
      _transitioningSongId = null;
      _pendingSelectionSong = null;
    }

    _offlineQueueActivationTargetIndex = _shiftQueueIndexAfterRemoval(
      _offlineQueueActivationTargetIndex,
      removedIndex,
    );
    if (_offlineQueueActivationTargetSongId == removedSongId) {
      _offlineQueueActivationTargetSongId = null;
    }
    if (_offlineQueueActivationSongIds != null) {
      _offlineQueueActivationSongIds = List<String>.from(
        _offlineQueueActivationSongIds!,
      )..remove(removedSongId);
    }

    _playbackFallbackRecoveryIndex = _shiftQueueIndexAfterRemoval(
      _playbackFallbackRecoveryIndex,
      removedIndex,
    );
    if (_playbackFallbackRecoverySongId == removedSongId) {
      _playbackFallbackRecoverySongId = null;
      _playbackFallbackRecoveryIndex = null;
    }

    for (int index = _standbyPreloads.length - 1; index >= 0; index -= 1) {
      final _StandbyPreloadSlot slot = _standbyPreloads[index];
      if (slot.songId == removedSongId || slot.queueIndex == removedIndex) {
        final _StandbyPreloadSlot removed = _standbyPreloads.removeAt(index);
        unawaited(removed.dispose());
        continue;
      }
      if (slot.queueIndex > removedIndex) {
        _standbyPreloads[index] = _StandbyPreloadSlot(
          queueIndex: slot.queueIndex - 1,
          songId: slot.songId,
          player: slot.player,
        );
      }
    }
  }

  Future<void> enqueueSong(LibrarySong song) async {
    registerUserActivity(reason: 'enqueue-song', notify: false);
    if (!shouldShowSongOutsideSearch(song)) {
      return;
    }
    final Set<String> dislikedKeys = dislikedSongs
        .map(_songIdentityKey)
        .toSet();
    if (song.isDisliked || dislikedKeys.contains(_songIdentityKey(song))) {
      return;
    }
    if (_queueSongIds.isEmpty) {
      await playSong(song, label: 'Queue');
      return;
    }
    final String preparedKey = _songIdentityKey(song);
    final bool alreadyQueued =
        _queueSongIds.contains(song.id) ||
        queueSongs.any(
          (LibrarySong queuedSong) =>
              _songIdentityKey(queuedSong) == preparedKey,
        );
    if (alreadyQueued) {
      return;
    }
    _smartQueueSongIds.remove(song.id);
    final int insertionIndex = _manualQueueInsertionIndex();
    _queueSongIds = List<String>.from(_queueSongIds)
      ..insert(insertionIndex, song.id);
    _detachedSequentialQueueSongIds = List<String>.from(
      _detachedSequentialQueueSongIds,
    )..insert(insertionIndex, song.id);

    if (insertionIndex <= _queueIndex) {
      _queueIndex += 1;
    }

    // When in detached mode, the underlying player playlist only contains the
    // currently playing track. Adding a new raw media item can cause the
    // player to auto-advance and try to open unprepared URLs.
    if (_offlineDetachedQueueMode) {
      unawaited(_refreshOfflinePlaybackCache(anchor: currentSong ?? song));
      _invalidateStandbyPreloads();
      notifyListeners();
      return;
    }

    await _player.add(_mediaForSong(song));
    if (insertionIndex < _queueSongIds.length - 1) {
      await _player.move(_queueSongIds.length - 1, insertionIndex);
    }
    unawaited(_refreshOfflinePlaybackCache(anchor: currentSong ?? song));
    _invalidateStandbyPreloads();
    notifyListeners();
  }

  Future<void> insertSongIntoQueueAt(
    LibrarySong song, {
    required int index,
    bool resumePlaybackWhenQueueWasEmpty = false,
  }) async {
    if (!shouldShowSongOutsideSearch(song) && _queueSongIds.isNotEmpty) {
      return;
    }

    if (_queueSongIds.isEmpty) {
      await playSong(song, label: _queueLabel);
      if (!resumePlaybackWhenQueueWasEmpty) {
        await pause();
      }
      return;
    }

    final int insertionIndex = index.clamp(0, _queueSongIds.length);
    _smartQueueSongIds.remove(song.id);
    _queueSongIds = List<String>.from(_queueSongIds)
      ..insert(insertionIndex, song.id);
    _detachedSequentialQueueSongIds = List<String>.from(
      _detachedSequentialQueueSongIds,
    )..insert(insertionIndex, song.id);

    if (insertionIndex <= _queueIndex) {
      _queueIndex += 1;
    }

    if (_offlineDetachedQueueMode) {
      unawaited(_refreshOfflinePlaybackCache(anchor: currentSong ?? song));
      _invalidateStandbyPreloads();
      notifyListeners();
      return;
    }

    await _player.add(_mediaForSong(song));
    if (insertionIndex < _queueSongIds.length - 1) {
      await _player.move(_queueSongIds.length - 1, insertionIndex);
    }
    unawaited(_refreshOfflinePlaybackCache(anchor: currentSong ?? song));
    _invalidateStandbyPreloads();
    notifyListeners();
  }

  Future<LibrarySong> _preparePlayableSong(LibrarySong song) async {
    _rememberTransientSong(song);
    if (!song.isRemote) {
      _preparedMediaUrlsBySongId[song.id] = song.path;
      _preparedMediaHeadersBySongId[song.id] = null;
      _playbackStreamInfoBySongId[song.id] = buildLocalPlaybackStreamInfo(song);
      return song;
    }

    if (offlineMusicMode || await _resolveOfflineStateForAction()) {
      throw const SocketException('Streaming is unavailable while offline.');
    }

    final _ResolvedRemotePlayback resolved = await _resolvePlayableRemoteStream(
      song,
      preferPlaybackCompatibility: true,
    );
    await _prepareResolvedRemoteStreamForPlayback(song, resolved);
    _playbackStreamInfoBySongId[song.id] = resolved.streamInfo;
    _debugPlayback(
      'stream.resolved song=${_debugSongLabel(song)} '
      '${resolved.streamInfo.debugSummary}',
    );
    return song;
  }

  Future<void> _prepareResolvedRemoteStreamForPlayback(
    LibrarySong song,
    _ResolvedRemotePlayback resolved,
  ) async {
    // Always store the direct upstream URL here. Proxy-based stream caching
    // is activated separately by _enableProxyCachingForSong, which is called
    // only when the user explicitly starts playback — not during prefetch.
    _preparedMediaUrlsBySongId[song.id] = resolved.resolvedUrl;
    _preparedMediaHeadersBySongId[song.id] = resolved.upstreamHeaders;
  }

  /// Registers a playback proxy session that simultaneously streams audio to
  /// [media_kit] and writes it to an offline cache file. Must be called only
  /// for songs the user has explicitly started playing (not prefetch).
  Future<void> _enableProxyCachingForSong(LibrarySong song) async {
    if (!offlinePlaybackCacheEnabled ||
        !_shouldCacheSongForOfflinePlayback(song) ||
        _hasOfflinePlaybackCache(song.id) ||
        _isDisposing ||
        _isDisposed) {
      return;
    }
    if (_playbackProxyBypassSongIds.contains(song.id)) {
      _debugPlayback(
        'proxy.cache skipped bypassed song=${_debugSongLabel(song)}',
      );
      return;
    }
    // Already streaming through an active proxy — nothing to do.
    if (_isSongUsingPlaybackProxy(song.id)) {
      return;
    }
    final String? directUrl = _preparedMediaUrlsBySongId[song.id];
    if (directUrl == null ||
        directUrl.startsWith('http://127.0.0.1:') ||
        directUrl.startsWith('http://localhost:')) {
      return;
    }
    final Map<String, String>? upstreamHeaders =
        _preparedMediaHeadersBySongId[song.id];
    try {
      final String sessionId = _uuid.v4();
      final File targetFile = await _offlinePlaybackCacheTargetFile(
        song,
        directUrl,
        streamInfo: _playbackStreamInfoBySongId[song.id],
      );
      final String proxyUrl = await _playbackProxy.register(
        sessionId: sessionId,
        songId: song.id,
        upstreamUri: Uri.parse(directUrl),
        upstreamHeaders: upstreamHeaders,
        cacheFilePath: targetFile.path,
        responseContentType: _playbackProxyContentType(
          _playbackStreamInfoBySongId[song.id],
        ),
        urlFileName: _playbackProxyUrlFileName(
          song,
          _playbackStreamInfoBySongId[song.id],
        ),
        cacheEpoch: _offlinePlaybackCacheEpoch,
      );
      _activePlaybackProxiesBySongId[song.id] = _ActivePlaybackProxy(
        sessionId: sessionId,
        proxyUrl: proxyUrl,
        upstreamUrl: directUrl,
        upstreamHeaders: upstreamHeaders,
      );
      _playbackProxyBypassSongIds.remove(song.id);
      _preparedMediaUrlsBySongId[song.id] = proxyUrl;
      _preparedMediaHeadersBySongId[song.id] = null;
      _debugPlayback(
        'proxy.cache enabled song=${_debugSongLabel(song)} '
        'cacheFile=${targetFile.path}',
      );
    } catch (error) {
      _debugPlayback(
        'proxy.cache setup failed song=${_debugSongLabel(song)} error=$error',
      );
    }
  }

  Future<void> _openPreparedSong(
    LibrarySong song, {
    required String label,
    int? selectionRevision,
  }) async {
    if (selectionRevision != null &&
        !_guardCurrentPlaybackSelection(
          selectionRevision,
          'openPrepared.start',
        )) {
      return;
    }
    _clearOfflineQueueWait(notify: false);
    _offlineDetachedQueueMode = false;
    _pendingSelectionSong = song;
    _beginPlaybackActivation(song, resetMetrics: true, notify: false);
    notifyListeners();
    _rememberTransientSong(song);
    try {
      _smartQueueSongIds.clear();
      _queueSongIds = <String>[song.id];
      _detachedSequentialQueueSongIds = List<String>.from(_queueSongIds);
      _queueLabel = label;
      _queueIndex = 0;
      await _ensureSequentialPlayback();
      if (selectionRevision != null &&
          !_guardCurrentPlaybackSelection(
            selectionRevision,
            'openPrepared.after-queue-setup',
          )) {
        return;
      }
      // Enable proxy caching before opening the player so media_kit streams
      // through the proxy, which writes to disk simultaneously.
      await _enableProxyCachingForSong(song);
      if (selectionRevision != null &&
          !_guardCurrentPlaybackSelection(
            selectionRevision,
            'openPrepared.after-proxy',
          )) {
        return;
      }
      await _player.open(Playlist(<Media>[_mediaForSong(song)]), play: false);
      await _syncPlayerPlaybackModes(_player);
      if (selectionRevision != null &&
          !_guardCurrentPlaybackSelection(
            selectionRevision,
            'openPrepared.after-open',
          )) {
        return;
      }
      await _player.play();
      _trackPlayback(song.id);
      _scheduleSmartQueueWindowRefill(seed: song);
      unawaited(_refreshOfflinePlaybackCache(anchor: song));
      _invalidateStandbyPreloads();
      notifyListeners();
    } catch (_) {
      _pendingSelectionSong = null;
      notifyListeners();
      rethrow;
    }
  }

  Media _mediaForSong(LibrarySong song) {
    return Media(
      _resolvedMediaUrlForSong(song),
      extras: <String, dynamic>{'songId': song.id},
      httpHeaders: _resolvedMediaHeadersForSong(song),
    );
  }

  String _resolvedMediaUrlForSong(LibrarySong song) {
    final String? cachedPath = _offlinePlaybackCachePathForSong(song.id);
    if (cachedPath != null) {
      return cachedPath;
    }

    final String? prepared = _preparedMediaUrlsBySongId[song.id];
    if (prepared != null && prepared.isNotEmpty) {
      return prepared;
    }
    return song.path;
  }

  Map<String, String>? _resolvedMediaHeadersForSong(LibrarySong song) {
    if (_offlinePlaybackCachePathForSong(song.id) != null) {
      return null;
    }
    if (_preparedMediaHeadersBySongId.containsKey(song.id)) {
      return _preparedMediaHeadersBySongId[song.id];
    }
    return song.isRemote ? _upstreamHeadersForUrl(song, song.path) : null;
  }

  Media? _playerQueueMediaAt(int index) {
    final List<Media> medias = _player.state.playlist.medias;
    if (index < 0 || index >= medias.length) {
      return null;
    }
    return medias[index];
  }

  bool _playerQueueEntryNeedsRefresh(LibrarySong song, int index) {
    final Media? media = _playerQueueMediaAt(index);
    if (media == null) {
      return true;
    }
    final String expectedUrl = Media.normalizeURI(
      _resolvedMediaUrlForSong(song),
    );
    if (media.uri != expectedUrl) {
      _debugPlayback(
        'queue.refresh stale media '
        'index=$index song=${_debugSongLabel(song)} '
        'expected="$expectedUrl" actual="${media.uri}"',
      );
      return true;
    }
    final Map<String, String>? expectedHeaders = _resolvedMediaHeadersForSong(
      song,
    );
    if (!mapEquals(media.httpHeaders, expectedHeaders)) {
      _debugPlayback(
        'queue.refresh stale headers '
        'index=$index song=${_debugSongLabel(song)}',
      );
      return true;
    }
    return false;
  }

  bool _queueSongNeedsQueueRefresh(LibrarySong song, int index) {
    if (_queueSongNeedsPreparedMediaSource(song)) {
      return true;
    }
    return _playerQueueEntryNeedsRefresh(song, index);
  }

  bool _isSongUsingPlaybackProxy(String songId) {
    final _ActivePlaybackProxy? activeProxy =
        _activePlaybackProxiesBySongId[songId];
    if (activeProxy == null) {
      return false;
    }
    return _preparedMediaUrlsBySongId[songId] == activeProxy.proxyUrl;
  }

  void _disablePlaybackProxyForSong(
    String songId, {
    bool bypass = false,
    bool keepCachingIfActive = true,
  }) {
    if (bypass) {
      _playbackProxyBypassSongIds.add(songId);
    } else {
      _playbackProxyBypassSongIds.remove(songId);
    }
    final _ActivePlaybackProxy? existing = _activePlaybackProxiesBySongId
        .remove(songId);
    if (existing != null) {
      if (keepCachingIfActive &&
          _playbackProxy.isCacheWriteInProgress(existing.sessionId)) {
        // The proxy is still downloading and writing the cache file.
        // Detach the session from routing (proxy URL now returns 404 for new
        // requests) but keep the upstream stream alive so the cache completes.
        // _handlePlaybackProxyCacheCompleted will fire when done.
        unawaited(_playbackProxy.unregisterKeepCaching(existing.sessionId));
        _proxyCachingOnlySongIds.add(songId);
        _debugPlayback(
          'proxy.detached song=$songId — cache write continues in background',
        );
      } else {
        unawaited(_playbackProxy.unregister(existing.sessionId));
        _completeOfflinePlaybackCacheWaiters(songId, false);
      }
    }
  }

  Future<_ResolvedRemotePlayback> _resolvePlayableRemoteStream(
    LibrarySong song, {
    bool preferPlaybackCompatibility = false,
  }) async {
    if (!_looksLikeYouTube(song.path)) {
      return _ResolvedRemotePlayback(
        resolvedUrl: song.path,
        upstreamHeaders: _upstreamHeadersForUrl(song, song.path),
        streamInfo: buildDirectPlaybackStreamInfo(song),
      );
    }

    final List<PlaybackStreamCandidate> rankedCandidates =
        await _rankedPlaybackCandidatesForSong(song);

    if (rankedCandidates.isEmpty) {
      throw const FormatException('No playable online stream found.');
    }

    final int currentIndex = (_playbackCandidateIndexBySongId[song.id] ?? 0)
        .clamp(0, rankedCandidates.length - 1);
    int selectedIndex = preferredPlaybackCandidateIndex(
      rankedCandidates: rankedCandidates,
      currentIndex: currentIndex,
      preferMuxedStability:
          preferPlaybackCompatibility &&
          (Platform.isWindows || Platform.isAndroid),
    );
    String selectionPolicy = selectedIndex == currentIndex
        ? (selectedIndex == 0
              ? 'muxed-first-streaming'
              : 'fallback-after-open-failure')
        : 'windows-muxed-stability-first';
    _playbackCandidateIndexBySongId[song.id] = selectedIndex;
    final PlaybackStreamResolution resolved = resolvePlaybackStreamAtIndex(
      songId: song.id,
      sourceLabel: song.sourceLabel,
      originalUrl: song.path,
      externalUrl: song.externalUrl,
      candidates: rankedCandidates,
      rankedCandidates: rankedCandidates,
      selectedIndex: selectedIndex,
      selectionPolicy: selectionPolicy,
    );
    return _ResolvedRemotePlayback(
      resolvedUrl: resolved.url,
      upstreamHeaders: _upstreamHeadersForUrl(song, resolved.url),
      streamInfo: resolved.info,
      youtubeStreamInfo: rankedCandidates[selectedIndex].source as StreamInfo?,
    );
  }

  Future<List<PlaybackStreamCandidate>> _rankedPlaybackCandidatesForSong(
    LibrarySong song,
  ) async {
    final DateTime? backoffUntil = _youtubeRequestBackoffUntil;
    if (backoffUntil != null && DateTime.now().isBefore(backoffUntil)) {
      throw StateError(
        'Online playback is temporarily rate limited. Please wait a little and try again.',
      );
    }
    final List<PlaybackStreamCandidate>? cachedCandidates =
        _rankedPlaybackCandidatesBySongId[song.id];
    if (cachedCandidates != null && cachedCandidates.isNotEmpty) {
      return cachedCandidates;
    }

    late final StreamManifest manifest;
    try {
      manifest = await _yt.videos.streams.getManifest(song.path);
      _youtubeRequestBackoffUntil = null;
    } catch (error) {
      if (_isYouTubeRateLimitError(error)) {
        _youtubeRequestBackoffUntil = DateTime.now().add(
          const Duration(seconds: 90),
        );
      }
      rethrow;
    }
    final List<PlaybackStreamCandidate> rankedCandidates =
        rankPlaybackStreamCandidates(_buildPlaybackStreamCandidates(manifest));
    _rankedPlaybackCandidatesBySongId[song.id] = rankedCandidates;
    return rankedCandidates;
  }

  Future<_ResolvedDownloadPayload> _downloadRemoteSong(LibrarySong song) async {
    final Directory downloadsRoot = await _downloadsDirectory();
    await downloadsRoot.create(recursive: true);
    final String baseName = _safeDownloadBaseName(song);
    final _ResolvedRemotePlayback resolved = await _resolvePlayableRemoteStream(
      song,
      preferPlaybackCompatibility: true,
    );
    final Uri? uri = Uri.tryParse(resolved.resolvedUrl);
    if (uri == null || !uri.hasScheme) {
      throw const FileSystemException('Unsupported download source');
    }
    final String extension = _downloadExtensionForSong(
      song,
      uri: uri,
      resolved: resolved,
    );
    final String audioPath = p.join(downloadsRoot.path, '$baseName.$extension');
    await _downloadUriToFile(uri, audioPath, headers: resolved.upstreamHeaders);
    final String? artworkPath = await _downloadArtworkForSong(
      song,
      downloadsRoot,
      baseName,
    );
    return _ResolvedDownloadPayload(
      audioPath: audioPath,
      artworkPath: artworkPath,
      title: song.title,
      artist: song.artist,
      album: song.album,
      albumArtist: song.albumArtist,
      durationMs: song.durationMs,
    );
  }

  String _downloadExtensionForSong(
    LibrarySong song, {
    required Uri uri,
    required _ResolvedRemotePlayback resolved,
  }) {
    final StreamInfo? info = resolved.youtubeStreamInfo;
    if (info case final AudioOnlyStreamInfo audioOnly) {
      return audioOnly.container.name;
    }
    if (info case final MuxedStreamInfo muxed) {
      return muxed.container.name;
    }
    final String extension = _extensionFromUri(uri);
    if (extension.isNotEmpty) {
      return extension;
    }
    if (_looksLikeYouTube(song.path)) {
      return 'm4a';
    }
    return 'mp3';
  }

  Future<Directory> _downloadsDirectory() async {
    final Directory root = await getApplicationSupportDirectory();
    return Directory(p.join(root.path, 'downloads'));
  }

  String _safeDownloadBaseName(LibrarySong song) {
    final String raw = '${song.artist} - ${song.title}'
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final String normalized = raw.isEmpty ? song.id : raw;
    final String suffix = song.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${normalized.substring(0, math.min(normalized.length, 70))}_$suffix';
  }

  String _extensionFromUri(Uri uri) {
    final String extension = p.extension(uri.path).replaceFirst('.', '').trim();
    return extension;
  }

  Future<void> _downloadUriToFile(
    Uri uri,
    String outputPath, {
    Map<String, String>? headers,
  }) async {
    final File tempFile = File('$outputPath.part');
    final File finalFile = File(outputPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      headers?.forEach(request.headers.set);
      final HttpClientResponse response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download request failed with status ${response.statusCode}',
          uri: uri,
        );
      }
      final IOSink sink = tempFile.openWrite();
      await response.cast<List<int>>().pipe(sink);
      await sink.flush();
      await sink.close();
      final int length = await tempFile.length();
      if (length <= 0) {
        throw const FileSystemException('Downloaded file is empty');
      }
      await tempFile.rename(outputPath);
    } catch (_) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _downloadArtworkForSong(
    LibrarySong song,
    Directory downloadsRoot,
    String baseName,
  ) async {
    final String? artworkUrl = song.artworkUrl;
    if (artworkUrl == null || artworkUrl.trim().isEmpty) {
      return null;
    }
    final Uri? uri = Uri.tryParse(artworkUrl);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    try {
      final String extension = _extensionFromUri(uri).isEmpty
          ? 'jpg'
          : _extensionFromUri(uri);
      final String artworkPath = p.join(
        downloadsRoot.path,
        '${baseName}_art.$extension',
      );
      final File artworkFile = File(artworkPath);
      await _downloadUriToFile(uri, artworkFile.path);
      return artworkPath;
    } catch (_) {
      return null;
    }
  }

  bool _isYouTubeRateLimitError(Object error) {
    final String message = '$error'.toLowerCase();
    return message.contains('requestlimitexceededexception') ||
        message.contains('rate limiting') ||
        message.contains('too many requests');
  }

  String _friendlyPlaybackErrorMessage(Object error) {
    if (_isYouTubeRateLimitError(error)) {
      return 'Online playback is temporarily blocked from this device. Please wait a bit and try again.';
    }
    return '$error';
  }

  bool _isPlayableOpenFailure(String message) {
    final String normalized = message.toLowerCase();
    return normalized.contains('failed to open http://') ||
        normalized.contains('failed to open https://') ||
        normalized.contains('failed to recognize file format');
  }

  bool _isLocalPlaybackProxyFailure(String message) {
    final String normalized = message.toLowerCase();
    return normalized.contains('failed to open http://127.0.0.1:') ||
        normalized.contains('failed to open http://localhost:');
  }

  void _primePlaybackFallbackRecovery(LibrarySong song) {
    final int queueSongIndex = _queueSongIds.indexOf(song.id);
    _playbackFallbackRecoverySongId = song.id;
    _playbackFallbackRecoveryIndex = queueSongIndex >= 0
        ? queueSongIndex
        : null;
    _transitioningSongId = song.id;
    if (queueSongIndex >= 0) {
      _transitioningQueueIndex = queueSongIndex;
    }
    _pendingSelectionSong = song;
    _position = Duration.zero;
    _duration = Duration.zero;
    _beginPlaybackActivation(song, notify: false);
    // Lock the queue immediately to prevent auto-advance
    _playbackRecoveryQueueLocked = true;
    _debugPlayback(
      'stream.fallback prime song=${_debugSongLabel(song)} '
      'targetIndex=$_playbackFallbackRecoveryIndex queueIndex=$_queueIndex',
    );
    notifyListeners();
  }

  void _clearPlaybackFallbackRecoveryState() {
    _playbackFallbackRecoverySongId = null;
    _playbackFallbackRecoveryIndex = null;
    // Unlock queue after recovery
    _playbackRecoveryQueueLocked = false;
  }

  Future<void> _pausePlayerForFallbackRecovery() async {
    try {
      await _player.pause();
    } catch (_) {}
    try {
      // Stop the native player while fallback resolution runs. Re-opening the
      // failed media here can make Android fetch the direct googlevideo URL
      // before the saver has a chance to wrap the fallback stream.
      await _player.stop();
    } catch (_) {}
  }

  bool _schedulePlaybackFallbackRecovery(
    LibrarySong song, {
    bool bypassPlaybackProxy = false,
  }) {
    if (_playbackFallbackRecoveryInFlight || !_looksLikeYouTube(song.path)) {
      return false;
    }
    // Check if this song is already queued for fallback to prevent rapid cycling
    if (_playbackFallbackRecoverySongId == song.id) {
      return false;
    }
    // LOCK FIRST to prevent playlist events from interfering
    _playbackRecoveryQueueLocked = true;
    final bool shouldBypassPlaybackProxy =
        bypassPlaybackProxy || _isSongUsingPlaybackProxy(song.id);
    _playbackFallbackRecoveryInFlight = true;
    if (shouldBypassPlaybackProxy) {
      _disablePlaybackProxyForSong(
        song.id,
        bypass: true,
        keepCachingIfActive: false,
      );
    }
    _primePlaybackFallbackRecovery(song);
    final int selectionRevision = _playbackSelectionRevision;
    unawaited(_pausePlayerForFallbackRecovery());
    unawaited(() async {
      try {
        if (!_guardCurrentPlaybackSelection(
          selectionRevision,
          'fallback.before-rank',
        )) {
          return;
        }
        // Rank candidates on-demand.
        // Without this, fallback recovery silently fails for upcoming songs
        // that were never prepared/opened.
        final List<PlaybackStreamCandidate> rankedCandidates =
            await _rankedPlaybackCandidatesForSong(song);

        if (!_guardCurrentPlaybackSelection(
          selectionRevision,
          'fallback.after-rank',
        )) {
          return;
        }
        if (rankedCandidates.isEmpty) {
          return;
        }

        final int candidateCount = rankedCandidates.length;
        final int currentIndex = (_playbackCandidateIndexBySongId[song.id] ?? 0)
            .clamp(0, candidateCount - 1);

        final int? targetIndex = nextPlaybackFallbackIndex(
          rankedCandidates,
          currentIndex,
        );
        if (targetIndex == null) {
          return;
        }

        await _recoverPlaybackWithFallback(
          song: song,
          currentIndex: currentIndex,
          nextIndex: targetIndex,
          bypassPlaybackProxy: shouldBypassPlaybackProxy,
          selectionRevision: selectionRevision,
        );
      } finally {
        // If we returned early before calling _recoverPlaybackWithFallback,
        // we still need to clear in-flight state and transitions.
        if (_playbackFallbackRecoveryInFlight &&
            _playbackFallbackRecoverySongId == song.id) {
          _clearPlaybackActivation();
          _clearTrackTransition();
          _clearPlaybackFallbackRecoveryState();
          _playbackFallbackRecoveryInFlight = false;
        }
      }
    }());
    return true;
  }

  Future<void> _recoverPlaybackWithFallback({
    required LibrarySong song,
    required int currentIndex,
    required int nextIndex,
    required bool bypassPlaybackProxy,
    required int selectionRevision,
  }) async {
    try {
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'fallback.before-resolve',
      )) {
        return;
      }
      _playbackCandidateIndexBySongId[song.id] = nextIndex;
      final _ResolvedRemotePlayback resolved =
          await _resolvePlayableRemoteStream(
            song,
            preferPlaybackCompatibility: true,
          );
      if (!_guardCurrentPlaybackSelection(
        selectionRevision,
        'fallback.after-resolve',
      )) {
        return;
      }
      _disablePlaybackProxyForSong(
        song.id,
        bypass: bypassPlaybackProxy,
        keepCachingIfActive: false,
      );
      _preparedMediaUrlsBySongId[song.id] = resolved.resolvedUrl;
      _preparedMediaHeadersBySongId[song.id] = resolved.upstreamHeaders;
      _playbackStreamInfoBySongId[song.id] = resolved.streamInfo;
      _errorMessage = null;
      _debugPlayback(
        'stream.fallback song=${_debugSongLabel(song)} '
        'fromIndex=$currentIndex toIndex=$nextIndex '
        'proxyBypass=$bypassPlaybackProxy '
        '${resolved.streamInfo.debugSummary}',
      );

      final int queueSongIndex = _queueSongIds.indexOf(song.id);
      if (queueSongIndex >= 0) {
        if (!_guardCurrentPlaybackSelection(
          selectionRevision,
          'fallback.before-reopen',
        )) {
          return;
        }
        await _reopenQueueAtIndex(queueSongIndex, forcePlay: true);
      } else {
        final LibrarySong prepared = await _preparePlayableSong(song);
        if (!_guardCurrentPlaybackSelection(
          selectionRevision,
          'fallback.after-prepare',
        )) {
          return;
        }
        await _openPreparedSong(
          prepared,
          label: _queueLabel,
          selectionRevision: selectionRevision,
        );
      }
      notifyListeners();
    } catch (error) {
      _debugPlayback(
        'stream.fallback failed song=${_debugSongLabel(song)} '
        'fromIndex=$currentIndex toIndex=$nextIndex error=$error',
      );
      _clearPlaybackActivation();
    } finally {
      _clearPlaybackFallbackRecoveryState();
      _playbackFallbackRecoveryInFlight = false;
    }
  }

  List<PlaybackStreamCandidate> _buildPlaybackStreamCandidates(
    StreamManifest manifest,
  ) {
    final List<PlaybackStreamCandidate> candidates = <PlaybackStreamCandidate>[
      ...manifest.audioOnly.map((AudioOnlyStreamInfo stream) {
        return _playbackStreamCandidate(
          stream: stream,
          transport: PlaybackStreamTransport.audioOnly,
        );
      }),
      ...manifest.muxed.map((MuxedStreamInfo stream) {
        return _playbackStreamCandidate(
          stream: stream,
          transport: PlaybackStreamTransport.muxed,
        );
      }),
      ...manifest.streams.whereType<HlsAudioStreamInfo>().map((
        HlsAudioStreamInfo stream,
      ) {
        return _playbackStreamCandidate(
          stream: stream,
          transport: PlaybackStreamTransport.hlsAudioOnly,
        );
      }),
      ...manifest.streams.whereType<HlsMuxedStreamInfo>().map((
        HlsMuxedStreamInfo stream,
      ) {
        return _playbackStreamCandidate(
          stream: stream,
          transport: PlaybackStreamTransport.hlsMuxed,
        );
      }),
      ...manifest.streams.whereType<HlsVideoStreamInfo>().map((
        HlsVideoStreamInfo stream,
      ) {
        return _playbackStreamCandidate(
          stream: stream,
          transport: PlaybackStreamTransport.hlsVideoOnly,
        );
      }),
    ];
    return candidates;
  }

  PlaybackStreamCandidate _playbackStreamCandidate({
    required StreamInfo stream,
    required PlaybackStreamTransport transport,
  }) {
    return PlaybackStreamCandidate(
      transport: transport,
      url: stream.url.toString(),
      bitrateBitsPerSecond: stream.bitrate.bitsPerSecond,
      source: stream,
      streamTag: stream.tag,
      videoHeight: stream is VideoStreamInfo
          ? stream.videoResolution.height
          : null,
      qualityLabel: stream.qualityLabel,
      containerName: stream.container.name,
      codecDescription: stream.codec.toString(),
      audioCodec: stream is AudioStreamInfo ? stream.audioCodec : null,
      videoCodec: stream is VideoStreamInfo ? stream.videoCodec : null,
    );
  }

  Map<String, String>? _upstreamHeadersForUrl(
    LibrarySong song,
    String resolvedUrl,
  ) {
    final Uri? uri = Uri.tryParse(resolvedUrl);
    if (uri == null || !uri.hasScheme) {
      return null;
    }

    final String host = uri.host.toLowerCase();
    if (host.contains('googlevideo.com') ||
        host.contains('youtube.com') ||
        host.contains('youtu.be')) {
      final String referer = (song.externalUrl ?? '').trim().isNotEmpty
          ? song.externalUrl!
          : song.sourceLabel == 'Online Stream' || song.sourceLabel == 'YouTube'
          ? 'https://www.youtube.com/'
          : 'https://music.youtube.com/';
      return <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Referer': referer,
        'Origin': referer.startsWith('https://www.youtube.com')
            ? 'https://www.youtube.com'
            : 'https://music.youtube.com',
        'Accept': '*/*',
      };
    }

    return <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    };
  }

  Future<void> jumpToQueue(int index) async {
    if (index < 0 || index >= _queueSongIds.length) {
      return;
    }
    final bool shouldBootstrapPlayback =
        _shouldBootstrapPlaybackForQueueNavigation();
    final bool shouldResumePlayback = _isPlaying || shouldBootstrapPlayback;
    final LibrarySong? targetSong = songById(_queueSongIds[index]);
    if (shouldResumePlayback) {
      _beginPlaybackActivation(targetSong, resetMetrics: true);
    }
    _debugPlayback(
      'jumpToQueue requested index=$index '
      'currentIndex=$_queueIndex '
      'target=${_debugSongLabel(songById(_queueSongIds[index]))}',
    );
    _primePendingTrackTransition(index);
    if (index > _queueIndex &&
        await _tryPromoteStandbyPreload(
          index,
          shouldResumePlayback: shouldResumePlayback,
        )) {
      return;
    }
    await _interruptCurrentPlayback();
    if (await _tryHandleOfflineTargetTransition(
      index,
      bootstrapPlayback: shouldResumePlayback,
    )) {
      return;
    }
    await _reopenQueueAtIndex(index, forcePlay: shouldResumePlayback);
  }

  Future<bool> removeFromQueue(
    int index, {
    String? debugReason,
    String? expectedRemovedId,
    bool treatAsCurrent = false,
  }) async {
    if (expectedRemovedId != null) {
      final int correctedIndex = _queueIndexForSong(
        expectedRemovedId,
        preferCurrent: true,
        referenceSong: songById(expectedRemovedId),
      );
      if (correctedIndex >= 0) {
        index = correctedIndex;
      }
    }
    if (index < 0 || index >= _queueSongIds.length) {
      return false;
    }
    if (expectedRemovedId != null) {
      final String queuedSongId = _queueSongIds[index];
      final bool exactMatch = queuedSongId == expectedRemovedId;
      final LibrarySong? queuedSong = songById(queuedSongId);
      final LibrarySong? expectedSong = songById(expectedRemovedId);
      final bool identityMatch =
          queuedSong != null &&
          expectedSong != null &&
          _songIdentityKey(queuedSong) == _songIdentityKey(expectedSong);
      if (!exactMatch && !identityMatch) {
        if (debugReason != null) {
          _debugPlayback(
            'dislike.transition missing-song '
            'reason=$debugReason songId=$expectedRemovedId '
            'queueIndex=$_queueIndex queueLen=${_queueSongIds.length}',
          );
        }
        return false;
      }
    }
    if (index < 0 || index >= _queueSongIds.length) {
      return false;
    }
    final String removedId = _queueSongIds[index];
    final bool wasPlaying = _isPlaying;
    final bool removedCurrent = treatAsCurrent || index == _queueIndex;
    final bool lockQueueNavigation = removedCurrent;
    final int updatedQueueIndex;
    if (_queueSongIds.length <= 1) {
      updatedQueueIndex = 0;
    } else if (removedCurrent) {
      updatedQueueIndex = math.min(index, _queueSongIds.length - 2);
    } else if (index < _queueIndex) {
      updatedQueueIndex = _queueIndex - 1;
    } else {
      // Removing a later song must not move the current playback cursor.
      updatedQueueIndex = _queueIndex;
    }

    if (lockQueueNavigation) {
      if (debugReason != null && _queueNavigationInFlight) {
        _debugPlayback(
          'dislike.transition override-navigation '
          'reason=$debugReason index=$index queueIndex=$_queueIndex '
          'removedId=$removedId',
        );
      }
      _queueNavigationInFlight = true;
    }
    try {
      if (debugReason != null) {
        _debugPlayback(
          'dislike.transition remove-start '
          'reason=$debugReason index=$index removedId=$removedId '
          'currentIndex=$_queueIndex nextQueueIndex=$updatedQueueIndex '
          'queueLen=${_queueSongIds.length} detached=$_offlineDetachedQueueMode '
          'playing=$_isPlaying',
        );
      }

      _queueSongIds = List<String>.from(_queueSongIds)..removeAt(index);
      _detachedSequentialQueueSongIds = List<String>.from(
        _detachedSequentialQueueSongIds,
      )..remove(removedId);
      _smartQueueSongIds.remove(removedId);
      _normalizeQueueStateAfterRemoval(
        removedIndex: index,
        removedSongId: removedId,
      );
      if (_queueSongIds.isEmpty) {
        _queueIndex = 0;
        if (debugReason != null) {
          _debugPlayback(
            'dislike.transition queue-empty '
            'reason=$debugReason removedId=$removedId',
          );
        }
        await _player.stop();
      } else {
        _queueIndex = updatedQueueIndex.clamp(0, _queueSongIds.length - 1);
        notifyListeners();
        if (!removedCurrent) {
          if (!_offlineDetachedQueueMode) {
            final List<String> playerQueueSongIds = _playerQueueSongIds;
            if (index >= 0 && index < playerQueueSongIds.length) {
              try {
                await _player.remove(index);
              } on RangeError {
                _debugPlayback(
                  'queue.remove player index out of range '
                  'index=$index playerLen=${playerQueueSongIds.length} '
                  'queueLen=${_queueSongIds.length}',
                );
              }
            }
          }
        } else {
          final int targetIndex = _queueIndex;
          final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
          if (debugReason != null) {
            _debugPlayback(
              'dislike.transition reopen-start '
              'reason=$debugReason queueIndex=$targetIndex '
              'target=${_debugSongLabel(targetSong)}',
            );
          }
          if (wasPlaying) {
            _beginPlaybackActivation(targetSong, resetMetrics: true);
          }
          _primePendingTrackTransition(targetIndex);
          await _interruptCurrentPlayback();
          await _reopenQueueAtIndex(targetIndex, forcePlay: wasPlaying);
          if (debugReason != null) {
            _debugPlayback(
              'dislike.transition reopen-complete '
              'reason=$debugReason queueIndex=$targetIndex '
              'current=${_debugSongLabel(currentSong)}',
            );
          }
        }
      }
      _scheduleSmartQueueWindowRefill();
      _invalidateStandbyPreloads();
      if (debugReason != null) {
        _debugPlayback(
          'dislike.transition complete '
          'reason=$debugReason removedId=$removedId queueIndex=$_queueIndex '
          'queueLen=${_queueSongIds.length} visibleIndex=$visibleQueueIndex '
          'current=${_debugSongLabel(currentSong)}',
        );
      }
      notifyListeners();
    } finally {
      if (lockQueueNavigation) {
        _queueNavigationInFlight = false;
      }
    }
    return true;
  }

  Future<void> reorderQueue(int from, int to) async {
    if (from < 0 ||
        to < 0 ||
        from >= _queueSongIds.length ||
        to >= _queueSongIds.length ||
        from == to) {
      return;
    }

    await _player.move(from, to);

    final String movedId = _queueSongIds.removeAt(from);
    _queueSongIds.insert(to, movedId);
    final int sequentialFrom = _detachedSequentialQueueSongIds.indexOf(movedId);
    if (sequentialFrom >= 0) {
      _detachedSequentialQueueSongIds.removeAt(sequentialFrom);
      final int sequentialTo = to.clamp(
        0,
        _detachedSequentialQueueSongIds.length,
      );
      _detachedSequentialQueueSongIds.insert(sequentialTo, movedId);
    }

    if (_queueIndex == from) {
      _queueIndex = to;
    } else if (from < _queueIndex && to >= _queueIndex) {
      _queueIndex -= 1;
    } else if (from > _queueIndex && to <= _queueIndex) {
      _queueIndex += 1;
    }

    _invalidateStandbyPreloads();
    notifyListeners();
  }

  Future<void> togglePlayback() async {
    registerUserActivity(reason: 'toggle-playback', notify: false);
    if (_queueSongIds.isEmpty || currentSong == null) {
      await _resumeMiniPlayerPlaybackFallback();
      return;
    }
    if (_isPlaying) {
      await pause();
      return;
    }
    await play();
  }

  Future<void> play() async {
    registerUserActivity(reason: 'play', notify: false);
    _pauseRequestedByUser = false;
    if (_isPlaying) {
      return;
    }
    if (_queueSongIds.isEmpty || currentSong == null) {
      if (await _resumeMiniPlayerPlaybackFallback()) {
        return;
      }
    }
    _syncControllerQueueIndexToPlayer();
    final LibrarySong? activeSong = currentSong;
    if (_playerHasLoadedCurrentSong(activeSong)) {
      try {
        await _player.play();
        if (activeSong != null && _lastTrackedSongId != activeSong.id) {
          _trackPlayback(activeSong.id);
        }
        unawaited(_refreshOfflinePlaybackCache(anchor: activeSong));
        return;
      } catch (error) {
        _debugPlayback(
          'player.play resume failed song=${_debugSongLabel(activeSong)} '
          'error=$error',
        );
      }
    }
    _beginPlaybackActivation(activeSong);
    if (activeSong != null &&
        !_playerQueueHasControllerPlaylist() &&
        _songHasImmediatePlaybackSource(activeSong)) {
      final bool shouldPreferDetachedPlayback = _queueSongIds.length <= 1;
      await _reopenQueueAtIndex(
        _queueIndex,
        forcePlay: true,
        preferDetached: shouldPreferDetachedPlayback,
      );
      return;
    }
    if (activeSong != null &&
        _queueSongNeedsQueueRefresh(activeSong, _queueIndex)) {
      await _reopenQueueAtIndex(_queueIndex);
      await _player.play();
      return;
    }
    if (!_playerQueueMatchesControllerState()) {
      await _reopenQueueAtIndex(_queueIndex);
    }
    await _player.play();
    unawaited(_refreshOfflinePlaybackCache(anchor: activeSong));
  }

  Future<void> pause() async {
    registerUserActivity(reason: 'pause', notify: false);
    if (!_isPlaying) {
      return;
    }
    _pauseRequestedByUser = true;
    _clearPlaybackActivation();
    await _player.pause();
  }

  Future<void> nextTrack({bool forcePlay = false}) async {
    if (!forcePlay) {
      registerUserActivity(reason: 'next-track', notify: false);
    }
    if (_queueNavigationInFlight) {
      _debugPlayback('nextTrack ignored while queue navigation is in flight');
      return;
    }
    if (_isShuffleEnabled && !_offlineDetachedQueueMode) {
      await _player.next();
      return;
    }
    _queueNavigationInFlight = true;
    try {
      _syncControllerQueueIndexToPlayer();
      final int? targetIndex = _nextQueueIndex(respectSingleRepeat: false);
      if (targetIndex == null) {
        return;
      }
      final bool shouldBootstrapPlayback =
          forcePlay || _shouldBootstrapPlaybackForQueueNavigation();
      final bool shouldResumePlayback = _isPlaying || shouldBootstrapPlayback;
      final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
      if (shouldResumePlayback) {
        _beginPlaybackActivation(targetSong, resetMetrics: true);
      }
      _debugPlayback(
        'nextTrack requested currentIndex=$_queueIndex targetIndex=$targetIndex '
        'forcePlay=$forcePlay '
        'current=${_debugSongLabel(currentSong)} '
        'target=${_debugSongLabel(songById(_queueSongIds[targetIndex]))}',
      );
      _primePendingTrackTransition(targetIndex);
      if (await _tryPromoteStandbyPreload(
        targetIndex,
        shouldResumePlayback: shouldResumePlayback,
      )) {
        return;
      }
      await _interruptCurrentPlayback();
      if (await _tryHandleOfflineTargetTransition(
        targetIndex,
        bootstrapPlayback: shouldResumePlayback,
      )) {
        return;
      }
      await _reopenQueueAtIndex(targetIndex, forcePlay: shouldResumePlayback);
    } finally {
      _queueNavigationInFlight = false;
    }
  }

  Future<void> previousTrack() async {
    registerUserActivity(reason: 'previous-track', notify: false);
    if (_queueNavigationInFlight) {
      _debugPlayback(
        'previousTrack ignored while queue navigation is in flight',
      );
      return;
    }
    if (_isShuffleEnabled && !_offlineDetachedQueueMode) {
      await _player.previous();
      return;
    }
    _queueNavigationInFlight = true;
    try {
      _syncControllerQueueIndexToPlayer();
      final int? targetIndex = _previousQueueIndex(respectSingleRepeat: false);
      if (targetIndex == null) {
        return;
      }
      final bool shouldBootstrapPlayback =
          _shouldBootstrapPlaybackForQueueNavigation();
      final bool shouldResumePlayback = _isPlaying || shouldBootstrapPlayback;
      final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
      if (shouldResumePlayback) {
        _beginPlaybackActivation(targetSong, resetMetrics: true);
      }
      _debugPlayback(
        'previousTrack requested currentIndex=$_queueIndex targetIndex=$targetIndex '
        'current=${_debugSongLabel(currentSong)} '
        'target=${_debugSongLabel(songById(_queueSongIds[targetIndex]))}',
      );
      _primePendingTrackTransition(targetIndex);
      await _interruptCurrentPlayback();
      if (await _tryHandleOfflineTargetTransition(
        targetIndex,
        bootstrapPlayback: shouldResumePlayback,
      )) {
        return;
      }
      await _reopenQueueAtIndex(targetIndex, forcePlay: shouldResumePlayback);
    } finally {
      _queueNavigationInFlight = false;
    }
  }

  Future<void> seek(Duration target) async {
    registerUserActivity(reason: 'seek', notify: false);
    await _player.seek(target);
  }

  Future<void> toggleShuffle() async {
    if (_offlineDetachedQueueMode) {
      _toggleDetachedQueueShuffle();
      notifyListeners();
      return;
    }
    await _player.setShuffle(!_isShuffleEnabled);
  }

  Future<void> cycleRepeatMode() async {
    final PlaylistMode next = switch (_repeatMode) {
      PlaylistMode.none => PlaylistMode.single,
      PlaylistMode.loop => PlaylistMode.single,
      PlaylistMode.single => PlaylistMode.none,
    };
    await _player.setPlaylistMode(next);
  }

  Future<void> setDenseLibrary(bool value) async {
    _settings = _settings.copyWith(denseLibrary: value);
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> setGridView(bool value) async {
    _settings = _settings.copyWith(useGridView: value);
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> setPlaybackRate(double value) async {
    _settings = _settings.copyWith(playbackRate: value);
    await _player.setRate(value);
    _invalidateStandbyPreloads();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> setSmartQueueEnabled(bool value) async {
    _settings = _settings.copyWith(smartQueueEnabled: value);
    await _saveSnapshot();
    if (value) {
      unawaited(_maybeExtendSmartQueue());
    }
    notifyListeners();
  }

  Future<void> setPreloadNextSongCount(int value) async {
    final int normalized = value.clamp(0, 3);
    if (_settings.preloadNextSongCount == normalized) {
      return;
    }
    _settings = _settings.copyWith(preloadNextSongCount: normalized);
    _bumpSettingsStateRevision();
    _invalidateStandbyPreloads();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> setOfflinePlaybackCacheEnabled(bool value) async {
    return;
  }

  Future<void> setOfflineMusicMode(bool value) async {
    if (_settings.offlineMusicMode == value) {
      return;
    }
    _settings = _settings.copyWith(offlineMusicMode: value);
    if (value) {
      _onlineResults = <LibrarySong>[];
      _onlineError = 'Offline Music mode is on.';
      _trendingNowSongs = <LibrarySong>[];
      _trendingNowError = 'Offline Music mode is on.';
      _homeFeed = <HomeFeedSection>[];
      _personalizedHomeRecommendations = <SongRecommendation>[];
      _homeError = 'Offline Music mode is on.';
      _bumpHomeStateRevision();
    }
    _bumpSettingsStateRevision();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> setNextChanceSongCount(int value) async {
    final int normalized = value.clamp(0, 5);
    if (_settings.nextChanceSongCount == normalized) {
      return;
    }
    _settings = _settings.copyWith(nextChanceSongCount: normalized);
    await _saveSnapshot();
    if (normalized > 0) {
      unawaited(_maybeExtendSmartQueue(force: true));
    }
    unawaited(_refreshOfflinePlaybackCache(anchor: currentSong));
    notifyListeners();
  }

  Future<void> clearOfflinePlaybackCacheAndNotify() async {
    await _deleteLegacyOfflinePlaybackCacheDirectory();
  }

  Future<void> resetDataUsageStats() async {
    _songPlaybackBytes.clear();
    _dataUsage = const AppDataUsageStats();
    _syncDataUsageState();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<Directory> _offlinePlaybackCacheDirectory() async {
    final Directory root = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      p.join(root.path, 'offline_playback_cache'),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _deleteLegacyOfflinePlaybackCacheDirectory() async {
    final Directory root = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      p.join(root.path, 'offline_playback_cache'),
    );
    if (!await dir.exists()) {
      return;
    }
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup for removed download/cache support.
    }
  }

  Future<void> _ensureSequentialPlayback() async {
    if (!_isShuffleEnabled || !_offlineDetachedQueueMode) {
      return;
    }
    _debugPlayback('forcing sequential queue playback by disabling shuffle');
    await _player.setShuffle(false);
  }

  Future<void> _syncPlayerPlaybackModes(Player player) async {
    await player.setPlaylistMode(_repeatMode);
    if (_offlineDetachedQueueMode) {
      if (_isShuffleEnabled) {
        await player.setShuffle(false);
      }
      return;
    }
    await player.setShuffle(_isShuffleEnabled);
  }

  void _toggleDetachedQueueShuffle() {
    if (_queueSongIds.length <= 1) {
      _isShuffleEnabled = false;
      _statusMessage = null;
      _syncPlaybackNotifiers();
      return;
    }

    final String currentSongId =
        currentSong?.id ??
        (_queueIndex >= 0 && _queueIndex < _queueSongIds.length
            ? _queueSongIds[_queueIndex]
            : _queueSongIds.first);

    if (_isShuffleEnabled) {
      if (_detachedSequentialQueueSongIds.isNotEmpty) {
        _queueSongIds = List<String>.from(_detachedSequentialQueueSongIds);
      }
      _queueIndex = _queueSongIds
          .indexOf(currentSongId)
          .clamp(0, _queueSongIds.length - 1);
      _isShuffleEnabled = false;
      _statusMessage = null;
      _invalidateStandbyPreloads();
      _syncPlaybackNotifiers();
      return;
    }

    _detachedSequentialQueueSongIds = List<String>.from(_queueSongIds);
    final List<String> remaining =
        _queueSongIds
            .where((String songId) => songId != currentSongId)
            .toList(growable: true)
          ..shuffle(math.Random());
    _queueSongIds = <String>[currentSongId, ...remaining];
    _queueIndex = 0;
    _isShuffleEnabled = true;
    _statusMessage = null;
    _invalidateStandbyPreloads();
    _syncPlaybackNotifiers();
  }

  String _normalizedContainerExtension(String? containerName) {
    final String normalized = (containerName ?? '').trim().toLowerCase();
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.startsWith('.')) {
      return normalized;
    }
    return '.$normalized';
  }

  String _playbackProxyUrlFileName(LibrarySong song, PlaybackStreamInfo? info) {
    final String safeId = song.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final String extension = _normalizedContainerExtension(info?.containerName);
    return extension.isEmpty ? safeId : '$safeId$extension';
  }

  String? _playbackProxyContentType(PlaybackStreamInfo? info) {
    final String container = (info?.containerName ?? '').trim().toLowerCase();
    final String codec = (info?.codecDescription ?? '').trim().toLowerCase();
    if (container == 'webm') {
      return info?.transport.hasVideo == true ? 'video/webm' : 'audio/webm';
    }
    if (container == 'mp4' || container == 'm4a') {
      if (codec.startsWith('audio/') || (info?.transport.hasVideo == false)) {
        return 'audio/mp4';
      }
      return 'video/mp4';
    }
    return null;
  }

  String _offlinePlaybackCacheFileName(
    LibrarySong song,
    String resolvedUrl, {
    PlaybackStreamInfo? streamInfo,
  }) {
    final Uri? uri = Uri.tryParse(resolvedUrl);
    final String extensionFromUrl = p.extension(uri?.path ?? '').trim();
    final String extension = extensionFromUrl.isNotEmpty
        ? extensionFromUrl
        : _normalizedContainerExtension(streamInfo?.containerName).isNotEmpty
        ? _normalizedContainerExtension(streamInfo?.containerName)
        : '.bin';
    final String safeId = song.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '$safeId$extension';
  }

  Future<File> _offlinePlaybackCacheTargetFile(
    LibrarySong song,
    String resolvedUrl, {
    PlaybackStreamInfo? streamInfo,
  }) async {
    final Directory dir = await _offlinePlaybackCacheDirectory();
    final String fileName = _offlinePlaybackCacheFileName(
      song,
      resolvedUrl,
      streamInfo: streamInfo,
    );
    return File(p.join(dir.path, fileName));
  }

  Future<void> _deleteFileIfExists(String path) async {
    final File file = File(path);
    if (!await file.exists()) {
      return;
    }
    // Handle file locks by retrying with delays
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        await file.delete();
        return;
      } on FileSystemException {
        // File is locked, wait and retry
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        } else {
          // Last attempt - try to delete .part file if exists
          final String partPath = '$path.part';
          try {
            final File partFile = File(partPath);
            if (await partFile.exists()) {
              await partFile.delete();
            }
          } catch (_) {}
          rethrow;
        }
      }
    }
  }

  Future<void> _refreshOfflinePlaybackCache({LibrarySong? anchor}) async {
    return;
  }

  Future<void> _reopenQueueAtIndex(
    int index, {
    bool forcePlay = false,
    bool preferDetached = false,
  }) async {
    if (index < 0 || index >= _queueSongIds.length) {
      return;
    }
    final List<LibrarySong> queue = queueSongs;
    if (queue.isEmpty || index >= queue.length) {
      return;
    }
    _primePendingTrackTransition(index);
    final bool actionOffline =
        offlineMusicMode || await _resolveOfflineStateForAction();
    final bool requiresDetachedSequentialQueue =
        !actionOffline && _queueRequiresDetachedSequentialPlayback(queue);
    final bool openDetachedQueue =
        preferDetached ||
        _offlineDetachedQueueMode ||
        actionOffline ||
        requiresDetachedSequentialQueue;
    final List<LibrarySong> preparedQueue = List<LibrarySong>.from(queue);
    final List<int> preparationIndexes = <int>[index];
    for (final int queueIndex in preparationIndexes) {
      final LibrarySong song = queue[queueIndex];
      if (queueIndex != index && !_queueSongNeedsPreparedMediaSource(song)) {
        continue;
      }
      preparedQueue[queueIndex] = await _preparePlayableSong(song);
    }
    final LibrarySong target = preparedQueue[index];
    try {
      final bool shouldResume = forcePlay || _isPlaying;
      if (shouldResume) {
        _beginPlaybackActivation(target, notify: false);
      }
      _debugPlayback(
        'queue.reopen start index=$index '
        'target=${_debugSongLabel(target)} '
        'shouldResume=$shouldResume '
        'forcePlay=$forcePlay '
        'currentIndex=$_queueIndex '
        'playerIndex=${_player.state.playlist.index} '
        'detached=$openDetachedQueue',
      );
      final List<String> preparedQueueSongIds = preparedQueue
          .map((LibrarySong song) => song.id)
          .toList();
      if (!openDetachedQueue) {
        _offlineDetachedQueueMode = false;
        _primeOfflineQueueActivation(
          targetSongId: target.id,
          targetIndex: index,
          queueSongIds: preparedQueueSongIds,
        );
        // Validate new queue doesn't skip songs accidentally
        // Only update queue if indices make sense
        if (_queueSongIds.isEmpty ||
            index == 0 ||
            index <= _queueIndex + 1 ||
            preparedQueueSongIds.length > _queueSongIds.length) {
          _queueSongIds = preparedQueueSongIds;
        }
      } else {
        _offlineDetachedQueueMode = true;
      }
      _queueIndex = index;
      notifyListeners();
      await _ensureSequentialPlayback();
      // Opening media can make Android buffer the whole current song even
      // before play() is called. Wrap the active target whenever it is opened;
      // queue entries are still left untouched until they become the target.
      await _enableProxyCachingForSong(target);
      if (openDetachedQueue) {
        await _player.open(
          Playlist(<Media>[_mediaForSong(target)]),
          play: false,
        );
      } else {
        await _player.open(
          Playlist(preparedQueue.map(_mediaForSong).toList(), index: index),
          play: false,
        );
      }
      await _syncPlayerPlaybackModes(_player);
      if (shouldResume) {
        await _player.play();
      }
      _clearOfflineQueueActivationState();
      _resolveTrackTransition(preparedQueue[index]);
      _trackPlayback(preparedQueue[index].id);
      _scheduleSmartQueueWindowRefill(seed: preparedQueue[index]);
      unawaited(_refreshOfflinePlaybackCache(anchor: preparedQueue[index]));
      _invalidateStandbyPreloads();
      _debugPlayback(
        'queue.reopen complete index=$index '
        'target=${_debugSongLabel(preparedQueue[index])}',
      );
      notifyListeners();
    } catch (_) {
      _debugPlayback('queue.reopen failed index=$index');
      _clearOfflineQueueActivationState();
      _offlineDetachedQueueMode = false;
      _clearTrackTransition();
      rethrow;
    }
  }

  bool _queueSongNeedsPreparedMediaSource(LibrarySong song) {
    if (!songNeedsResolvedPlaybackUrl(song)) {
      return false;
    }
    if (_offlinePlaybackCachePathForSong(song.id) != null) {
      return false;
    }
    final String? prepared = _preparedMediaUrlsBySongId[song.id];
    return prepared == null || prepared.isEmpty || prepared == song.path;
  }

  Future<bool> _tryHandleOfflineTargetTransition(
    int targetIndex, {
    bool bootstrapPlayback = false,
  }) async {
    final bool offline = await _resolveOfflineStateForAction();
    if (!offlineMusicMode && !offline) {
      return false;
    }
    if (targetIndex < 0 || targetIndex >= _queueSongIds.length) {
      return false;
    }
    final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
    if (targetSong == null) {
      return false;
    }
    final bool canOpenNow =
        !targetSong.isRemote ||
        _offlinePlaybackCachePathForSong(targetSong.id) != null;
    if (canOpenNow) {
      await _reopenQueueAtIndex(targetIndex, forcePlay: bootstrapPlayback);
      return true;
    }
    await _enterOfflineQueueWait(
      targetIndex,
      shouldResume: bootstrapPlayback || _isPlaying,
    );
    return true;
  }

  bool _shouldBootstrapPlaybackForQueueNavigation() {
    return !_isPlaying &&
        _queueSongIds.isNotEmpty &&
        currentSong != null &&
        _player.state.playlist.medias.isEmpty;
  }

  void _primePendingTrackTransition(int targetIndex) {
    final LibrarySong? pending = songById(_queueSongIds[targetIndex]);
    if (pending == null) {
      return;
    }
    _clearOfflineQueueWait(notify: false);
    _transitioningSongId = pending.id;
    _transitioningQueueIndex = targetIndex;
    _pendingSelectionSong = pending;
    _position = Duration.zero;
    _duration = Duration.zero;
    _debugPlayback(
      'transition.prime index=$targetIndex song=${_debugSongLabel(pending)} '
      'queueIndex=$_queueIndex',
    );
    notifyListeners();
  }

  bool _shouldHoldTransitionMetrics() {
    if (_offlineQueueActivationTargetSongId != null) {
      return true;
    }
    if (_offlineQueueWaitingSongId != null) {
      return true;
    }
    final String? transitioningSongId = _transitioningSongId;
    if (transitioningSongId == null) {
      return false;
    }
    final LibrarySong? active = currentSong;
    return active == null || active.id != transitioningSongId;
  }

  void _resolveTrackTransition(LibrarySong? song) {
    if (song == null) {
      return;
    }
    if (_offlineQueueWaitingSongId == song.id) {
      _clearOfflineQueueWait(notify: false);
    }
    if (_transitioningSongId == song.id) {
      _transitioningSongId = null;
      _transitioningQueueIndex = null;
    }
    _offlineQueueAdvancePending = false;
    final LibrarySong? pending = _pendingSelectionSong;
    if (pending == null || pending.id == song.id) {
      _pendingSelectionSong = null;
    }
    _debugPlayback(
      'transition.resolve song=${_debugSongLabel(song)} '
      'pending=${_debugSongLabel(_pendingSelectionSong)} '
      'transitionSong=$_transitioningSongId '
      'transitionIndex=$_transitioningQueueIndex '
      'queueIndex=$_queueIndex',
    );
  }

  void _clearTrackTransition() {
    _transitioningSongId = null;
    _transitioningQueueIndex = null;
    _pendingSelectionSong = null;
    _debugPlayback('transition.clear queueIndex=$_queueIndex');
    notifyListeners();
  }

  Future<void> _enterOfflineQueueWait(
    int targetIndex, {
    bool shouldResume = false,
  }) async {
    if (targetIndex < 0 || targetIndex >= _queueSongIds.length) {
      return;
    }
    final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
    if (targetSong == null) {
      return;
    }
    _offlineQueueWaitingSongId = targetSong.id;
    _offlineQueueWaitingIndex = targetIndex;
    _offlineQueueWaitingShouldResume = shouldResume;
    _queueIndex = targetIndex;
    _transitioningSongId = targetSong.id;
    _transitioningQueueIndex = targetIndex;
    _pendingSelectionSong = targetSong;
    _position = Duration.zero;
    _duration = Duration.zero;
    _statusMessage = 'Waiting for internet to continue queue';
    _clearPlaybackActivation();
    _debugPlayback(
      'offline.wait enter '
      'targetIndex=$targetIndex song=${_debugSongLabel(targetSong)} '
      'shouldResume=$shouldResume',
    );
    try {
      await _player.pause();
    } catch (_) {}
    notifyListeners();
  }

  void _clearOfflineQueueWait({bool notify = true}) {
    if (_offlineQueueWaitingSongId == null &&
        _offlineQueueWaitingIndex == null) {
      return;
    }
    _offlineQueueWaitingSongId = null;
    _offlineQueueWaitingIndex = null;
    _offlineQueueWaitingShouldResume = false;
    _statusMessage = null;
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _resumeOfflineWaitingQueue() async {
    final int? targetIndex = _offlineQueueWaitingIndex;
    final bool shouldResume = _offlineQueueWaitingShouldResume;
    final bool offline = await _resolveOfflineStateForAction();
    if (targetIndex == null || offline || offlineMusicMode) {
      return;
    }
    if (targetIndex < 0 || targetIndex >= _queueSongIds.length) {
      _clearOfflineQueueWait();
      return;
    }
    final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
    _debugPlayback(
      'offline.wait resume '
      'targetIndex=$targetIndex target=${_debugSongLabel(targetSong)} '
      'shouldResume=$shouldResume',
    );
    await _reopenQueueAtIndex(targetIndex, forcePlay: shouldResume);
  }

  void _primeOfflineQueueActivation({
    required String targetSongId,
    required int targetIndex,
    required List<String> queueSongIds,
  }) {
    _offlineQueueActivationTargetSongId = targetSongId;
    _offlineQueueActivationTargetIndex = targetIndex;
    _offlineQueueActivationSongIds = List<String>.from(queueSongIds);
    _transitioningSongId = targetSongId;
    _transitioningQueueIndex = targetIndex;
    _pendingSelectionSong = songById(targetSongId) ?? _pendingSelectionSong;
    _debugPlayback(
      'offline.activation prime target=$targetSongId '
      'targetIndex=$targetIndex queueLen=${queueSongIds.length}',
    );
  }

  void _clearOfflineQueueActivationState() {
    _offlineQueueActivationTargetSongId = null;
    _offlineQueueActivationTargetIndex = null;
    _offlineQueueActivationSongIds = null;
  }

  LibrarySong? _preferredPlaybackRecoverySong() {
    final String? transitioningSongId = _transitioningSongId;
    if (transitioningSongId != null) {
      final LibrarySong? transitioningSong = songById(transitioningSongId);
      if (transitioningSong != null) {
        return transitioningSong;
      }
    }
    final LibrarySong? pending = _pendingSelectionSong;
    if (pending != null) {
      return pending;
    }
    return currentSong;
  }

  bool _shouldIgnorePlaylistEventForPendingSelection(
    List<String> nextQueueSongIds,
    int nextQueueIndex,
  ) {
    final String? expectedSongId =
        _transitioningSongId ??
        _pendingSelectionSong?.id ??
        _playbackActivationSongId;
    if (expectedSongId == null || nextQueueSongIds.isEmpty) {
      return false;
    }
    final String activeSongId = nextQueueSongIds[nextQueueIndex];
    if (activeSongId == expectedSongId) {
      return false;
    }
    final int expectedIndex =
        _transitioningQueueIndex ?? _queueSongIds.indexOf(expectedSongId);
    final bool containsExpectedSong = nextQueueSongIds.contains(expectedSongId);
    final bool expectedSongAtExpectedIndex =
        expectedIndex >= 0 &&
        expectedIndex < nextQueueSongIds.length &&
        nextQueueSongIds[expectedIndex] == expectedSongId &&
        nextQueueIndex == expectedIndex;
    final bool ignore = containsExpectedSong || expectedSongAtExpectedIndex;
    if (ignore) {
      _debugPlayback(
        'player.playlist ignored stale selection event '
        'active=$activeSongId '
        'expected=$expectedSongId '
        'nextIndex=$nextQueueIndex '
        'expectedIndex=$expectedIndex '
        'queueLen=${nextQueueSongIds.length} '
        'revision=$_playbackSelectionRevision',
      );
    }
    return ignore;
  }

  void _debugPlayback(String message) {
    if (!_shouldEmitPlaybackDebug(message)) {
      return;
    }
    AppLogger.info('Controller', '[PlaybackDebug] $message');
  }

  bool _shouldEmitPlaybackDebug(String message) {
    return message.startsWith('dislike.transition') ||
        message.startsWith('queue.prune removed') ||
        message.startsWith('queue.prune sync') ||
        message.startsWith('queue.reopen') ||
        message.startsWith('player.playlist') ||
        message.startsWith('player.interrupt requested') ||
        message.startsWith('queue.autoAdvance');
  }

  void _debugLog(String message) {
    AppLogger.trace('Controller', message);
  }

  String _debugSongLabel(LibrarySong? song) {
    if (song == null) {
      return 'null';
    }
    return '${song.id}("${song.title}" by "${song.artist}")';
  }

  String _debugQueueSnapshot({
    List<String>? songIds,
    int? activeIndex,
    int maxItems = 8,
  }) {
    final List<String> ids = songIds ?? _queueSongIds;
    if (ids.isEmpty) {
      return '[]';
    }
    final int highlightedIndex = activeIndex ?? _queueIndex;
    final Iterable<String> entries = ids
        .take(maxItems)
        .toList()
        .asMap()
        .entries
        .map((MapEntry<int, String> entry) {
          final int index = entry.key;
          final String songId = entry.value;
          final LibrarySong? song = songById(songId);
          final String marker = index == highlightedIndex ? '*' : '';
          final String label = song == null
              ? songId
              : '${song.title} / ${song.artist} / ${song.id}';
          return '$marker$index:$label';
        });
    final String suffix = ids.length > maxItems
        ? ' ... (+${ids.length - maxItems})'
        : '';
    return '[${entries.join(' | ')}$suffix]';
  }

  int? _queueProgressIndex() {
    if (_queueSongIds.isEmpty) {
      return null;
    }
    if (_offlineDetachedQueueMode ||
        _offlineQueueWaitingSongId != null ||
        !_playerQueueHasControllerPlaylist()) {
      if (_queueIndex < 0 || _queueIndex >= _queueSongIds.length) {
        return null;
      }
      return _queueIndex;
    }
    // Synchronize with player state, but validate it matches our queue
    final int? playerIndex = _activePlayerQueueIndex();
    if (playerIndex != null &&
        playerIndex >= 0 &&
        playerIndex < _queueSongIds.length &&
        playerIndex == _queueIndex) {
      return playerIndex;
    }
    // If player index is ahead, ensure it's intentional
    if (playerIndex != null && playerIndex > _queueIndex && _isPlaying) {
      // Player has advanced, but only return it if we're in a stable state
      if (_transitioningSongId == null &&
          _offlineQueueWaitingSongId == null &&
          _playbackFallbackRecoverySongId == null) {
        return playerIndex;
      }
    }
    return _queueIndex;
  }

  int? _nextQueueIndex({bool respectSingleRepeat = true}) {
    if (_queueSongIds.isEmpty) {
      return null;
    }
    final int? currentIndex = _queueProgressIndex();
    if (currentIndex == null) {
      return null;
    }
    if (respectSingleRepeat && _repeatMode == PlaylistMode.single) {
      return currentIndex;
    }
    if (currentIndex < _queueSongIds.length - 1) {
      return currentIndex + 1;
    }
    if (_repeatMode == PlaylistMode.loop) {
      return 0;
    }
    return null;
  }

  int? _previousQueueIndex({bool respectSingleRepeat = true}) {
    if (_queueSongIds.isEmpty) {
      return null;
    }
    final int? currentIndex = _queueProgressIndex();
    if (currentIndex == null) {
      return null;
    }
    if (respectSingleRepeat && _repeatMode == PlaylistMode.single) {
      return currentIndex;
    }
    if (currentIndex > 0) {
      return currentIndex - 1;
    }
    if (_repeatMode == PlaylistMode.loop) {
      return _queueSongIds.length - 1;
    }
    return null;
  }

  Future<void> updateYtMusicAuth(String rawInput) async {
    final String trimmed = rawInput.trim();
    final String? normalized = trimmed.isEmpty
        ? null
        : await _normalizeYtMusicAuth(trimmed);

    _settings = _settings.copyWith(ytMusicAuthJson: normalized ?? '');
    await _saveSnapshot();
    await _recreateYtMusicClient();
    notifyListeners();
  }

  Future<void> clearYtMusicAuth() async {
    _settings = _settings.copyWith(ytMusicAuthJson: '');
    await _saveSnapshot();
    await _recreateYtMusicClient();
    notifyListeners();
  }

  Future<UserPlaylist> createPlaylist(String name) async {
    final String trimmed = name.trim();
    final String playlistName = trimmed.isEmpty ? 'Untitled Playlist' : trimmed;
    final DateTime now = DateTime.now();
    final UserPlaylist playlist = UserPlaylist(
      id: _uuid.v4(),
      name: playlistName,
      songIds: <String>[],
      createdAt: now,
      updatedAt: now,
    );
    _playlists = <UserPlaylist>[playlist, ..._playlists];
    _markLibraryDataDirty('playlist created');
    await _saveSnapshot();
    notifyListeners();
    unawaited(_syncPlaylistToCloud(playlist));
    return playlist;
  }

  Future<void> deletePlaylist(String playlistId) async {
    _cloudPlaylistSongLoadFutures.remove(playlistId);
    _playlists = _playlists
        .where((UserPlaylist playlist) => playlist.id != playlistId)
        .toList();
    _markLibraryDataDirty('playlist deleted');
    await _saveSnapshot();
    notifyListeners();
    await _deletePlaylistFromCloud(playlistId);
  }

  Future<UserPlaylist?> removePlaylistLocally(String playlistId) async {
    final int playlistIndex = _playlists.indexWhere(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (playlistIndex < 0) {
      return null;
    }
    final UserPlaylist removed = _playlists[playlistIndex];
    _cloudPlaylistSongLoadFutures.remove(playlistId);
    _playlists = List<UserPlaylist>.from(_playlists)..removeAt(playlistIndex);
    _markLibraryDataDirty('playlist deleted');
    await _saveSnapshot();
    notifyListeners();
    return removed;
  }

  Future<void> restorePlaylist(UserPlaylist playlist, {int? index}) async {
    final int insertionIndex = (index ?? 0).clamp(0, _playlists.length);
    _playlists = List<UserPlaylist>.from(_playlists)
      ..removeWhere((UserPlaylist item) => item.id == playlist.id)
      ..insert(insertionIndex, playlist);
    _playlists.sort(_sortUserPlaylists);
    _markLibraryDataDirty('playlist restored');
    await _saveSnapshot();
    notifyListeners();
    unawaited(_syncPlaylistToCloud(playlist));
  }

  Future<void> finalizeDeletedPlaylist(String playlistId) async {
    await _deletePlaylistFromCloud(playlistId);
  }

  Future<void> renamePlaylist(String playlistId, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final UserPlaylist? basePlaylist = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    _playlists =
        _playlists
            .map(
              (UserPlaylist playlist) => playlist.id == playlistId
                  ? playlist.copyWith(name: trimmed, updatedAt: DateTime.now())
                  : playlist,
            )
            .toList()
          ..sort(_sortUserPlaylists);
    _markLibraryDataDirty('playlist renamed');
    await _saveSnapshot();
    notifyListeners();
    final UserPlaylist? updated = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (updated != null) {
      unawaited(_syncPlaylistToCloud(updated, basePlaylist: basePlaylist));
    }
  }

  Future<void> addSongToPlaylist(String playlistId, String songId) async {
    UserPlaylist? current = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (current != null && !current.songIdsComplete) {
      await loadPlaylistSongsFromCloud(playlistId);
      final UserPlaylist? loaded = _playlists.firstWhereOrNull(
        (UserPlaylist playlist) => playlist.id == playlistId,
      );
      if (loaded == null || !loaded.songIdsComplete) {
        _queueCloudSyncMessage(
          'Could not load this playlist before editing. Please try again when cloud sync is available.',
        );
        notifyListeners();
        return;
      }
      current = loaded;
    }
    _playlists = _playlists.map((UserPlaylist playlist) {
      if (playlist.id != playlistId || playlist.songIds.contains(songId)) {
        return playlist;
      }
      return playlist.copyWith(
        songIds: <String>[...playlist.songIds, songId],
        songCount: playlist.songIds.length + 1,
        songIdsComplete: true,
        updatedAt: DateTime.now(),
      );
    }).toList()..sort(_sortUserPlaylists);
    _markLibraryDataDirty('playlist song added');
    await _saveSnapshot();
    notifyListeners();
    final UserPlaylist? updated = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (updated != null) {
      unawaited(_syncPlaylistToCloud(updated, basePlaylist: current));
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    UserPlaylist? current = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (current != null && !current.songIdsComplete) {
      await loadPlaylistSongsFromCloud(playlistId);
      final UserPlaylist? loaded = _playlists.firstWhereOrNull(
        (UserPlaylist playlist) => playlist.id == playlistId,
      );
      if (loaded == null || !loaded.songIdsComplete) {
        _queueCloudSyncMessage(
          'Could not load this playlist before editing. Please try again when cloud sync is available.',
        );
        notifyListeners();
        return;
      }
      current = loaded;
    }
    _playlists = _playlists.map((UserPlaylist playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      final List<String> nextSongIds = playlist.songIds
          .where((String id) => id != songId)
          .toList();
      return playlist.copyWith(
        songIds: nextSongIds,
        songCount: nextSongIds.length,
        songIdsComplete: true,
        updatedAt: DateTime.now(),
      );
    }).toList()..sort(_sortUserPlaylists);
    _markLibraryDataDirty('playlist song removed');
    await _saveSnapshot();
    notifyListeners();
    final UserPlaylist? updated = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (updated != null) {
      unawaited(_syncPlaylistToCloud(updated, basePlaylist: current));
    }
  }

  Future<int?> removeDownloadedSong(LibrarySong song) async {
    final int downloadIndex = _downloadedSongs.indexWhere(
      (LibrarySong item) => item.id == song.id,
    );
    if (downloadIndex < 0) {
      return null;
    }
    _downloadedSongs = List<LibrarySong>.from(_downloadedSongs)
      ..removeAt(downloadIndex);
    _markLibraryDataDirty('download removed');
    await _saveSnapshot();
    notifyListeners();
    return downloadIndex;
  }

  Future<void> restoreDownloadedSong(LibrarySong song, {int? index}) async {
    final int insertionIndex = (index ?? _downloadedSongs.length).clamp(
      0,
      _downloadedSongs.length,
    );
    _downloadedSongs = List<LibrarySong>.from(_downloadedSongs)
      ..removeWhere((LibrarySong item) => item.id == song.id)
      ..insert(insertionIndex, song);
    _markLibraryDataDirty('download restored');
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> finalizeRemovedDownloadedSong(LibrarySong song) async {
    final bool stillTracked = _downloadedSongs.any(
      (LibrarySong item) => item.id == song.id,
    );
    if (stillTracked) {
      return;
    }
    final File file = File(song.path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<int?> removeSongFromPlaylistAt(
    String playlistId,
    int songIndex,
  ) async {
    UserPlaylist? current = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (current != null && !current.songIdsComplete) {
      await loadPlaylistSongsFromCloud(playlistId);
      final UserPlaylist? loaded = _playlists.firstWhereOrNull(
        (UserPlaylist playlist) => playlist.id == playlistId,
      );
      if (loaded == null || !loaded.songIdsComplete) {
        _queueCloudSyncMessage(
          'Could not load this playlist before editing. Please try again when cloud sync is available.',
        );
        notifyListeners();
        return null;
      }
      current = loaded;
    }

    final UserPlaylist? latest = current;
    if (latest == null || songIndex < 0 || songIndex >= latest.songIds.length) {
      return null;
    }

    final List<String> nextSongIds = List<String>.from(latest.songIds)
      ..removeAt(songIndex);
    _playlists = _playlists.map((UserPlaylist playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      return playlist.copyWith(
        songIds: nextSongIds,
        songCount: nextSongIds.length,
        songIdsComplete: true,
        updatedAt: DateTime.now(),
      );
    }).toList()..sort(_sortUserPlaylists);
    _markLibraryDataDirty('playlist song removed');
    await _saveSnapshot();
    notifyListeners();
    return songIndex;
  }

  Future<void> finalizeRemovedSongFromPlaylist(
    String playlistId,
    String songId,
  ) async {
    final UserPlaylist? updated = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (updated == null || updated.songIds.contains(songId)) {
      return;
    }
    await _syncPlaylistToCloud(updated);
  }

  Future<void> insertSongIntoPlaylistAt(
    String playlistId,
    String songId, {
    int? index,
  }) async {
    UserPlaylist? current = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (current != null && !current.songIdsComplete) {
      await loadPlaylistSongsFromCloud(playlistId);
      current = _playlists.firstWhereOrNull(
        (UserPlaylist playlist) => playlist.id == playlistId,
      );
    }

    final UserPlaylist? latest = current;
    if (latest == null) {
      return;
    }

    final int insertionIndex = (index ?? latest.songIds.length).clamp(
      0,
      latest.songIds.length,
    );
    final List<String> nextSongIds = List<String>.from(latest.songIds)
      ..insert(insertionIndex, songId);
    _playlists = _playlists.map((UserPlaylist playlist) {
      if (playlist.id != playlistId) {
        return playlist;
      }
      return playlist.copyWith(
        songIds: nextSongIds,
        songCount: nextSongIds.length,
        songIdsComplete: true,
        updatedAt: DateTime.now(),
      );
    }).toList()..sort(_sortUserPlaylists);
    _markLibraryDataDirty('playlist song restored');
    await _saveSnapshot();
    notifyListeners();
    final UserPlaylist? updated = _playlists.firstWhereOrNull(
      (UserPlaylist playlist) => playlist.id == playlistId,
    );
    if (updated != null) {
      unawaited(_syncPlaylistToCloud(updated, basePlaylist: current));
    }
  }

  Future<void> toggleFavorite(String songId) async {
    _songs = _songs
        .map(
          (LibrarySong song) => song.id == songId
              ? song.copyWith(isFavorite: !song.isFavorite)
              : song,
        )
        .toList();
    await _saveSnapshot();
    notifyListeners();
  }

  Future<void> likeSong(String songId) async {
    registerUserActivity(reason: 'like-song', notify: false);
    final LibrarySong? base = songById(songId);
    if (base == null) {
      return;
    }
    final bool newLiked = !base.isLiked;
    const bool newDisliked = false;
    _songs = _songs
        .map(
          (LibrarySong song) => song.id == songId
              ? song.copyWith(isLiked: newLiked, isDisliked: newDisliked)
              : song,
        )
        .toList();
    final LibrarySong? transient = _transientSongsById[songId];
    if (transient != null) {
      _transientSongsById[songId] = transient.copyWith(
        isLiked: newLiked,
        isDisliked: newDisliked,
      );
    }
    _markLibraryDataDirty('song liked state updated');
    _applyOptimisticCloudSongPreference(
      songId: songId,
      isLiked: newLiked,
      isDisliked: newDisliked,
    );
    await _saveSnapshot();
    notifyListeners();
    _scheduleCloudPreferenceProfileSync();
    await _syncLikedSongToCloud(songId: songId, isLiked: newLiked);
  }

  Future<void> dislikeSong(String songId) async {
    registerUserActivity(reason: 'dislike-song', notify: false);
    final LibrarySong? base = songById(songId);
    if (base == null) {
      return;
    }
    final List<String?> activeSongCandidates = <String?>[
      _activePlaybackSongId,
      miniPlayerSong?.id,
      currentSong?.id,
    ];
    final bool wasActiveSong = activeSongCandidates.contains(songId);
    final String? activeSongId =
        activeSongCandidates.firstWhereOrNull((String? id) => id == songId) ??
        activeSongCandidates.firstWhereOrNull((String? id) => id != null);
    final int initialQueuedIndex = _queueIndexForSong(
      songId,
      preferCurrent: true,
      referenceSong: base,
    );
    final bool wasQueued = initialQueuedIndex >= 0;
    final bool newDisliked = !base.isDisliked;
    const bool newLiked = false;
    _songs = _songs
        .map(
          (LibrarySong song) => song.id == songId
              ? song.copyWith(isDisliked: newDisliked, isLiked: newLiked)
              : song,
        )
        .toList();
    final LibrarySong? transient = _transientSongsById[songId];
    if (transient != null) {
      _transientSongsById[songId] = transient.copyWith(
        isDisliked: newDisliked,
        isLiked: newLiked,
      );
    }
    if (newDisliked) {
      final String dislikedKey = _songIdentityKey(base);
      _homeFeed = _filterHomeFeedSectionsForBrowsing(_homeFeed)
          .map(
            (HomeFeedSection section) => HomeFeedSection(
              title: section.title,
              subtitle: section.subtitle,
              query: section.query,
              songs: section.songs
                  .where(
                    (LibrarySong song) => _songIdentityKey(song) != dislikedKey,
                  )
                  .toList(growable: false),
            ),
          )
          .where((HomeFeedSection section) => section.songs.isNotEmpty)
          .toList(growable: false);
      _trendingNowSongs = _trendingNowSongs
          .where((LibrarySong song) => _songIdentityKey(song) != dislikedKey)
          .toList(growable: false);
      _personalizedHomeRecommendations = _personalizedHomeRecommendations
          .where(
            (SongRecommendation item) =>
                _songIdentityKey(item.song) != dislikedKey,
          )
          .toList(growable: false);
    }
    _markLibraryDataDirty('song disliked state updated');
    _applyOptimisticCloudSongPreference(
      songId: songId,
      isLiked: newLiked,
      isDisliked: newDisliked,
      pruneQueue: false,
    );
    bool queueChangeHandled = false;
    if (newDisliked) {
      if (wasQueued) {
        if (wasActiveSong) {
          _debugPlayback(
            'dislike.transition start '
            'song=${_debugSongLabel(songById(songId) ?? base)} '
            'queueIndex=$_queueIndex queueLen=${_queueSongIds.length} '
            'activeSongId=$activeSongId queuedIndex=$initialQueuedIndex '
            'queue=${_debugQueueSnapshot(songIds: _queueSongIds, activeIndex: _queueIndex)}',
          );
          await _transitionAfterDislikingActiveQueuedSong(
            songId: songId,
            queuedIndex: initialQueuedIndex,
          );
          queueChangeHandled = true;
        } else {
          _pruneRestrictedSongsFromQueue();
        }
      } else if (wasActiveSong) {
        await _skipDislikedActiveSong(songId);
        queueChangeHandled = true;
      }
    }
    await _saveSnapshot();
    if (!queueChangeHandled) {
      notifyListeners();
    }
    _scheduleCloudPreferenceProfileSync();
    await _syncDislikedSongToCloud(songId: songId, isDisliked: newDisliked);
  }

  Future<void> _transitionAfterDislikingActiveQueuedSong({
    required String songId,
    required int queuedIndex,
  }) async {
    final bool shouldBootstrapPlayback =
        _shouldBootstrapPlaybackForQueueNavigation();
    final bool shouldResumePlayback = _isPlaying || shouldBootstrapPlayback;
    _queueNavigationInFlight = true;
    try {
      final bool pruned = _pruneRestrictedSongsFromQueue(
        syncPlayer: false,
        preferredContinuationIndex: queuedIndex >= 0 ? queuedIndex : null,
      );
      if (!pruned) {
        if (!_queueSongIds.contains(songId) && _queueSongIds.isNotEmpty) {
          final int targetIndex = _queueIndex.clamp(
            0,
            _queueSongIds.length - 1,
          );
          final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
          _debugPlayback(
            'dislike.transition already-pruned reopen '
            'songId=$songId targetIndex=$targetIndex '
            'target=${_debugSongLabel(targetSong)} '
            'queue=${_debugQueueSnapshot(songIds: _queueSongIds, activeIndex: targetIndex)}',
          );
          if (shouldResumePlayback) {
            _beginPlaybackActivation(targetSong, resetMetrics: true);
          }
          _primePendingTrackTransition(targetIndex);
          await _interruptCurrentPlayback();
          await _reopenQueueAtIndex(
            targetIndex,
            forcePlay: shouldResumePlayback,
          );
          return;
        }
        await _skipDislikedActiveSong(songId);
        return;
      }
      if (_queueSongIds.isEmpty) {
        _debugPlayback(
          'dislike.transition pruned active song and queue is now empty '
          'songId=$songId',
        );
        await _player.stop();
        notifyListeners();
        return;
      }
      final int targetIndex = _queueIndex.clamp(0, _queueSongIds.length - 1);
      final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
      _debugPlayback(
        'dislike.transition pruned-active reopen '
        'songId=$songId targetIndex=$targetIndex '
        'target=${_debugSongLabel(targetSong)} '
        'queue=${_debugQueueSnapshot(songIds: _queueSongIds, activeIndex: targetIndex)}',
      );
      if (shouldResumePlayback) {
        _beginPlaybackActivation(targetSong, resetMetrics: true);
      }
      _primePendingTrackTransition(targetIndex);
      await _interruptCurrentPlayback();
      if (await _tryHandleOfflineTargetTransition(
        targetIndex,
        bootstrapPlayback: shouldResumePlayback,
      )) {
        return;
      }
      await _reopenQueueAtIndex(targetIndex, forcePlay: shouldResumePlayback);
    } finally {
      _queueNavigationInFlight = false;
    }
  }

  Future<void> _skipDislikedActiveSong(String songId) async {
    final int? targetIndex = _nextQueueIndex(respectSingleRepeat: false);
    if (targetIndex == null) {
      _pruneRestrictedSongsFromQueue(syncPlayer: false);
      await _player.stop();
      notifyListeners();
      return;
    }

    final bool shouldBootstrapPlayback =
        _shouldBootstrapPlaybackForQueueNavigation();
    final bool shouldResumePlayback = _isPlaying || shouldBootstrapPlayback;
    final LibrarySong? targetSong = songById(_queueSongIds[targetIndex]);
    _queueNavigationInFlight = true;
    try {
      if (shouldResumePlayback) {
        _beginPlaybackActivation(targetSong, resetMetrics: true);
      }
      _primePendingTrackTransition(targetIndex);
      await _interruptCurrentPlayback();
      if (await _tryHandleOfflineTargetTransition(
        targetIndex,
        bootstrapPlayback: shouldResumePlayback,
      )) {
        _pruneRestrictedSongsFromQueue(syncPlayer: false);
        return;
      }
      await _reopenQueueAtIndex(targetIndex, forcePlay: shouldResumePlayback);
      _pruneRestrictedSongsFromQueue(syncPlayer: false);
    } finally {
      _queueNavigationInFlight = false;
    }
  }

  int _queueIndexForSong(
    String songId, {
    bool preferCurrent = false,
    LibrarySong? referenceSong,
  }) {
    final LibrarySong? resolvedReferenceSong =
        referenceSong ?? songById(songId);
    final String? identityKey = resolvedReferenceSong == null
        ? null
        : _songIdentityKey(resolvedReferenceSong);
    int indexForIdentity(List<String> songIds) {
      if (identityKey == null) {
        return -1;
      }
      for (int index = 0; index < songIds.length; index += 1) {
        final LibrarySong? song = songById(songIds[index]);
        if (song != null && _songIdentityKey(song) == identityKey) {
          return index;
        }
      }
      return -1;
    }

    bool matchesSongAtIndex(int index, List<String> songIds) {
      if (index < 0 || index >= songIds.length) {
        return false;
      }
      final String queuedSongId = songIds[index];
      if (queuedSongId == songId) {
        return true;
      }
      if (identityKey == null) {
        return false;
      }
      final LibrarySong? queuedSong = songById(queuedSongId);
      return queuedSong != null && _songIdentityKey(queuedSong) == identityKey;
    }

    if (preferCurrent &&
        _queueIndex >= 0 &&
        _queueIndex < _queueSongIds.length &&
        matchesSongAtIndex(_queueIndex, _queueSongIds)) {
      return _queueIndex;
    }

    final int playbackIndex = _activePlaybackSongId == null
        ? -1
        : _queueSongIds.indexOf(_activePlaybackSongId!);
    if (playbackIndex >= 0 &&
        matchesSongAtIndex(playbackIndex, _queueSongIds)) {
      return playbackIndex;
    }

    final int directIndex = _queueSongIds.indexOf(songId);
    if (directIndex >= 0) {
      return directIndex;
    }

    final int identityIndex = indexForIdentity(_queueSongIds);
    if (identityIndex >= 0) {
      return identityIndex;
    }

    if (_offlineDetachedQueueMode) {
      final int detachedDirectIndex = _detachedSequentialQueueSongIds.indexOf(
        songId,
      );
      if (detachedDirectIndex >= 0) {
        return detachedDirectIndex;
      }
      final int detachedIdentityIndex = indexForIdentity(
        _detachedSequentialQueueSongIds,
      );
      if (detachedIdentityIndex >= 0) {
        return detachedIdentityIndex;
      }
    }

    return -1;
  }

  void _rememberTransientSong(LibrarySong song) {
    if (song.isRemote) {
      final LibrarySong? existing = _transientSongsById[song.id];
      if (existing == null) {
        _transientSongsById[song.id] = _withKnownCloudPreferenceState(song);
        _markLibraryDataDirty('transient song added');
        return;
      }
      _transientSongsById[song.id] = _withKnownCloudPreferenceState(
        song.copyWith(
          playCount: existing.playCount,
          lastPlayedAt: existing.lastPlayedAt,
          isLiked: existing.isLiked,
          isDisliked: existing.isDisliked,
        ),
      );
      _markLibraryDataDirty('transient song refreshed');
    }
  }

  void _trackPlayback(String songId) {
    final DateTime now = DateTime.now();
    _finalizeActivePlaybackSession(nextSongId: songId);
    final LibrarySong? currentSong = songById(songId);
    final bool shouldTrack =
        currentSong != null && _shouldUseSongForHistorySignals(currentSong);
    final int index = _songs.indexWhere(
      (LibrarySong song) => song.id == songId,
    );
    if (shouldTrack && index >= 0) {
      final LibrarySong song = _songs[index];
      _songs[index] = song.copyWith(
        playCount: song.playCount + 1,
        lastPlayedAt: now,
      );
    } else if (shouldTrack) {
      final LibrarySong? transient = _transientSongsById[songId];
      if (transient != null) {
        _transientSongsById[songId] = transient.copyWith(
          playCount: transient.playCount + 1,
          lastPlayedAt: now,
        );
      }
    }

    _activePlaybackSongId = songId;
    _activePlaybackCompletionRatio = 0;
    _lastTrackedSongId = songId;
    _scheduleSnapshotSave();
  }

  void _updateActivePlaybackProgress() {
    final LibrarySong? song = currentSong;
    if (song == null) {
      return;
    }
    _activePlaybackSongId ??= song.id;
    if (_activePlaybackSongId != song.id) {
      _finalizeActivePlaybackSession(nextSongId: song.id);
      _activePlaybackSongId = song.id;
      _activePlaybackCompletionRatio = 0;
    }
    final int durationMs = math.max(song.durationMs, _duration.inMilliseconds);
    if (durationMs <= 0) {
      return;
    }
    final double ratio = _position.inMilliseconds / durationMs;
    if (ratio > _activePlaybackCompletionRatio) {
      _activePlaybackCompletionRatio = ratio.clamp(0, 1);
    }
  }

  String currentStreamSongDataLabel({
    required LibrarySong song,
    required PlaybackStreamInfo info,
    required String fallbackLabel,
  }) {
    final int? bytes = _currentStreamSongDataBytes(song: song, info: info);
    if (bytes != null && bytes > 0) {
      return formatDataSize(bytes);
    }
    return fallbackLabel;
  }

  String currentCacheProgressLabel({
    required LibrarySong song,
    required String fallbackLabel,
  }) {
    final (int bytes, int _) = _currentSongCacheProgress(song.id);
    if (bytes > 0) {
      return formatDataSize(bytes);
    }
    return fallbackLabel;
  }

  (int, int) _currentSongCacheProgress(String songId) {
    final int bytes = _offlinePlaybackCacheProgressBytesBySongId[songId] ?? 0;
    int expected = _offlinePlaybackCacheExpectedBytesBySongId[songId] ?? 0;
    if (expected <= 0) {
      expected = _estimatedSourceSizeBytes(songId) ?? 0;
    }
    final LibrarySong? song = songById(songId);
    final PlaybackStreamInfo? info = _playbackStreamInfoBySongId[songId];
    final int? fullSize = song == null || info == null
        ? null
        : _currentStreamSongDataBytes(song: song, info: info);
    if (fullSize != null && fullSize > 0) {
      if (expected <= 0 || expected < fullSize) {
        expected = fullSize;
      }
      if (info != null &&
          (info.transport == PlaybackStreamTransport.cachedFile ||
              info.transport == PlaybackStreamTransport.localFile)) {
        return (fullSize, fullSize);
      }
    }
    return (bytes.clamp(0, expected > 0 ? expected : bytes), expected);
  }

  void _updateOfflinePlaybackCacheProgress({
    required String songId,
    required int bytesWritten,
    int? expectedBytes,
  }) {
    final int normalizedBytes = math.max(0, bytesWritten);
    final int previousBytes =
        _offlinePlaybackCacheProgressBytesBySongId[songId] ?? 0;
    _offlinePlaybackCacheProgressBytesBySongId[songId] = normalizedBytes;
    final int normalizedExpected = math.max(0, expectedBytes ?? 0);
    if (normalizedExpected > 0) {
      _offlinePlaybackCacheExpectedBytesBySongId[songId] = normalizedExpected;
    } else {
      final int? estimated = _estimatedSourceSizeBytes(songId);
      if (estimated != null && estimated > 0) {
        _offlinePlaybackCacheExpectedBytesBySongId[songId] = estimated;
      }
    }
    final int delta = normalizedBytes - previousBytes;
    if (delta > 0) {
      _recordStreamBytes(songId, delta);
      return;
    }
  }

  int? _estimatedSourceSizeBytes(String songId, {LibrarySong? fallbackSong}) {
    final LibrarySong? song = fallbackSong ?? songById(songId);
    final PlaybackStreamInfo? info = _playbackStreamInfoBySongId[songId];
    if (song == null || info == null) {
      return null;
    }
    return _currentStreamSongDataBytes(song: song, info: info);
  }

  int? _currentStreamSongDataBytes({
    required LibrarySong song,
    required PlaybackStreamInfo info,
  }) {
    if (info.transport == PlaybackStreamTransport.cachedFile) {
      final int? cachedSize = _offlinePlaybackCacheSizesBySongId[song.id];
      if (cachedSize != null && cachedSize > 0) {
        return cachedSize;
      }
      final String? cachedPath = _offlinePlaybackCachePathForSong(song.id);
      if (cachedPath != null) {
        final File cachedFile = File(cachedPath);
        if (cachedFile.existsSync()) {
          final int length = cachedFile.lengthSync();
          _offlinePlaybackCacheSizesBySongId[song.id] = length;
          return length;
        }
      }
    }

    if (info.transport == PlaybackStreamTransport.localFile) {
      final File localFile = File(info.resolvedUrl);
      if (localFile.existsSync()) {
        return localFile.lengthSync();
      }
    }

    final int? bitrate = info.bitrateBitsPerSecond;
    final int durationMs = math.max(
      song.durationMs,
      currentSong?.id == song.id ? _duration.inMilliseconds : 0,
    );
    if (bitrate != null && bitrate > 0 && durationMs > 0) {
      return ((bitrate * durationMs) / 8000).round();
    }
    final int consumedBytes = _songPlaybackBytes[song.id] ?? 0;
    return consumedBytes > 0 ? consumedBytes : null;
  }

  void _finalizeActivePlaybackSession({String? nextSongId}) {
    final String? songId = _activePlaybackSongId;
    if (songId == null || songId == nextSongId) {
      return;
    }
    if (!_offlinePlaybackPrefetchInFlight.contains(songId)) {
      _offlinePlaybackCacheProgressBytesBySongId.remove(songId);
      _offlinePlaybackCacheExpectedBytesBySongId.remove(songId);
    }
    if (!_shouldUseSongIdForHistorySignals(songId)) {
      _activePlaybackSongId = null;
      _activePlaybackCompletionRatio = 0;
      return;
    }
    final DateTime now = DateTime.now();
    final double ratio = _activePlaybackCompletionRatio.clamp(0, 1);
    final bool listenedToEnd = ratio >= 0.88;
    if (listenedToEnd) {
      _completedPlaybackSaveEligibleSongIds.add(songId);
      _disablePlaybackProxyForSong(songId, keepCachingIfActive: true);
      final String? pendingPath = _pendingCompletedPlaybackCachePaths.remove(
        songId,
      );
      if (pendingPath != null) {
        _finalizeCompletedPlaybackCacheSave(
          songId: songId,
          cachedFilePath: pendingPath,
        );
      }
    } else {
      _completedPlaybackSaveEligibleSongIds.remove(songId);
      final String? pendingPath = _pendingCompletedPlaybackCachePaths.remove(
        songId,
      );
      if (pendingPath != null) {
        unawaited(_deleteFileIfExists(pendingPath));
      }
      _disablePlaybackProxyForSong(songId, keepCachingIfActive: false);
    }
    _history = <PlaybackEntry>[
      PlaybackEntry(
        songId: songId,
        playedAt: now,
        completionRatio: ratio,
        listenedToEnd: listenedToEnd,
      ),
      ..._history,
    ].take(300).toList();
    _activePlaybackSongId = null;
    _activePlaybackCompletionRatio = 0;
    _scheduleCloudPreferenceProfileSync();
    _scheduleSnapshotSave();
  }

  void _finalizeCompletedPlaybackCacheSave({
    required String songId,
    required String cachedFilePath,
  }) {
    _pendingCompletedPlaybackCachePaths.remove(songId);
    _completedPlaybackSaveEligibleSongIds.remove(songId);
    _offlinePlaybackCachePaths[songId] = cachedFilePath;
    final File cachedFile = File(cachedFilePath);
    if (cachedFile.existsSync()) {
      _offlinePlaybackCacheSizesBySongId[songId] = cachedFile.lengthSync();
    }
    final int completedSize = _offlinePlaybackCacheSizesBySongId[songId] ?? 0;
    if (completedSize > 0) {
      _offlinePlaybackCacheProgressBytesBySongId[songId] = completedSize;
      _offlinePlaybackCacheExpectedBytesBySongId[songId] = completedSize;
    }
    _preparedMediaUrlsBySongId[songId] = cachedFilePath;
    _preparedMediaHeadersBySongId[songId] = null;
    final LibrarySong? song = songById(songId);
    if (song != null) {
      _playbackStreamInfoBySongId[songId] = buildCachedPlaybackStreamInfo(
        song: song,
        cachedPath: cachedFilePath,
        previousInfo: _playbackStreamInfoBySongId[songId],
      );
      _updateOfflinePlaybackCacheProgress(
        songId: songId,
        bytesWritten: completedSize,
        expectedBytes: completedSize,
      );
    }
    _completeOfflinePlaybackCacheWaiters(songId, true);
    unawaited(_saveSnapshot());
    notifyListeners();
  }

  Future<void> _loadSnapshot() async {
    final File file = await _snapshotFile();
    if (!await file.exists()) {
      _snapshotLoaded = false;
      _markLibraryDataDirty('snapshot missing');
      return;
    }

    late final Map<String, dynamic> json;
    try {
      final String raw = await file.readAsString();
      final Map<String, dynamic>? decoded = await decodeSnapshotJson(raw);
      if (decoded == null) {
        await file.delete();
        _snapshotLoaded = false;
        _markLibraryDataDirty('snapshot invalid and removed');
        return;
      }
      json = decoded;
    } on FormatException catch (error) {
      _debugLog('Snapshot load skipped due to invalid JSON: $error');
      await file.delete();
      _snapshotLoaded = false;
      _markLibraryDataDirty('snapshot parse failed');
      return;
    }

    _settings = AppSettings.fromJson(json['settings'] as Map<String, dynamic>?);
    _sources = (json['sources'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic item) => item as String)
        .toList();
    _songs = (json['songs'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic item) => LibrarySong.fromJson(item as Map<String, dynamic>),
        )
        .map(_withoutPersistedLikedState)
        .toList();
    _downloadedSongs =
        (json['downloadedSongs'] as List<dynamic>? ?? <dynamic>[])
            .map(
              (dynamic item) =>
                  LibrarySong.fromJson(item as Map<String, dynamic>),
            )
            .where(
              (LibrarySong song) =>
                  song.isDownloaded && File(song.path).existsSync(),
            )
            .toList();
    _playlists = (json['playlists'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic item) => UserPlaylist.fromJson(item as Map<String, dynamic>),
        )
        .toList();
    final List<LibrarySong> transientSongs =
        (json['transientSongs'] as List<dynamic>? ?? <dynamic>[])
            .map(
              (dynamic item) =>
                  LibrarySong.fromJson(item as Map<String, dynamic>),
            )
            .map(_withoutPersistedLikedState)
            .where((LibrarySong song) => song.isRemote)
            .toList();
    _transientSongsById
      ..clear()
      ..addEntries(
        transientSongs.map(
          (LibrarySong song) => MapEntry<String, LibrarySong>(song.id, song),
        ),
      );
    _history = (json['history'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic item) =>
              PlaybackEntry.fromJson(item as Map<String, dynamic>),
        )
        .toList();
    _prunePlaybackHistory();
    _searchDraft = json['searchDraft'] as String? ?? '';
    _recentSearchTerms =
        (json['recentSearchTerms'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic item) => item as String)
            .where((String item) => item.trim().isNotEmpty)
            .take(8)
            .toList(growable: false);
    _offlinePlaybackCachePaths.clear();
    _offlinePlaybackCacheSizesBySongId.clear();
    final List<String> restoredQueueSongIds =
        (json['queueSongIds'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic item) => item as String)
            .where((String songId) {
              final LibrarySong? song = songById(songId);
              return song != null && shouldShowSongOutsideSearch(song);
            })
            .toList(growable: false);
    _queueSongIds = restoredQueueSongIds;
    _detachedSequentialQueueSongIds = List<String>.from(restoredQueueSongIds);
    final int restoredQueueIndex = (json['queueIndex'] as num?)?.toInt() ?? 0;
    _queueIndex = restoredQueueSongIds.isEmpty
        ? 0
        : restoredQueueIndex.clamp(0, restoredQueueSongIds.length - 1);
    final String restoredQueueLabel =
        json['queueLabel'] as String? ?? 'Now Playing';
    _queueLabel = restoredQueueLabel.trim().isEmpty
        ? 'Now Playing'
        : restoredQueueLabel;
    final String cachedCloudUserId = (json['cloudUserId'] as String? ?? '')
        .trim();
    _activeCloudUserId = cachedCloudUserId.isEmpty ? null : cachedCloudUserId;
    _cloudLibraryRevision = DateTime.tryParse(
      json['cloudLibraryRevision'] as String? ?? '',
    );
    _cloudUserDataLoaded = _activeCloudUserId != null;
    _cloudPreferenceProfile = CloudPreferenceProfile.fromMap(
      json['cloudPreferenceProfile'] as Map<String, dynamic>? ??
          const <String, dynamic>{},
    );
    if (!_restoreCloudPreferenceIdsFromSnapshot(json)) {
      _restoreCloudPreferenceStateFromSnapshot(ignoreLikedSongs: true);
    } else {
      _applyCloudPreferenceStateToCollections(<String>{
        ..._cloudLikedSongIds,
        ..._cloudDislikedSongIds,
      }, syncQueue: false);
    }
    _pruneTransientPreferenceOnlySongs();
    _pruneRestrictedSongsFromQueue(syncPlayer: false);
    _rebuildTopArtistsCache();
    _dataUsage = const AppDataUsageStats();
    dataUsageState.value = _dataUsage;
    _snapshotLoaded = true;
    _markLibraryDataDirty('snapshot loaded');
  }

  Future<void> _saveSnapshot() async {
    final File file = await _snapshotFile();
    await file.parent.create(recursive: true);
    final List<LibrarySong> transientSongs =
        _transientSongsById.values
            .where(
              (LibrarySong song) =>
                  song.isRemote &&
                  (song.playCount > 0 ||
                      song.lastPlayedAt != null ||
                      _queueSongIds.contains(song.id)),
            )
            .toList()
          ..sort((LibrarySong a, LibrarySong b) {
            final DateTime left = a.lastPlayedAt ?? a.addedAt;
            final DateTime right = b.lastPlayedAt ?? b.addedAt;
            return right.compareTo(left);
          });
    final String raw = await encodeSnapshotJson(<String, dynamic>{
      'settings': _settings.toJson(),
      'sources': _sources,
      'songs': _songs
          .map(_withoutPersistedLikedState)
          .map((LibrarySong song) => song.toJson())
          .toList(),
      'downloadedSongs': _downloadedSongs
          .where((LibrarySong song) => File(song.path).existsSync())
          .map((LibrarySong song) => song.toJson())
          .toList(),
      'transientSongs': transientSongs
          .take(200)
          .map(_withoutPersistedLikedState)
          .map((LibrarySong song) => song.toJson())
          .toList(),
      'playlists': _playlists
          .map((UserPlaylist playlist) => playlist.toJson())
          .toList(),
      'history': _history
          .where((PlaybackEntry entry) => songById(entry.songId) != null)
          .map((PlaybackEntry entry) => entry.toJson())
          .toList(),
      'queueSongIds': _queueSongIds
          .where((String songId) => songById(songId) != null)
          .toList(growable: false),
      'queueIndex': _queueIndex,
      'queueLabel': _queueLabel,
      'searchDraft': _searchDraft,
      'recentSearchTerms': _recentSearchTerms,
      'cloudUserId': _activeCloudUserId,
      'cloudLibraryRevision': _cloudLibraryRevision?.toIso8601String(),
      'cloudPreferenceProfile': _cloudPreferenceProfile.toMap(),
      'cloudDislikedSongIds': _cloudDislikedSongIds.toList(growable: false),
    });
    await file.writeAsString(raw);
  }

  void _pruneTransientPreferenceOnlySongs() {
    final Set<String> historySongIds = _history
        .map((PlaybackEntry entry) => entry.songId)
        .toSet();
    _transientSongsById.removeWhere((String songId, LibrarySong song) {
      if (!song.isRemote) {
        return false;
      }
      if (song.playCount > 0 || song.lastPlayedAt != null) {
        return false;
      }
      if (_queueSongIds.contains(songId) || historySongIds.contains(songId)) {
        return false;
      }
      return song.isLiked || song.isDisliked;
    });
  }

  bool _restoreCloudPreferenceIdsFromSnapshot(Map<String, dynamic> json) {
    final List<dynamic>? disliked =
        json['cloudDislikedSongIds'] as List<dynamic>?;
    if (disliked == null) {
      return false;
    }
    _cloudLikedSongIds.clear();
    _cloudDislikedSongIds
      ..clear()
      ..addAll(
        disliked
            .map((dynamic item) => item.toString().trim())
            .where((String id) => id.isNotEmpty),
      );
    _cloudLikedSongIds.removeAll(_cloudDislikedSongIds);
    return true;
  }

  void _restoreCloudPreferenceStateFromSnapshot({
    bool ignoreLikedSongs = false,
  }) {
    _cloudLikedSongIds.clear();
    if (!ignoreLikedSongs) {
      _cloudLikedSongIds.addAll(
        _songs
            .where((LibrarySong song) => song.isLiked && !song.isDisliked)
            .map((LibrarySong song) => song.id),
      );
      _cloudLikedSongIds.addAll(
        _transientSongsById.values
            .where((LibrarySong song) => song.isLiked && !song.isDisliked)
            .map((LibrarySong song) => song.id),
      );
    }
    _cloudDislikedSongIds
      ..clear()
      ..addAll(
        _songs
            .where((LibrarySong song) => song.isDisliked)
            .map((LibrarySong song) => song.id),
      )
      ..addAll(
        _transientSongsById.values
            .where((LibrarySong song) => song.isDisliked)
            .map((LibrarySong song) => song.id),
      );
  }

  LibrarySong _withoutPersistedLikedState(LibrarySong song) {
    if (!song.isLiked) {
      return song;
    }
    return song.copyWith(isLiked: false);
  }

  Future<File> _snapshotFile() async {
    final Directory root = await getApplicationSupportDirectory();
    return File(p.join(root.path, 'musix_flutter_state.json'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      clearSearchState();
      _finalizeActivePlaybackSession();
      unawaited(_saveSnapshot());
    }
  }

  @override
  void dispose() {
    if (_isDisposed || _isDisposing) {
      return;
    }
    _isDisposing = true;
    _standbyPreloadRevision += 1;
    _finalizeActivePlaybackSession();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveSnapshot());
    _cancelPlayerListeners();
    _dataUsageSnapshotTimer?.cancel();
    _dataUsageSnapshotTimer = null;
    _playbackActivationTimer?.cancel();
    _playbackActivationTimer = null;
    _cloudPreferenceProfileSyncTimer?.cancel();
    _cloudPreferenceProfileSyncTimer = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _standbyPreloadRetryTimer?.cancel();
    _standbyPreloadRetryTimer = null;
    _completeAllOfflinePlaybackCacheWaiters(false);
    unawaited(_cloudUserDataSubscription?.cancel());
    _cloudUserDataSubscription = null;
    unawaited(_notificationActionSubscription?.cancel());
    _notificationActionSubscription = null;
    unawaited(_windowsMediaActionSubscription?.cancel());
    _windowsMediaActionSubscription = null;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
    unawaited(AndroidMediaNotificationBridge.stop());
    unawaited(WindowsMediaControlsBridge.stop());
    _ytMusic?.close();
    _yt.close();
    unawaited(_playbackProxy.dispose());
    unawaited(_disposeStandbyPreloads());
    _isDisposed = true;
    _notifyScheduler.dispose();
    home.dispose();
    library.dispose();
    search.dispose();
    connectivity.dispose();
    appSettings.dispose();
    queue.dispose();
    nowPlayingState.dispose();
    playbackProgressState.dispose();
    dataUsageState.dispose();
    final Player? player = _playerInstance;
    if (player != null) {
      unawaited(player.stop());
      unawaited(player.dispose());
      _playerInstance = null;
    }
    super.dispose();
  }
}

class _FallbackTitle {
  const _FallbackTitle({required this.title, this.artist});

  final String title;
  final String? artist;
}

class _RecommendationQuery {
  const _RecommendationQuery({
    required this.title,
    required this.subtitle,
    required this.query,
    this.anchor,
  });

  final String title;
  final String subtitle;
  final String query;
  final LibrarySong? anchor;
}

class OnlineArtistCollectionPage {
  const OnlineArtistCollectionPage({
    required this.artist,
    required this.hasMore,
  });

  final ArtistCollection artist;
  final bool hasMore;
}

class _TasteSignal {
  const _TasteSignal(this.label, this.score);

  final String label;
  final double score;
}

class _OnlineArtistCollectionSession {
  _OnlineArtistCollectionSession({
    required this.normalizedKey,
    required this.fallbackArtistName,
    required this.resolvedName,
    required this.songsSection,
    required this.albums,
    required this.singles,
  });

  final String normalizedKey;
  final String fallbackArtistName;
  String resolvedName;
  final Map<dynamic, dynamic>? songsSection;
  final _OnlineArtistReleaseState albums;
  final _OnlineArtistReleaseState singles;
  final List<LibrarySong> songs = <LibrarySong>[];
  final Set<String> seenSongKeys = <String>{};
  final Set<String> processedReleaseBrowseIds = <String>{};
  int playlistRequestedLimit = 0;
  bool playlistExhausted = false;
  bool fullyLoaded = false;
}

class _OnlineArtistReleaseState {
  _OnlineArtistReleaseState({required this.browseId, required this.params});

  final String browseId;
  final String params;
  final List<String> pendingBrowseIds = <String>[];
  final Set<String> queuedBrowseIds = <String>{};
  int requestedLimit = 0;
  bool exhausted = false;

  bool get isAvailable => browseId.isNotEmpty && params.isNotEmpty;
}

class _LanguageSignal {
  const _LanguageSignal({
    required this.label,
    required this.queryToken,
    required this.score,
  });

  final String label;
  final String queryToken;
  final double score;
}

class _LanguageDetection {
  const _LanguageDetection(this.code, this.confidence);

  final String code;
  final double confidence;
}

class _ActivePlaybackProxy {
  const _ActivePlaybackProxy({
    required this.sessionId,
    required this.proxyUrl,
    required this.upstreamUrl,
    required this.upstreamHeaders,
  });

  final String sessionId;
  final String proxyUrl;
  final String upstreamUrl;
  final Map<String, String>? upstreamHeaders;
}

class _StandbyPreloadSlot {
  const _StandbyPreloadSlot({
    required this.queueIndex,
    required this.songId,
    required this.player,
  });

  final int queueIndex;
  final String songId;
  final Player player;

  Future<void> dispose() async {
    try {
      await player.stop();
    } catch (_) {}
    await player.dispose();
  }
}

class _SessionContext {
  const _SessionContext({
    required this.label,
    required this.query,
    required this.vibeToken,
  });

  final String label;
  final String query;
  final String vibeToken;
}

class _ScoredSong {
  const _ScoredSong(this.song, this.score);

  final LibrarySong song;
  final double score;
}

class _TasteProfile {
  const _TasteProfile({
    required this.artistKeys,
    required this.genreKeys,
    required this.moodKeys,
    required this.languageKeys,
    required this.yearKeys,
    required this.prefersRecentYears,
    required this.artistScores,
    required this.genreScores,
    required this.moodScores,
    required this.languageScores,
    required this.languageConfidenceScores,
    required this.yearScores,
    required this.avoidedArtistScores,
    required this.avoidedGenreScores,
    required this.avoidedMoodScores,
    required this.avoidedLanguageScores,
    required this.avoidedYearScores,
    required this.recentArtistScores,
    required this.recentGenreScores,
    required this.recentMoodScores,
    required this.recentLanguageScores,
    required this.recentYearScores,
    required this.skipArtistScores,
    required this.skipGenreScores,
    required this.skipMoodScores,
    required this.skipLanguageScores,
    required this.skipYearScores,
    required this.energyScores,
    required this.sessionContextScores,
    required this.sourceWeights,
    required this.noveltyPreference,
    required this.popularityPreference,
    required this.repeatAffinity,
    required this.primaryLanguage,
    required this.secondaryLanguages,
    required this.preferredYearFloor,
  });

  final Set<String> artistKeys;
  final Set<String> genreKeys;
  final Set<String> moodKeys;
  final Set<String> languageKeys;
  final Set<String> yearKeys;
  final bool prefersRecentYears;
  final Map<String, double> artistScores;
  final Map<String, double> genreScores;
  final Map<String, double> moodScores;
  final Map<String, double> languageScores;
  final Map<String, double> languageConfidenceScores;
  final Map<String, double> yearScores;
  final Map<String, double> avoidedArtistScores;
  final Map<String, double> avoidedGenreScores;
  final Map<String, double> avoidedMoodScores;
  final Map<String, double> avoidedLanguageScores;
  final Map<String, double> avoidedYearScores;
  final Map<String, double> recentArtistScores;
  final Map<String, double> recentGenreScores;
  final Map<String, double> recentMoodScores;
  final Map<String, double> recentLanguageScores;
  final Map<String, double> recentYearScores;
  final Map<String, double> skipArtistScores;
  final Map<String, double> skipGenreScores;
  final Map<String, double> skipMoodScores;
  final Map<String, double> skipLanguageScores;
  final Map<String, double> skipYearScores;
  final Map<String, double> energyScores;
  final Map<String, double> sessionContextScores;
  final Map<String, double> sourceWeights;
  final double noveltyPreference;
  final double popularityPreference;
  final double repeatAffinity;
  final String primaryLanguage;
  final Set<String> secondaryLanguages;
  final int? preferredYearFloor;

  double artistAffinity(String key) => artistScores[key] ?? 0;

  double genreAffinity(String key) => genreScores[key] ?? 0;

  double moodAffinity(String key) => moodScores[key] ?? 0;

  double languageAffinity(String key) => languageScores[key] ?? 0;

  double yearAffinity(int? year) {
    if (year == null || year <= 0) {
      return 0;
    }
    final double direct = yearScores['$year'] ?? 0;
    if (direct > 0) {
      return direct;
    }
    double best = 0;
    for (final MapEntry<String, double> entry in yearScores.entries) {
      final int? preferredYear = int.tryParse(entry.key);
      if (preferredYear == null) {
        continue;
      }
      final int delta = (preferredYear - year).abs();
      if (delta > 10) {
        continue;
      }
      final double closeness = (1 - (delta / 10)).clamp(0, 1);
      best = math.max(best, entry.value * closeness);
    }
    return best;
  }

  double artistAvoidance(String key) => avoidedArtistScores[key] ?? 0;

  double genreAvoidance(String key) => avoidedGenreScores[key] ?? 0;

  double moodAvoidance(String key) => avoidedMoodScores[key] ?? 0;

  double languageAvoidance(String key) => avoidedLanguageScores[key] ?? 0;

  double yearAvoidance(int? year) {
    if (year == null || year <= 0) {
      return 0;
    }
    return avoidedYearScores['$year'] ?? 0;
  }

  double recentArtistAffinity(String key) => recentArtistScores[key] ?? 0;

  double recentGenreAffinity(String key) => recentGenreScores[key] ?? 0;

  double recentMoodAffinity(String key) => recentMoodScores[key] ?? 0;

  double recentLanguageAffinity(String key) => recentLanguageScores[key] ?? 0;

  double recentYearAffinity(int? year) {
    if (year == null || year <= 0) {
      return 0;
    }
    return recentYearScores['$year'] ?? 0;
  }

  double skipArtistPenalty(String key) => skipArtistScores[key] ?? 0;

  double skipGenrePenalty(String key) => skipGenreScores[key] ?? 0;

  double skipMoodPenalty(String key) => skipMoodScores[key] ?? 0;

  double skipLanguagePenalty(String key) => skipLanguageScores[key] ?? 0;

  double skipYearPenalty(int? year) {
    if (year == null || year <= 0) {
      return 0;
    }
    return skipYearScores['$year'] ?? 0;
  }

  double energyAffinity(String key) => energyScores[key] ?? 0;

  double sessionContextAffinity(String key) => sessionContextScores[key] ?? 0;

  double sourceWeight(String key, {double fallback = 1}) =>
      sourceWeights[key] ?? fallback;

  double preferredYearWindowBoost(int? year) {
    if (year == null || year <= 0) {
      return 0;
    }
    final int? floor = preferredYearFloor;
    if (floor == null) {
      return 0;
    }
    if (year < floor) {
      final int gap = floor - year;
      return gap >= 12 ? -8.5 : -(gap * 0.8);
    }
    return 3.4;
  }
}

class _ScoredRecommendation {
  const _ScoredRecommendation({
    required this.song,
    required this.score,
    required this.reason,
    required this.isExploratory,
  });

  final LibrarySong song;
  final double score;
  final String reason;
  final bool isExploratory;
}

class _ResolvedRemotePlayback {
  const _ResolvedRemotePlayback({
    required this.resolvedUrl,
    required this.streamInfo,
    this.upstreamHeaders,
    this.youtubeStreamInfo,
  });

  final String resolvedUrl;
  final PlaybackStreamInfo streamInfo;
  final Map<String, String>? upstreamHeaders;
  final StreamInfo? youtubeStreamInfo;
}

class _ResolvedDownloadPayload {
  const _ResolvedDownloadPayload({
    required this.audioPath,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.durationMs,
    this.artworkPath,
  });

  final String audioPath;
  final String? artworkPath;
  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final int durationMs;
}
