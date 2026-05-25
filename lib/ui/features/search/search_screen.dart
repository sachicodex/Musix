part of '../../musix_ui.dart';

class _SearchPulseHeader extends StatelessWidget {
  const _SearchPulseHeader();

  @override
  Widget build(BuildContext context) {
    return const _HomeStyleHeader(
      title: 'SEARCH',
      leading: _HomeStyleProfileBadge(),
      trailing: _HomeStyleNotificationIcon(),
    );
  }
}

class _SearchSectionTitle extends StatelessWidget {
  const _SearchSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
        color: _kTextPrimary,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _SearchHistoryChip extends StatelessWidget {
  const _SearchHistoryChip({
    required this.label,
    required this.onTap,
    required this.onRemove,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return _ApplePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          color: MusixColors.textFieldFill,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: MusixColors.surfaceEdge),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _kTextSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onRemove,
                child: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: MusixColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchGenreCard extends StatelessWidget {
  const _SearchGenreCard({
    required this.shelf,
    required this.height,
    required this.onTap,
    this.wide = false,
  });

  final _SearchGenreShelf shelf;
  final double height;
  final VoidCallback onTap;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return _ApplePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            colors: shelf.colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: <Widget>[
            Positioned(
              top: 18,
              left: 16,
              right: 16,
              child: Text(
                shelf.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: const Color(0xFFFFEDE3),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Positioned(
              right: wide ? 14 : -4,
              bottom: wide ? -6 : -8,
              child: Transform.rotate(
                angle: -0.16,
                child: Opacity(
                  opacity: 0.95,
                  child: _SearchGenreThumbnail(
                    shelf: shelf,
                    size: wide ? 150 : 110,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchGenreThumbnail extends StatelessWidget {
  const _SearchGenreThumbnail({required this.shelf, required this.size});

  final _SearchGenreShelf shelf;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          shelf.assetPath,
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) {
                final String? fallbackAssetPath = shelf.fallbackAssetPath;
                if (fallbackAssetPath != null) {
                  return Image.asset(
                    fallbackAssetPath,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (
                          BuildContext context,
                          Object error,
                          StackTrace? stackTrace,
                        ) {
                          return _SearchGenreThumbnailFallback(
                            shelf: shelf,
                            size: size,
                          );
                        },
                  );
                }
                return _SearchGenreThumbnailFallback(shelf: shelf, size: size);
              },
        ),
      ),
    );
  }
}

class _SearchGenreThumbnailFallback extends StatelessWidget {
  const _SearchGenreThumbnailFallback({
    required this.shelf,
    required this.size,
  });

  final _SearchGenreShelf shelf;
  final double size;

  @override
  Widget build(BuildContext context) {
    final LibrarySong? song = shelf.song;
    if (song != null) {
      return _Artwork(
        seed: song.id,
        title: song.title,
        size: size,
        imageUrl: song.artworkUrl,
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        gradient: LinearGradient(
          colors: shelf.colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: _ArtworkFallbackSurface(colors: shelf.colors),
    );
  }
}

class _SearchTrendingTile extends StatelessWidget {
  const _SearchTrendingTile({
    required this.rank,
    required this.song,
    required this.controller,
  });

  final int rank;
  final LibrarySong song;
  final MusixController controller;

  @override
  Widget build(BuildContext context) {
    final String subtitle = _songArtistLabel(song);
    final bool canQueue = controller.shouldShowSongOutsideSearch(song);
    final Widget tile = _SongCardRow(
      song: song,
      index: rank,
      subtitle: subtitle,
      metaText: _formatClock(song.duration),
      artworkSize: 56,
      onTap: () {
        if (song.isRemote) {
          controller.playOnlineSong(song);
        } else {
          controller.playSong(song, label: 'Search trending');
        }
      },
      onLongPress: () {
        unawaited(
          _showSongActionsSheet(
            context,
            controller: controller,
            song: song,
            allowFavorite: true,
            allowQueue: canQueue,
            allowPlaylist: false,
          ),
        );
      },
    );
    if (!canQueue) {
      return tile;
    }
    return Dismissible(
      key: ValueKey<String>('search-song-${song.id}-$rank'),
      direction: DismissDirection.startToEnd,
      background: const _SwipeActionBackground(
        alignment: Alignment.centerLeft,
        color: Color(0xFF18432B),
        icon: Icons.queue_music_rounded,
        label: 'Queue',
      ),
      confirmDismiss: (DismissDirection direction) async {
        await HapticFeedback.selectionClick();
        await controller.enqueueSong(song);
        if (context.mounted) {
          _showMusixSnackBar(context, 'Added to queue');
        }
        return false;
      },
      child: tile,
    );
  }
}

InputDecoration _buildSearchFieldDecoration({
  required String hintText,
  double borderRadius = 20,
  double verticalPadding = 20,
}) {
  return musixInputDecoration(
    hintText: hintText,
    prefixIcon: const Padding(
      padding: EdgeInsets.only(left: 10),
      child: Icon(Icons.search_rounded),
    ),
    prefixIconConstraints: const BoxConstraints(minWidth: 52, minHeight: 0),
    borderRadius: borderRadius,
    contentPadding: EdgeInsets.symmetric(vertical: verticalPadding),
    floatingLabelBehavior: FloatingLabelBehavior.never,
  );
}

class _SearchScreen extends StatefulWidget {
  const _SearchScreen({
    super.key,
    required this.controller,
    required this.isActive,
    this.focusRequestSerial = 0,
  });

  final MusixController controller;
  final bool isActive;
  final int focusRequestSerial;

  @override
  State<_SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<_SearchScreen>
    with AutomaticKeepAliveClientMixin<_SearchScreen> {
  static const Duration _searchDebounceDuration = Duration(milliseconds: 250);
  static const Duration _trendingRequestDelay = Duration(milliseconds: 180);
  static const List<String> _genreAssetPaths = <String>[
    'assets/img/hip_hop.png',
    'assets/img/pop.png',
    'assets/img/electronic.png',
    'assets/img/jazz.png',
    'assets/img/chill_focus.png',
  ];

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  final List<String> _recentSearches = <String>[];
  Timer? _searchDebounce;
  bool _requestedTrending = false;
  String? _browseCacheSignature;
  List<_SearchGenreShelf>? _cachedBrowseShelves;
  String? _trendingCacheSignature;
  List<LibrarySong>? _cachedMonthlyTrending;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final String initialDraft = widget.controller.searchDraft;
    if (initialDraft.isNotEmpty) {
      _searchController.value = TextEditingValue(
        text: initialDraft,
        selection: TextSelection.collapsed(offset: initialDraft.length),
      );
    }
    _recentSearches.addAll(widget.controller.recentSearchTerms);
    widget.controller.addListener(_syncSearchStateFromController);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheGenreAssets();
      _scheduleTrendingRequest();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    widget.controller.removeListener(_syncSearchStateFromController);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _scheduleTrendingRequest();
    }
    if (widget.focusRequestSerial != oldWidget.focusRequestSerial) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _searchFocusNode.requestFocus();
      });
    }
  }

  void _precacheGenreAssets() {
    if (!mounted) {
      return;
    }
    for (final String assetPath in _genreAssetPaths) {
      precacheImage(AssetImage(assetPath), context);
    }
  }

  void _scheduleTrendingRequest() {
    if (!mounted || _requestedTrending || !widget.isActive) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _requestedTrending || !widget.isActive) {
        return;
      }
      Future<void>.delayed(_trendingRequestDelay, () {
        _requestTrendingIfNeeded();
      });
    });
  }

  void _requestTrendingIfNeeded() {
    if (!mounted || _requestedTrending || !widget.isActive) {
      return;
    }
    _requestedTrending = true;
    unawaited(
      widget.controller.loadTrendingNow(
        languageCode: widget.controller.preferredLanguageCode,
        countryCode: widget.controller.preferredCountryCode,
      ),
    );
  }

  List<_SearchGenreShelf> _browseShelvesFor(MusixController controller) {
    final String signature =
        '${controller.search.homeRevision}|${controller.search.libraryRevision}';
    if (_browseCacheSignature == signature && _cachedBrowseShelves != null) {
      return _cachedBrowseShelves!;
    }
    _browseCacheSignature = signature;
    _cachedBrowseShelves = _buildSearchGenreShelves(controller);
    return _cachedBrowseShelves!;
  }

  List<LibrarySong> _monthlyTrendingFor(MusixController controller) {
    final String signature =
        '${controller.search.revision}|${controller.preferredRegionLabel}';
    if (_trendingCacheSignature == signature && _cachedMonthlyTrending != null) {
      return _cachedMonthlyTrending!;
    }
    _trendingCacheSignature = signature;
    _cachedMonthlyTrending = _buildMonthlyTrendingNow(
      controller: controller,
    ).take(7).toList(growable: false);
    return _cachedMonthlyTrending!;
  }

  void _syncSearchStateFromController() {
    final String draft = widget.controller.searchDraft;
    if (_searchController.text != draft) {
      _searchDebounce?.cancel();
      _searchController.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
    final List<String> nextRecentSearches = widget.controller.recentSearchTerms;
    if (!listEquals(_recentSearches, nextRecentSearches) && mounted) {
      setState(() {
        _recentSearches
          ..clear()
          ..addAll(nextRecentSearches);
      });
    }
  }

  void _onScroll() {
    widget.controller.registerScrollActivity();
    if (!_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.extentAfter > 480) {
      return;
    }
    if (_searchController.text.trim().isEmpty) {
      return;
    }
    widget.controller.loadMoreOnlineResults();
  }

  void _runSearch(String value) {
    final String trimmed = value.trim();
    widget.controller.cacheSearchDraft(value);
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) {
        return;
      }
      unawaited(widget.controller.searchOnline(trimmed));
    });
  }

  void _rememberSearch(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    widget.controller.rememberRecentSearch(trimmed);
    setState(() {
      _recentSearches
        ..clear()
        ..addAll(widget.controller.recentSearchTerms);
    });
  }

  void _applySearch(String value) {
    _searchController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _rememberSearch(value);
    _runSearch(value);
  }

  Future<void> _refreshSearchContent() async {
    await widget.controller.refreshConnectivityStatus();
    final String query = _searchController.text.trim();
    if (query.isEmpty) {
      await widget.controller.loadTrendingNow(
        languageCode: widget.controller.preferredLanguageCode,
        countryCode: widget.controller.preferredCountryCode,
        force: true,
      );
      return;
    }
    await widget.controller.searchOnline(query);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.controller.search,
        widget.controller.connectivity,
      ]),
      builder: (BuildContext context, Widget? _) {
        return _buildSearchScreen(context);
      },
    );
  }

  Widget _buildSearchScreen(BuildContext context) {
    if (_isDesktopPlatform()) {
      return _DesktopSearchScreen(
        controller: widget.controller,
        searchController: _searchController,
        searchFocusNode: _searchFocusNode,
        scrollController: _scrollController,
        recentSearches: _recentSearches,
        onRunSearch: _runSearch,
        onRememberSearch: _rememberSearch,
        onApplySearch: _applySearch,
        onRemoveSearch: (String term) {
          widget.controller.removeRecentSearch(term);
          setState(() {
            _recentSearches
              ..clear()
              ..addAll(widget.controller.recentSearchTerms);
          });
        },
      );
    }
    final bool searchOffline = widget.controller.isOfflineViewActive;
    if (searchOffline) {
      return _SearchOfflineState(controller: widget.controller);
    }

    final String query = _searchController.text.trim().toLowerCase();

    final List<LibrarySong> monthlyTrendingSongs = query.isEmpty
        ? _monthlyTrendingFor(widget.controller)
        : const <LibrarySong>[];
    final List<_SearchGenreShelf> browseShelves = query.isEmpty
        ? _browseShelvesFor(widget.controller)
        : const <_SearchGenreShelf>[];
    final List<LibrarySong> topResults = query.isEmpty
        ? const <LibrarySong>[]
        : _mergeSearchResults(
            widget.controller.songs
                .where(
                  (LibrarySong song) =>
                      widget.controller.shouldShowSongOutsideSearch(song) &&
                      (song.title.toLowerCase().contains(query) ||
                          song.artist.toLowerCase().contains(query) ||
                          song.album.toLowerCase().contains(query)),
                )
                .toList(growable: false),
            widget.controller.onlineResults,
            query: _searchController.text,
          );

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[Color(0xFF2B0D02), Color(0xFF170602)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: RefreshIndicator(
              color: _kAccent,
              backgroundColor: _kSurface,
              onRefresh: _refreshSearchContent,
              child: ListView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: _rootScreenContentPadding(
                  context,
                  hasMiniPlayer: widget.controller.miniPlayerSong != null,
                ),
                children: <Widget>[
                  const _SearchPulseHeader(),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _runSearch,
                    onSubmitted: _rememberSearch,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: _buildSearchFieldDecoration(
                      hintText: 'Artists, songs or albums',
                      borderRadius: 18,
                      verticalPadding: 18,
                    ),
                  ),
                  const SizedBox(height: 15),
                  if (_recentSearches.isNotEmpty) ...<Widget>[
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _recentSearches.map((String term) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: _SearchHistoryChip(
                              label: term,
                              onTap: () => _applySearch(term),
                              onRemove: () {
                                widget.controller.removeRecentSearch(term);
                                setState(() {
                                  _recentSearches
                                    ..clear()
                                    ..addAll(
                                      widget.controller.recentSearchTerms,
                                    );
                                });
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (query.isEmpty) ...<Widget>[
                    Text(
                      'Browse All',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        color: _kTextPrimary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.05,
                      ),
                    ),
                    const SizedBox(height: 18),
                    RepaintBoundary(
                      child: LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                              final double width = constraints.maxWidth;
                              final double smallWidth = ((width - 14) / 2)
                                  .clamp(
                                    120.0,
                                    260.0,
                                  );
                              final _SearchGenreShelf large =
                                  browseShelves.last;
                              final List<_SearchGenreShelf> small = browseShelves
                                  .take(browseShelves.length - 1)
                                  .toList(growable: false);
                              return Wrap(
                                spacing: 14,
                                runSpacing: 16,
                                children: <Widget>[
                                  ...small.map(
                                    (_SearchGenreShelf shelf) => SizedBox(
                                      width: smallWidth,
                                      child: _SearchGenreCard(
                                        shelf: shelf,
                                        height: 164,
                                        onTap: () => _applySearch(shelf.query),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: width,
                                    child: _SearchGenreCard(
                                      shelf: large,
                                      height: 196,
                                      wide: true,
                                      onTap: () => _applySearch(large.query),
                                    ),
                                  ),
                                ],
                              );
                            },
                      ),
                    ),
                    const SizedBox(height: 34),
                    const _SearchSectionTitle('Trending Now'),
                    const SizedBox(height: 18),
                    RepaintBoundary(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (monthlyTrendingSongs.isEmpty &&
                              !widget.controller.trendingNowLoading)
                            Text(
                              'Regional chart songs are loading for ${widget.controller.preferredRegionLabel}.',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: MusixColors.textMuted,
                                  ),
                            )
                          else
                            ...monthlyTrendingSongs.asMap().entries.map(
                              (MapEntry<int, LibrarySong> entry) =>
                                  _SearchTrendingTile(
                                    rank: entry.key + 1,
                                    song: entry.value,
                                    controller: widget.controller,
                                  ),
                            ),
                          if (widget.controller.trendingNowLoading)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: _OnlineSongResultsSkeleton(),
                            ),
                          if (widget.controller.trendingNowError != null &&
                              monthlyTrendingSongs.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                widget.controller.trendingNowError!,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: const Color(0xFFFFA27C)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ] else ...<Widget>[
                    const _SearchSectionTitle('Top Results'),
                    const SizedBox(height: 14),
                    if (topResults.isEmpty && !widget.controller.onlineLoading)
                      Text(
                        'No matches found for "${_searchController.text.trim()}".',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: MusixColors.textMuted,
                        ),
                      )
                    else ...<Widget>[
                      ...topResults.asMap().entries.map(
                        (MapEntry<int, LibrarySong> entry) =>
                            _SearchTrendingTile(
                              rank: entry.key + 1,
                              song: entry.value,
                              controller: widget.controller,
                            ),
                      ),
                      if (widget.controller.onlineLoading)
                        const _OnlineSongResultsSkeleton()
                      else if (widget.controller.onlineHasMore)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Center(
                            child: Text(
                              'Scroll for more',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: MusixColors.textMuted),
                            ),
                          ),
                        ),
                    ],
                    if (widget.controller.onlineError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: Text(
                          widget.controller.onlineError!,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: const Color(0xFFFFA27C)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchOfflineState extends StatelessWidget {
  const _SearchOfflineState({required this.controller});

  final MusixController controller;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[Color(0xFF2B0D02), Color(0xFF170602)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: _kAccent,
          backgroundColor: _kSurface,
          onRefresh: () => controller.refreshConnectivityStatus(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: _rootScreenContentPadding(
              context,
              hasMiniPlayer: controller.miniPlayerSong != null,
            ),
            children: <Widget>[
              const _SearchPulseHeader(),
              const SizedBox(height: 140),
              _NetworkUnavailablePanel(
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
            ],
          ),
        ),
      ),
    );
  }
}

List<LibrarySong> _mergeSearchResults(
  List<LibrarySong> localResults,
  List<LibrarySong> onlineResults, {
  required String query,
}) {
  final List<LibrarySong> merged = <LibrarySong>[];
  final Set<String> seen = <String>{};
  final Map<LibrarySong, int> originalOrder = <LibrarySong, int>{};

  String keyOf(LibrarySong song) {
    String normalize(String value) {
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

    return '${normalize(song.artist)}::${normalize(song.title)}';
  }

  for (final LibrarySong song in <LibrarySong>[
    ...localResults,
    ...onlineResults,
  ]) {
    if (song.isDisliked) {
      continue;
    }
    final String key = keyOf(song);
    if (seen.add(key)) {
      originalOrder[song] = merged.length;
      merged.add(song);
    }
  }

  final String normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) {
    return merged;
  }

  int score(LibrarySong song) {
    final String title = song.title.trim().toLowerCase();
    final String artist = song.artist.trim().toLowerCase();
    final String album = song.album.trim().toLowerCase();
    final String full = '$title $artist $album';

    int value = 0;
    if (title == normalizedQuery) {
      value += 220;
    }
    if (artist == normalizedQuery) {
      value += 110;
    }
    if (title.startsWith(normalizedQuery)) {
      value += 80;
    }
    if (artist.startsWith(normalizedQuery)) {
      value += 42;
    }
    if (album.startsWith(normalizedQuery)) {
      value += 24;
    }
    if (title.contains(normalizedQuery)) {
      value += 20;
    }
    if (full.contains(' $normalizedQuery ')) {
      value += 18;
    }
    if (full.contains(normalizedQuery)) {
      value += 8;
    }
    if (song.isRemote) {
      value += 2;
    }
    return value;
  }

  merged.sort((LibrarySong a, LibrarySong b) {
    final int scoreCompare = score(b).compareTo(score(a));
    if (scoreCompare != 0) {
      return scoreCompare;
    }
    return (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0);
  });
  return merged;
}

class _OnlineSongResultsSkeleton extends StatelessWidget {
  const _OnlineSongResultsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: <Widget>[
        _SearchTrendingTileSkeleton(),
        _SearchTrendingTileSkeleton(),
        _SearchTrendingTileSkeleton(),
        _SearchTrendingTileSkeleton(),
      ],
    );
  }
}

class _MusixSectionHeaderSkeleton extends StatelessWidget {
  const _MusixSectionHeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        Expanded(child: _SkeletonBlock(width: double.infinity, height: 22)),
        SizedBox(width: 12),
        _SkeletonBlock(width: 64, height: 14, radius: 8),
      ],
    );
  }
}

class _MusixPopularTrackTileSkeleton extends StatelessWidget {
  const _MusixPopularTrackTileSkeleton({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return _SongCardSkeleton(index: index);
  }
}

class _SearchTrendingTileSkeleton extends StatelessWidget {
  const _SearchTrendingTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const _SongCardSkeleton(index: 1, artworkSize: 56);
  }
}
