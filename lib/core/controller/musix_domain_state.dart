import 'package:flutter/foundation.dart';

/// Narrow listenable for home feed UI — avoids rebuilding on unrelated controller changes.
class MusixHomeState extends ChangeNotifier {
  int revision = 0;
  bool loading = false;
  bool refreshResolvedOnce = false;
  bool offlineViewActive = false;
  String? error;

  void publish({
    required int revision,
    required bool loading,
    required bool refreshResolvedOnce,
    required bool offlineViewActive,
    required String? error,
  }) {
    final bool changed =
        this.revision != revision ||
        this.loading != loading ||
        this.refreshResolvedOnce != refreshResolvedOnce ||
        this.offlineViewActive != offlineViewActive ||
        this.error != error;
    if (!changed) {
      return;
    }
    this.revision = revision;
    this.loading = loading;
    this.refreshResolvedOnce = refreshResolvedOnce;
    this.offlineViewActive = offlineViewActive;
    this.error = error;
    notifyListeners();
  }
}

/// Search tab signals — trending, online results, and browse shelf inputs.
class MusixSearchState extends ChangeNotifier {
  int revision = 0;
  bool offlineViewActive = false;
  bool trendingLoading = false;
  bool onlineLoading = false;
  int libraryRevision = 0;
  int homeRevision = 0;

  void publish({
    required int revision,
    required bool offlineViewActive,
    required bool trendingLoading,
    required bool onlineLoading,
    required int libraryRevision,
    required int homeRevision,
  }) {
    final bool changed =
        this.revision != revision ||
        this.offlineViewActive != offlineViewActive ||
        this.trendingLoading != trendingLoading ||
        this.onlineLoading != onlineLoading ||
        this.libraryRevision != libraryRevision ||
        this.homeRevision != homeRevision;
    if (!changed) {
      return;
    }
    this.revision = revision;
    this.offlineViewActive = offlineViewActive;
    this.trendingLoading = trendingLoading;
    this.onlineLoading = onlineLoading;
    this.libraryRevision = libraryRevision;
    this.homeRevision = homeRevision;
    notifyListeners();
  }
}

/// Library scan / derived-data revision for library tab rebuilds.
class MusixLibraryState extends ChangeNotifier {
  int revision = 0;
  bool scanning = false;
  bool cloudLoading = false;

  void publish({
    required int revision,
    required bool scanning,
    required bool cloudLoading,
  }) {
    final bool changed =
        this.revision != revision ||
        this.scanning != scanning ||
        this.cloudLoading != cloudLoading;
    if (!changed) {
      return;
    }
    this.revision = revision;
    this.scanning = scanning;
    this.cloudLoading = cloudLoading;
    notifyListeners();
  }
}

/// Connectivity and offline-mode signals.
class MusixConnectivityState extends ChangeNotifier {
  bool isOffline = false;
  bool offlineViewActive = false;
  String? connectivityMessage;

  void publish({
    required bool isOffline,
    required bool offlineViewActive,
    required String? connectivityMessage,
  }) {
    final bool changed =
        this.isOffline != isOffline ||
        this.offlineViewActive != offlineViewActive ||
        this.connectivityMessage != connectivityMessage;
    if (!changed) {
      return;
    }
    this.isOffline = isOffline;
    this.offlineViewActive = offlineViewActive;
    this.connectivityMessage = connectivityMessage;
    notifyListeners();
  }
}

/// Settings that appear on the profile screen and related controls.
class MusixAppSettingsState extends ChangeNotifier {
  int revision = 0;
  int preloadNextSongCount = 0;
  String sleepTimerStatusLabel = 'Off';
  String preferredRegionLabel = '';
  bool offlineMusicMode = false;

  void publish({
    required int revision,
    required int preloadNextSongCount,
    required String sleepTimerStatusLabel,
    required String preferredRegionLabel,
    required bool offlineMusicMode,
  }) {
    final bool changed =
        this.revision != revision ||
        this.preloadNextSongCount != preloadNextSongCount ||
        this.sleepTimerStatusLabel != sleepTimerStatusLabel ||
        this.preferredRegionLabel != preferredRegionLabel ||
        this.offlineMusicMode != offlineMusicMode;
    if (!changed) {
      return;
    }
    this.revision = revision;
    this.preloadNextSongCount = preloadNextSongCount;
    this.sleepTimerStatusLabel = sleepTimerStatusLabel;
    this.preferredRegionLabel = preferredRegionLabel;
    this.offlineMusicMode = offlineMusicMode;
    notifyListeners();
  }
}

/// Playback queue chrome (mini player visibility, queue index) for shell widgets.
class MusixQueueState extends ChangeNotifier {
  int revision = 0;
  bool hasMiniPlayer = false;
  int queueLength = 0;
  int visibleQueueIndex = 0;

  void publish({
    required int revision,
    required bool hasMiniPlayer,
    required int queueLength,
    required int visibleQueueIndex,
  }) {
    final bool changed =
        this.revision != revision ||
        this.hasMiniPlayer != hasMiniPlayer ||
        this.queueLength != queueLength ||
        this.visibleQueueIndex != visibleQueueIndex;
    if (!changed) {
      return;
    }
    this.revision = revision;
    this.hasMiniPlayer = hasMiniPlayer;
    this.queueLength = queueLength;
    this.visibleQueueIndex = visibleQueueIndex;
    notifyListeners();
  }
}
