part of '../../../musix_ui.dart';

class _DesktopHomeScreen extends StatelessWidget {
  const _DesktopHomeScreen({
    required this.controller,
    required this.onOpenSearch,
  });

  final MusixController controller;
  final VoidCallback onOpenSearch;

  @override
  Widget build(BuildContext context) {
    if (controller.isOfflineViewActive) {
      final List<LibrarySong> localSongs = controller.browsableSongs
          .where((LibrarySong song) => !song.isRemote)
          .take(6)
          .toList(growable: false);
      return _DesktopPageScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _DesktopPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const _DesktopPanelTitle(
                    eyebrow: 'OFFLINE',
                    title: 'Desktop home is in offline mode',
                  ),
                  const SizedBox(height: 16),
                  _NetworkUnavailablePanel(
                    title: controller.offlineMusicMode
                        ? 'Offline Music Mode'
                        : 'No Internet Connection',
                    message: controller.offlineMusicMode
                        ? 'Only your local music is active right now. Online recommendations stay paused until connectivity returns.'
                        : 'Desktop recommendations need internet. Your local and saved music are still available.',
                    actionLabel: 'Retry',
                    onAction: () async {
                      await controller.refreshConnectivityStatus();
                    },
                    icon: controller.offlineMusicMode
                        ? Icons.offline_bolt_rounded
                        : Icons.cloud_off_rounded,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _DesktopPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const _DesktopPanelTitle(
                    eyebrow: 'READY OFFLINE',
                    title: 'Local picks',
                  ),
                  const SizedBox(height: 16),
                  if (localSongs.isEmpty)
                    _WindowsLocalImportPanel(controller: controller)
                  else
                    ...localSongs.asMap().entries.map(
                      (MapEntry<int, LibrarySong> entry) =>
                          _MusixPopularTrackTile(
                            index: entry.key + 1,
                            song: entry.value,
                            controller: controller,
                            onTap: () => controller.playSongs(
                              localSongs,
                              startIndex: entry.key,
                              label: 'Offline',
                            ),
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final List<HomeFeedSection> feed = _filteredHomeFeedSections(
      controller.homeFeed,
    );
    final HomeFeedSection? featuredArtistSection = _pickSingleArtistSection(
      feed,
    );
    final List<LibrarySong> mayYouLikeFull = _resolvedMayYouLikeSongs(
      controller,
    );
    final List<LibrarySong> mayYouLike = mayYouLikeFull
        .take(4)
        .toList(growable: false);
    final bool hasRevealableContent =
        feed.isNotEmpty || mayYouLikeFull.isNotEmpty;
    final bool showRecommendationLoadingState =
        !hasRevealableContent &&
        (controller.homeLoading || !controller.homeRefreshResolvedOnce);
    final _HomeEmptyStateMessages emptyStateMessages = _homeEmptyStateMessages(
      controller,
    );
    final List<LibrarySong> jumpBackIn = controller.recentlyPlayedSongs
        .take(4)
        .toList(growable: false);
    final _FeaturedHeroData? featured = _pickFeaturedHero(
      context: context,
      controller: controller,
      feed: feed,
      mayYouLike: mayYouLikeFull,
    );

    return _DesktopPageScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _DesktopPanel(
            child: showRecommendationLoadingState
                ? const _MusixHeroSkeleton()
                : featured != null
                ? _MusixHeroCard(
                    badge: featured.badge,
                    title: featured.title,
                    subtitle: featured.subtitle,
                    imageUrl: featured.imageUrl,
                    onListenNow: featured.onListenNow,
                  )
                : _PersonalizationHintCard(
                    message: emptyStateMessages.heroMessage,
                  ),
          ),
          const SizedBox(height: 20),
          _DesktopPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _MusixSectionHeader(
                  title: _HomeText.mayYouLike,
                  onViewAll: () {
                    if (mayYouLikeFull.isEmpty) {
                      onOpenSearch();
                      return;
                    }
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            _MayYouLikeScreen(controller: controller),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                if (showRecommendationLoadingState)
                  const _MusixListSkeleton(count: 4)
                else if (mayYouLike.isEmpty)
                  _PersonalizationHintCard(
                    message: emptyStateMessages.mayYouLikeMessage,
                  )
                else
                  _ProgressiveListReveal(
                    itemCount: mayYouLike.length,
                    showTrailingPlaceholders: true,
                    itemBuilder: (BuildContext context, int index) {
                      final LibrarySong song = mayYouLike[index];
                      return _MusixPopularTrackTile(
                        index: index + 1,
                        song: song,
                        controller: controller,
                        onTap: () {
                          if (song.isRemote) {
                            controller.playOnlineSong(song);
                          } else {
                            controller.playSong(song, label: 'May you like');
                          }
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
          if (showRecommendationLoadingState) ...<Widget>[
            const SizedBox(height: 20),
            const _RecommendationShelfSkeleton(wrapInDesktopPanel: true),
            const SizedBox(height: 20),
            const _TopArtistsLoadingBlock(isDesktop: true),
          ] else ...<Widget>[
            if (featuredArtistSection != null) ...<Widget>[
              _buildHomeShelf(
                context: context,
                controller: controller,
                section: featuredArtistSection,
                wrapInDesktopPanel: true,
                topPadding: 20,
              ),
            ],
            const SizedBox(height: 20),
            _DesktopPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const _MusixSectionHeader(title: _HomeText.topArtists),
                  const SizedBox(height: 10),
                  _TopArtistsSection(controller: controller, isDesktop: true),
                ],
              ),
            ),
          ],
          ..._buildMoreShelves(
            context: context,
            controller: controller,
            wrapInDesktopPanel: true,
            includeFeaturedArtistSection: false,
          ),
          if (controller.homeLoading && !hasRevealableContent) ...<Widget>[
            const SizedBox(height: 20),
            const _DesktopPanel(
              child: Opacity(opacity: 0.8, child: _HomeFeedSkeleton()),
            ),
          ],
          if (!controller.homeLoading && jumpBackIn.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            _DesktopPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _MusixSectionHeader(
                    title: _HomeText.jumpBackIn,
                    trailing: TextButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext context) =>
                                _RecentPlaysScreen(controller: controller),
                          ),
                        );
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: _kAccent,
                        backgroundColor: const Color(0x221C0904),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: _kSurfaceEdge),
                        ),
                        textStyle: _musixBodyTextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text('Open history'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          final double width = (constraints.maxWidth - 20) / 2;
                          return Wrap(
                            spacing: 20,
                            runSpacing: 20,
                            children: jumpBackIn.map((LibrarySong song) {
                              return _MusixJumpBackCard(
                                width: width.clamp(220.0, 420.0),
                                title: song.title,
                                subtitle: _songArtistLabel(song),
                                seed: song.id,
                                imageUrl: song.artworkUrl,
                                onTap: () {
                                  if (song.isRemote) {
                                    controller.playOnlineSong(song);
                                  } else {
                                    controller.playSong(
                                      song,
                                      label: 'Jump back in',
                                    );
                                  }
                                },
                              );
                            }).toList(),
                          );
                        },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
