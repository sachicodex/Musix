part of '../../musix_ui.dart';

class _LibraryScreen extends StatefulWidget {
  const _LibraryScreen({
    super.key,
    required this.controller,
    required this.isActive,
    required this.filter,
    required this.onFilterChanged,
  });

  final MusixController controller;
  final bool isActive;
  final LibraryFilter filter;
  final ValueChanged<LibraryFilter> onFilterChanged;

  @override
  State<_LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<_LibraryScreen>
    with AutomaticKeepAliveClientMixin<_LibraryScreen> {
  String? _lastBuildSignature;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: widget.controller.library,
      builder: (BuildContext context, Widget? _) {
        return _buildLibraryContent(context);
      },
    );
  }

  Widget _buildLibraryContent(BuildContext context) {
    final MusixController controller = widget.controller;
    final List<UserPlaylist> playlists = controller.playlists;
    final List<LibrarySong> cachedSongs = controller.cachedSongs;
    final List<LibrarySong> downloadedSongs = controller.downloadedSongs;
    final bool offline = controller.isOfflineViewActive;
    final bool hasCachedPlaylist = cachedSongs.isNotEmpty;
    final bool hasDownloads = downloadedSongs.isNotEmpty;
    final List<MapEntry<UserPlaylist, List<LibrarySong>>> visiblePlaylists =
        playlists
            .map((UserPlaylist playlist) {
              return MapEntry<UserPlaylist, List<LibrarySong>>(
                playlist,
                controller.songsForPlaylist(playlist),
              );
            })
            .toList(growable: false);
    final bool hasAnyPlaylistEntries =
        hasCachedPlaylist || playlists.isNotEmpty;
    final String buildSignature =
        '${widget.isActive}|$offline|${playlists.length}|'
        '${visiblePlaylists.fold<int>(0, (int total, MapEntry<UserPlaylist, List<LibrarySong>> entry) => total + entry.key.displaySongCount)}';
    if (widget.isActive && buildSignature != _lastBuildSignature) {
      _lastBuildSignature = buildSignature;
      AppLogger.trace(
        'LibraryUI',
        'build playlists=${playlists.length} offline=$offline',
      );
    }

    if (_isDesktopPlatform()) {
      return _DesktopLibraryScreen(
        controller: controller,
        showPlaylistContent: true,
      );
    }

    return DecoratedBox(
      decoration: _musixPageDecoration(),
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: _kAccent,
          backgroundColor: _kSurface,
          onRefresh: () async {
            await controller.refreshConnectivityStatus();
            if (!controller.isOfflineViewActive) {
              await controller.loadUserDataFromCloud(force: true);
            }
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification notification) {
              if (notification is UserScrollNotification ||
                  notification is ScrollUpdateNotification) {
                controller.registerScrollActivity();
              }
              return false;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: _rootScreenContentPadding(
                context,
                hasMiniPlayer: controller.miniPlayerSong != null,
              ),
              children: <Widget>[
                const _LibraryHeader(),
                const SizedBox(height: 28),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    const double spacing = 16;
                    final double itemWidth =
                        (constraints.maxWidth - spacing) / 2;
                    return Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: <Widget>[
                        SizedBox(
                          width: itemWidth,
                          child: _LibraryFeatureCard(
                            title: 'Downloads',
                            subtitle: hasDownloads
                                ? '${downloadedSongs.length} songs ready'
                                : 'Save music',
                            icon: Platform.isAndroid
                                ? null
                                : Icons.downloading_outlined,
                            accent: const Color(0xFFFF8C43),
                            secondary: const Color(0xFFCC5A18),
                            watermark: Icons.download_for_offline_rounded,
                            showArtwork: true,
                            watermarkAlignment: Platform.isAndroid
                                ? Alignment.topCenter
                                : null,
                            iconBackgroundColor: Colors.white.withValues(
                              alpha: 0.15,
                            ),
                            iconColor: Colors.white.withValues(alpha: 0.55),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (BuildContext context) =>
                                      _MusixPlaylistScreen(
                                        controller: controller,
                                        title: 'Downloads',
                                        songs: downloadedSongs,
                                        localPlaybackOnly: true,
                                      ),
                                ),
                              );
                            },
                          ),
                        ),
                        SizedBox(
                          width: itemWidth,
                          child: _LibraryFeatureCard(
                            title: 'Local Files',
                            subtitle: controller.supportsLocalFileImport
                                ? 'Import or browse'
                                : 'Ready anytime',
                            icon: Platform.isAndroid
                                ? null
                                : CupertinoIcons.folder_solid,
                            accent: const Color(0xFF4A1D06),
                            secondary: const Color(0xFF512007),
                            watermark: Icons.folder,
                            showArtwork: true,
                            watermarkAlignment: Platform.isAndroid
                                ? Alignment.topCenter
                                : null,
                            darkText: false,
                            iconColor: Colors.white.withValues(alpha: 0.7),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (BuildContext context) =>
                                      _MusixPlaylistScreen(
                                        controller: controller,
                                        title: 'Local Files',
                                        songs: controller.browsableSongs,
                                        localPlaybackOnly: true,
                                        showLocalImportActions: true,
                                      ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 34),
                ...<Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Playlists',
                          style: _musixBodyTextStyle(
                            color: const Color(0xFFFFE2D2),
                            fontSize: 32,
                            fontWeight: FontWeight.w600,
                            height: 0.95,
                          ),
                        ),
                      ),
                      if (!offline)
                        TextButton(
                          onPressed: () =>
                              _showCreatePlaylistDialog(context, controller),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFFF9B54),
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            'Create New +',
                            style: _musixBodyTextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (hasCachedPlaylist)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: _LibraryPlaylistRow(
                        controller: controller,
                        title: 'Saved Songs',
                        seed: 'cached_songs',
                        songs: cachedSongs,
                        subtitle: 'Playlist - ${cachedSongs.length} Saved',
                        forceEnabled: true,
                      ),
                    ),
                  if (!offline && !hasAnyPlaylistEntries)
                    _LibraryEmptyPlaylistCard(
                      onCreate: () =>
                          _showCreatePlaylistDialog(context, controller),
                    )
                  else if (controller.cloudLibraryLoading &&
                      !hasCachedPlaylist &&
                      visiblePlaylists.isEmpty)
                    const _LibraryBlockedCard(
                      title: 'Syncing Playlists',
                      subtitle:
                          'Loading your cloud playlists in the background.',
                      icon: Icons.cloud_sync_rounded,
                    )
                  else if (visiblePlaylists.isNotEmpty)
                    ...visiblePlaylists.map((
                      MapEntry<UserPlaylist, List<LibrarySong>> entry,
                    ) {
                      final UserPlaylist playlist = entry.key;
                      final List<LibrarySong> playlistSongs = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: _LibraryPlaylistRow(
                          controller: controller,
                          title: playlist.name,
                          seed: playlist.id,
                          songs: playlistSongs,
                          playlist: playlist,
                        ),
                      );
                    })
                  else if (!hasCachedPlaylist)
                    const _LibraryBlockedCard(
                      title: 'Cloud Playlists',
                      subtitle: 'Reconnect to open playlists from the cloud.',
                      icon: Icons.cloud_off_rounded,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _LibraryPlaylistSectionSkeleton extends StatelessWidget {
  const _LibraryPlaylistSectionSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SkeletonBlock(width: 140, height: 34, radius: 10),
        SizedBox(height: 18),
        _SkeletonBlock(width: double.infinity, height: 120, radius: 26),
      ],
    );
  }
}
