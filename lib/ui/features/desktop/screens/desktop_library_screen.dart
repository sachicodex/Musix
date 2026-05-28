part of '../../../musix_ui.dart';

class _DesktopLibraryScreen extends StatelessWidget {
  const _DesktopLibraryScreen({
    required this.controller,
    required this.showPlaylistContent,
  });

  final MusixController controller;
  final bool showPlaylistContent;

  @override
  Widget build(BuildContext context) {
    final bool offline = controller.isOfflineViewActive;
    final List<UserPlaylist> playlists = controller.playlists;
    final List<LibrarySong> cachedSongs = controller.cachedSongs;
    final List<LibrarySong> downloadedSongs = controller.downloadedSongs;
    final bool hasCachedPlaylist = cachedSongs.isNotEmpty;
    final bool hasDownloads = downloadedSongs.isNotEmpty;
    final List<_DesktopLibraryPlaylistEntry> playlistEntries =
        <_DesktopLibraryPlaylistEntry>[
          if (hasCachedPlaylist)
            _DesktopLibraryPlaylistEntry(
              title: 'Saved Songs',
              seed: 'cached_songs',
              songs: cachedSongs,
              subtitle: '${cachedSongs.length} saved songs',
            ),
          ...playlists.map((UserPlaylist playlist) {
            final List<LibrarySong> playlistSongs = controller.songsForPlaylist(
              playlist,
            );
            return _DesktopLibraryPlaylistEntry(
              title: playlist.name,
              seed: playlist.id,
              songs: playlistSongs,
              playlist: playlist,
              subtitle: '${playlist.displaySongCount} songs',
            );
          }),
        ].toList(growable: false);
    final bool hasAnyPlaylistEntries = playlistEntries.isNotEmpty;

    return _DesktopPageScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final int columns = _isDesktopPlatform() ? 2 : 1;
              const double spacing = 20;
              final double totalSpacing = spacing * (columns - 1);
              final double availableWidth = constraints.maxWidth - totalSpacing;
              final double itemWidth = availableWidth / columns;

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
                      icon: Icons.downloading_outlined,
                      accent: const Color(0xFFFF8C43),
                      secondary: const Color(0xFFCC5A18),
                      watermark: Icons.download_for_offline_rounded,
                      iconBackgroundColor: Colors.white.withValues(alpha: 0.15),
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
                      icon: CupertinoIcons.folder_solid,
                      accent: const Color(0xFF4A1D06),
                      secondary: const Color(0xFF512007),
                      watermark: Icons.folder,
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
          const SizedBox(height: 20),
          _DesktopPanel(
            child: showPlaylistContent
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              'Playlists',
                              style: _musixBodyTextStyle(
                                color: const Color(0xFFFFE2D2),
                                fontSize: 28,
                                fontWeight: FontWeight.w600,
                                height: 0.95,
                              ),
                            ),
                          ),
                          if (!offline)
                            TextButton(
                              onPressed: () => _showCreatePlaylistDialog(
                                context,
                                controller,
                              ),
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
                      if (!offline && !hasAnyPlaylistEntries)
                        _LibraryEmptyPlaylistCard(
                          onCreate: () =>
                              _showCreatePlaylistDialog(context, controller),
                        )
                      else if (playlistEntries.isNotEmpty)
                        LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final int columns = _isDesktopPlatform()
                                    ? 2
                                    : 1;
                                const double spacing = 18;
                                final double totalSpacing =
                                    spacing * (columns - 1);
                                final double availableWidth =
                                    constraints.maxWidth - totalSpacing;
                                final double itemWidth =
                                    availableWidth / columns;

                                return Wrap(
                                  spacing: spacing,
                                  runSpacing: spacing,
                                  children: playlistEntries.map((
                                    _DesktopLibraryPlaylistEntry entry,
                                  ) {
                                    return SizedBox(
                                      width: itemWidth,
                                      child: _DesktopPlaylistBox(
                                        controller: controller,
                                        title: entry.title,
                                        seed: entry.seed,
                                        songs: entry.songs,
                                        playlist: entry.playlist,
                                        subtitle: entry.subtitle,
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                        )
                      else if (!hasCachedPlaylist)
                        const _LibraryBlockedCard(
                          title: 'Cloud Playlists',
                          subtitle:
                              'Reconnect to open playlists from the cloud.',
                          icon: Icons.cloud_off_rounded,
                        ),
                    ],
                  )
                : const _LibraryPlaylistSectionSkeleton(),
          ),
        ],
      ),
    );
  }
}
