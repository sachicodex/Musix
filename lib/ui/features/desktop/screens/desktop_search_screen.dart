part of '../../../musix_ui.dart';

class _DesktopSearchScreen extends StatelessWidget {
  const _DesktopSearchScreen({
    required this.controller,
    required this.searchController,
    required this.searchFocusNode,
    required this.scrollController,
    required this.recentSearches,
    required this.onRunSearch,
    required this.onRememberSearch,
    required this.onApplySearch,
    required this.onRemoveSearch,
  });

  final MusixController controller;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final ScrollController scrollController;
  final List<String> recentSearches;
  final ValueChanged<String> onRunSearch;
  final ValueChanged<String> onRememberSearch;
  final ValueChanged<String> onApplySearch;
  final ValueChanged<String> onRemoveSearch;

  @override
  Widget build(BuildContext context) {
    final bool offline = controller.isOfflineViewActive;
    if (offline) {
      return _DesktopPageScrollView(
        child: _DesktopPanel(
          child: _NetworkUnavailablePanel(
            title: controller.offlineMusicMode
                ? 'Offline Music Only'
                : 'Search Is Offline',
            message: controller.offlineMusicMode
                ? 'Search is limited to your local music right now. Reconnect to search online songs again.'
                : 'Internet is required for online search. Your local music is still available in Home and Library.',
            actionLabel: 'Retry',
            onAction: () => controller.refreshConnectivityStatus(),
            icon: controller.offlineMusicMode
                ? Icons.offline_bolt_rounded
                : Icons.wifi_off_rounded,
          ),
        ),
      );
    }

    final String query = searchController.text.trim().toLowerCase();
    final List<LibrarySong> songs = controller.songs
        .where(
          (LibrarySong song) =>
              query.isEmpty ||
              song.title.toLowerCase().contains(query) ||
              song.artist.toLowerCase().contains(query) ||
              song.album.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final List<_SearchGenreShelf> browseShelves = _buildSearchGenreShelves(
      controller,
    );
    final List<LibrarySong> monthlyTrendingSongs = _buildMonthlyTrendingNow(
      controller: controller,
    ).take(7).toList(growable: false);
    final List<LibrarySong> topResults = _mergeSearchResults(
      songs,
      controller.onlineResults,
      query: searchController.text,
    );

    return _DesktopPageScrollView(
      controller: scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _DesktopPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _DesktopPanelTitle(
                  eyebrow: 'SEARCH',
                  title: 'Find artists, songs, and playlists',
                ),
                const SizedBox(height: 16),
                Focus(
                  onKeyEvent: (FocusNode node, KeyEvent event) {
                    if (node.hasFocus &&
                        _isBareBackspace(event) &&
                        searchController.text.isEmpty) {
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: searchController,
                    focusNode: searchFocusNode,
                    onChanged: onRunSearch,
                    onSubmitted: onRememberSearch,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: _buildSearchFieldDecoration(
                      hintText: 'Artists, songs, albums, or playlists',
                    ),
                  ),
                ),
                if (recentSearches.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: recentSearches.map((String term) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _SearchHistoryChip(
                            label: term,
                            onTap: () => onApplySearch(term),
                            onRemove: () => onRemoveSearch(term),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (query.isEmpty)
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool stacked = constraints.maxWidth < 1160;
                final Widget browse = _DesktopPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                              final double totalWidth = constraints.maxWidth;
                              final int columns = totalWidth >= 1180
                                  ? 3
                                  : totalWidth >= 520
                                  ? 2
                                  : 1;
                              final double itemWidth = math.max(
                                0,
                                (totalWidth - ((columns - 1) * 16)) / columns,
                              );
                              return Wrap(
                                spacing: 16,
                                runSpacing: 16,
                                children: browseShelves.asMap().entries.map((
                                  MapEntry<int, _SearchGenreShelf> entry,
                                ) {
                                  final int index = entry.key;
                                  final _SearchGenreShelf shelf = entry.value;
                                  final bool isLast =
                                      index == browseShelves.length - 1;
                                  final bool shouldSpanFullWidth =
                                      isLast &&
                                      browseShelves.length % columns == 1;
                                  return SizedBox(
                                    width: shouldSpanFullWidth
                                        ? totalWidth
                                        : itemWidth,
                                    child: _SearchGenreCard(
                                      shelf: shelf,
                                      height: shouldSpanFullWidth || isLast
                                          ? 210
                                          : 176,
                                      wide: shouldSpanFullWidth || isLast,
                                      onTap: () => onApplySearch(shelf.query),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                      ),
                    ],
                  ),
                );

                final Widget trending = _DesktopPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const _DesktopPanelTitle(
                        eyebrow: 'TRENDING',
                        title: 'Regional Trends',
                      ),
                      const SizedBox(height: 18),
                      if (monthlyTrendingSongs.isEmpty &&
                          !controller.trendingNowLoading)
                        Text(
                          'Regional chart songs are loading for ${controller.preferredRegionLabel}.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: const Color(0xFFD1A793)),
                        )
                      else
                        ...monthlyTrendingSongs.asMap().entries.map(
                          (MapEntry<int, LibrarySong> entry) =>
                              _SearchTrendingTile(
                                rank: entry.key + 1,
                                song: entry.value,
                                controller: controller,
                              ),
                        ),
                      if (controller.trendingNowLoading)
                        const _OnlineSongResultsSkeleton(),
                    ],
                  ),
                );

                if (stacked) {
                  return Column(
                    children: <Widget>[
                      browse,
                      const SizedBox(height: 20),
                      trending,
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(flex: 7, child: browse),
                    const SizedBox(width: 20),
                    Expanded(flex: 5, child: trending),
                  ],
                );
              },
            )
          else
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget results = _DesktopPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const _DesktopPanelTitle(
                        eyebrow: 'RESULTS',
                        title: 'Top matches',
                      ),
                      const SizedBox(height: 16),
                      if (topResults.isEmpty && !controller.onlineLoading)
                        Text(
                          'No matches found for "${searchController.text.trim()}".',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: const Color(0xFFD1A793)),
                        )
                      else ...<Widget>[
                        ...topResults.asMap().entries.map(
                          (MapEntry<int, LibrarySong> entry) =>
                              _SearchTrendingTile(
                                rank: entry.key + 1,
                                song: entry.value,
                                controller: controller,
                              ),
                        ),
                        if (controller.onlineLoading)
                          const _OnlineSongResultsSkeleton()
                        else if (controller.onlineHasMore)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Scroll for more',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFFD1A793)),
                            ),
                          ),
                      ],
                      if (controller.onlineError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Text(
                            controller.onlineError!,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: const Color(0xFFFFA27C)),
                          ),
                        ),
                    ],
                  ),
                );

                return results;
              },
            ),
        ],
      ),
    );
  }
}
