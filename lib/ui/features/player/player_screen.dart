part of '../../musix_ui.dart';

class _PlayerScreen extends StatefulWidget {
  const _PlayerScreen({required this.controller});

  final MusixController controller;

  @override
  State<_PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<_PlayerScreen>
    with TickerProviderStateMixin {
  static const double _kPlayerGestureVelocity = 420;

  late final AnimationController _tapFeedbackController;
  late final AnimationController _likeFeedbackController;
  late final KeyEventCallback _shortcutHandler;
  bool _showPauseGlyph = false;

  @override
  void initState() {
    super.initState();
    _tapFeedbackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _likeFeedbackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _shortcutHandler = _handleShortcutKeyEvent;
    HardwareKeyboard.instance.addHandler(_shortcutHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_shortcutHandler);
    _tapFeedbackController.dispose();
    _likeFeedbackController.dispose();
    super.dispose();
  }

  Future<void> _showQueueSheet() async {
    final MusixController controller = widget.controller;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, _) {
            return _PlayerQueueSheet(controller: controller);
          },
        );
      },
    );
  }

  Future<void> _handleDownloadAction(LibrarySong song) async {
    final MusixController controller = widget.controller;
    final String message = await controller.downloadSongForOffline(song);
    if (!mounted) {
      return;
    }
    _showMusixSnackBar(context, message);
  }

  Future<void> _handleSaveAction(LibrarySong song) async {
    await _showAddToPlaylistDialog(context, widget.controller, song);
  }

  Future<void> _handleAlbumArtDoubleTap(LibrarySong song) async {
    await _triggerLikeFeedback();
    if (!song.isLiked) {
      await widget.controller.likeSong(song.id);
    }
  }

  Future<void> _handleAlbumArtTap() async {
    await _triggerPlaybackFeedback();
    unawaited(widget.controller.togglePlayback());
  }

  Future<void> _handleDislikeAction(LibrarySong song) async {
    await HapticFeedback.mediumImpact();
    await widget.controller.dislikeSong(song.id);
  }

  Future<void> _handleBackNavigation() async {
    if (!mounted) {
      return;
    }
    await Navigator.of(context).maybePop();
  }

  bool _handleShortcutKeyEvent(KeyEvent event) {
    if (!mounted ||
        !_routeIsCurrent(context) ||
        _focusedWidgetAcceptsTextInput()) {
      return false;
    }
    final LibrarySong? song = widget.controller.nowPlayingState.value.song;
    if (song == null) {
      return false;
    }
    return _handleShortcutBindings(event, <_ShortcutBinding>[
      if (_isDesktopPlatform()) ...<_ShortcutBinding>[
        _ShortcutBinding(
          const SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            includeRepeats: false,
          ),
          () => unawaited(widget.controller.previousTrack()),
        ),
        _ShortcutBinding(
          const SingleActivator(
            LogicalKeyboardKey.arrowRight,
            includeRepeats: false,
          ),
          () => unawaited(widget.controller.nextTrack()),
        ),
        _ShortcutBinding(
          const SingleActivator(LogicalKeyboardKey.keyQ, includeRepeats: false),
          () => unawaited(_showQueueSheet()),
        ),
      ],
      _ShortcutBinding(
        const SingleActivator(LogicalKeyboardKey.keyL, includeRepeats: false),
        () => unawaited(widget.controller.likeSong(song.id)),
      ),
      _ShortcutBinding(
        const SingleActivator(LogicalKeyboardKey.keyD, includeRepeats: false),
        () => unawaited(widget.controller.dislikeSong(song.id)),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.arrowDown,
          includeRepeats: false,
        ),
        () => unawaited(_handleBackNavigation()),
      ),
    ]);
  }

  Future<void> _triggerPlaybackFeedback() async {
    final PlaybackProgressState progress =
        widget.controller.playbackProgressState.value;
    final bool isPlayerLoading =
        widget.controller.nowPlayingState.value.isLoading;
    _showPauseGlyph = !progress.isPlaying || isPlayerLoading;
    _tapFeedbackController
      ..stop()
      ..reset()
      ..forward();
    unawaited(HapticFeedback.lightImpact());
  }

  Future<void> _triggerLikeFeedback() async {
    _likeFeedbackController
      ..stop()
      ..reset()
      ..forward();
    unawaited(HapticFeedback.selectionClick());
  }

  Future<void> _handlePlayerPanEnd(DragEndDetails details) async {
    final Velocity velocity = details.velocity;
    final double dx = velocity.pixelsPerSecond.dx;
    final double dy = velocity.pixelsPerSecond.dy;

    if (dx.abs() < _kPlayerGestureVelocity &&
        dy.abs() < _kPlayerGestureVelocity) {
      return;
    }

    if (dx.abs() > dy.abs()) {
      unawaited(HapticFeedback.selectionClick());
      if (dx < 0) {
        await widget.controller.nextTrack();
      } else {
        await widget.controller.previousTrack();
      }
      return;
    }

    if (dy < 0) {
      await HapticFeedback.selectionClick();
      await _showQueueSheet();
      return;
    }

    await HapticFeedback.selectionClick();
    if (mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final MusixController controller = widget.controller;
    return ValueListenableBuilder<NowPlayingState>(
      valueListenable: controller.nowPlayingState,
      builder: (BuildContext context, NowPlayingState nowPlaying, Widget? child) {
        final LibrarySong? song = nowPlaying.song;
        if (song == null) {
          return const Scaffold(
            body: Center(child: Text('Nothing is playing.')),
          );
        }

        const Color backgroundTop = Color(0xFF774120);
        const Color backgroundBottom = Color(0xFF200901);
        const Color surface = Color(0xFF120606);
        const Color accent = Color(0xFFFF7F2A);
        const Color textPrimary = Color(0xFFFFDFC9);
        const Color textSecondary = Color(0xFFE9A56F);
        const Color trackInactive = Color(0xFF5A2508);

        if (_isDesktopPlatform()) {
          return _DesktopPlayerScreen(
            controller: controller,
            song: song,
            nowPlaying: nowPlaying,
            tapFeedbackController: _tapFeedbackController,
            likeFeedbackController: _likeFeedbackController,
            showPauseGlyph: _showPauseGlyph,
            onSaveSong: _handleSaveAction,
            onDownloadSong: _handleDownloadAction,
            onAlbumArtDoubleTap: _handleAlbumArtDoubleTap,
            onAlbumArtTap: _handleAlbumArtTap,
            onDislikeAction: _handleDislikeAction,
            onTriggerPlaybackFeedback: _triggerPlaybackFeedback,
            onTriggerLikeFeedback: _triggerLikeFeedback,
            onShowQueueSheet: _showQueueSheet,
            backgroundTop: backgroundTop,
            backgroundBottom: backgroundBottom,
            surface: surface,
            accent: accent,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            trackInactive: trackInactive,
          );
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanEnd: _handlePlayerPanEnd,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[backgroundTop, backgroundBottom],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double layoutScale = (constraints.maxHeight / 780)
                        .clamp(0.68, 1.0);
                    double scale(double value, {double? min, double? max}) {
                      final double scaled = value * layoutScale;
                      return scaled.clamp(
                        min ?? double.negativeInfinity,
                        max ?? double.infinity,
                      );
                    }

                    final double horizontalPadding = constraints.maxWidth < 360
                        ? 12
                        : 16;
                    final double artSize = math.min(
                      constraints.maxWidth - (horizontalPadding * 2),
                      math.min(
                        scale(328, min: 220, max: 328),
                        constraints.maxHeight * 0.38,
                      ),
                    );

                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        scale(8, min: 6, max: 8),
                        horizontalPadding,
                        scale(20, min: 16, max: 28),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                ),
                                color: accent,
                                iconSize: scale(28, min: 24, max: 28),
                              ),
                              Expanded(
                                child: Text(
                                  'NOW PLAYING',
                                  textAlign: TextAlign.center,
                                  style: _musixBodyTextStyle(
                                    color: accent,
                                    fontSize: scale(17, min: 14, max: 17),
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: scale(1.6, min: 1.1),
                                  ),
                                ),
                              ),
                              _PlayerHeaderOverflowMenu(
                                song: song,
                                controller: controller,
                                color: accent,
                                onSaveSong: () => _handleSaveAction(song),
                                onDownloadSong: () =>
                                    _handleDownloadAction(song),
                                transparentTriggerStyle: true,
                              ),
                            ],
                          ),
                          Spacer(flex: layoutScale < 0.8 ? 1 : 2),
                          Center(
                            child: RepaintBoundary(
                              child: SizedBox(
                                width: artSize,
                                height: artSize,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _handleAlbumArtTap,
                                  onDoubleTap: () =>
                                      _handleAlbumArtDoubleTap(song),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: surface,
                                      borderRadius: BorderRadius.circular(
                                        scale(34, min: 24, max: 34),
                                      ),
                                      boxShadow: <BoxShadow>[
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.42,
                                          ),
                                          blurRadius: scale(
                                            32,
                                            min: 18,
                                            max: 32,
                                          ),
                                          offset: Offset(
                                            0,
                                            scale(18, min: 12, max: 18),
                                          ),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        scale(34, min: 24, max: 34),
                                      ),
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 260,
                                        ),
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeInCubic,
                                        child: Stack(
                                          key: ValueKey<String>(
                                            '${song.id}|${song.artworkUrl ?? ''}',
                                          ),
                                          fit: StackFit.expand,
                                          children: <Widget>[
                                            if (song.artworkUrl != null &&
                                                song.artworkUrl!
                                                    .trim()
                                                    .isNotEmpty)
                                              _CachedArtworkImage(
                                                imageUrl: song.artworkUrl!,
                                                dimension: artSize,
                                                placeholder:
                                                    const _PlayerArtFallback(),
                                                errorWidget:
                                                    const _PlayerArtFallback(),
                                              )
                                            else
                                              const _PlayerArtFallback(),
                                            IgnorePointer(
                                              child:
                                                  _PlayerArtInteractionOverlay(
                                                    tapController:
                                                        _tapFeedbackController,
                                                    likeController:
                                                        _likeFeedbackController,
                                                    showPauseGlyph:
                                                        _showPauseGlyph,
                                                    isLiked: song.isLiked,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Spacer(flex: layoutScale < 0.8 ? 1 : 2),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      song.title,
                                      textAlign: TextAlign.left,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: _musixHeadingTextStyle(
                                        color: _kTextPrimary,
                                        fontSize: scale(30, min: 30, max: 38),
                                        fontWeight: FontWeight.w600,
                                        height: 0.92,
                                      ),
                                    ),
                                    SizedBox(height: scale(8, min: 6, max: 10)),
                                    Text(
                                      song.artist,
                                      textAlign: TextAlign.left,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _musixBodyTextStyle(
                                        color: _kTextSecondary,
                                        fontSize: scale(17, min: 14, max: 17),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: scale(12, min: 8, max: 14)),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: <Widget>[
                                  IconButton(
                                    onPressed: () async {
                                      if (!song.isLiked) {
                                        await _triggerLikeFeedback();
                                      }
                                      await controller.likeSong(song.id);
                                    },
                                    icon: Icon(
                                      song.isLiked
                                          ? Icons.thumb_up_rounded
                                          : Icons.thumb_up_outlined,
                                      color: accent,
                                      size: scale(30, min: 24, max: 30),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    splashRadius: scale(24, min: 20, max: 24),
                                  ),
                                  SizedBox(width: scale(2, min: 0, max: 4)),
                                  IconButton(
                                    onPressed: () => _handleDislikeAction(song),
                                    icon: Icon(
                                      song.isDisliked
                                          ? Icons.thumb_down_rounded
                                          : Icons.thumb_down_outlined,
                                      color: song.isDisliked
                                          ? Colors.redAccent
                                          : accent,
                                      size: scale(30, min: 24, max: 30),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    splashRadius: scale(24, min: 20, max: 24),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: scale(22, min: 16, max: 24)),
                          ValueListenableBuilder<PlaybackProgressState>(
                            valueListenable: controller.playbackProgressState,
                            builder:
                                (
                                  BuildContext context,
                                  PlaybackProgressState progress,
                                  Widget? child,
                                ) {
                                  final Duration position = nowPlaying.isLoading
                                      ? Duration.zero
                                      : progress.position;
                                  final Duration duration =
                                      progress.duration == Duration.zero
                                      ? song.duration
                                      : progress.duration;
                                  final double sliderMax = math.max(
                                    duration.inMilliseconds.toDouble(),
                                    1,
                                  );
                                  final double sliderValue = position
                                      .inMilliseconds
                                      .clamp(0, sliderMax.toInt())
                                      .toDouble();
                                  final bool showPauseIcon =
                                      progress.isPlaying &&
                                      !nowPlaying.isLoading;

                                  return _PlayerProgressAndControls(
                                    layoutScale: layoutScale,
                                    accent: accent,
                                    textPrimary: textPrimary,
                                    trackInactive: trackInactive,
                                    sliderValue: sliderValue,
                                    sliderMax: sliderMax,
                                    position: position,
                                    duration: duration,
                                    isPlayerLoading: nowPlaying.isLoading,
                                    isShuffleEnabled:
                                        nowPlaying.isShuffleEnabled,
                                    repeatMode: nowPlaying.repeatMode,
                                    onSeek: controller.seek,
                                    onToggleShuffle: controller.toggleShuffle,
                                    onPrevious: controller.previousTrack,
                                    onTogglePlayback: () async {
                                      await _triggerPlaybackFeedback();
                                      unawaited(controller.togglePlayback());
                                    },
                                    onNext: controller.nextTrack,
                                    onCycleRepeatMode:
                                        controller.cycleRepeatMode,
                                    onShowQueue: _showQueueSheet,
                                    showPauseIcon: showPauseIcon,
                                  );
                                },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayerHeaderActionButton extends StatelessWidget {
  const _PlayerHeaderActionButton({
    required this.icon,
    required this.semanticLabel,
    required this.color,
    required this.onPressed,
    this.child,
    this.transparentStyle = false,
  });

  final IconData icon;
  final String semanticLabel;
  final Color color;
  final VoidCallback? onPressed;
  final Widget? child;
  final bool transparentStyle;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final bool useAndroidStyle =
        defaultTargetPlatform == TargetPlatform.android;
    final bool useTransparentStyle = transparentStyle;
    final Color backgroundColor = useTransparentStyle
        ? Colors.transparent
        : useAndroidStyle
        ? color.withValues(alpha: enabled ? 0.16 : 0.08)
        : enabled
        ? const Color(0xFF25110B)
        : const Color(0xFF25110B).withValues(alpha: 0.55);
    final Color borderColor = useTransparentStyle
        ? Colors.transparent
        : useAndroidStyle
        ? color.withValues(alpha: enabled ? 0.34 : 0.16)
        : enabled
        ? const Color(0xFF5B2D14)
        : const Color(0xFF5B2D14).withValues(alpha: 0.55);

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
              boxShadow: useTransparentStyle
                  ? null
                  : useAndroidStyle
                  ? <BoxShadow>[
                      BoxShadow(
                        color: color.withValues(alpha: enabled ? 0.14 : 0.06),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child:
                  child ??
                  Icon(
                    icon,
                    color: enabled ? color : color.withValues(alpha: 0.7),
                    size: 22,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _PlayerHeaderMenuAction { saveToPlaylist, download }

class _PlayerHeaderOverflowMenu extends StatelessWidget {
  const _PlayerHeaderOverflowMenu({
    required this.song,
    required this.controller,
    required this.color,
    required this.onSaveSong,
    required this.onDownloadSong,
    this.transparentTriggerStyle = false,
  });

  final LibrarySong song;
  final MusixController controller;
  final Color color;
  final Future<void> Function() onSaveSong;
  final Future<void> Function() onDownloadSong;
  final bool transparentTriggerStyle;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        final bool isDownloaded = controller.isSongDownloaded(song);
        final bool isDownloading = controller.isSongDownloading(song.id);
        return PopupMenuButton<_PlayerHeaderMenuAction>(
          tooltip: '',
          color: const Color(0xFF25110B),
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.black.withValues(alpha: 0.32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: color.withValues(alpha: 0.24)),
          ),
          position: PopupMenuPosition.under,
          offset: const Offset(0, 8),
          popUpAnimationStyle: AnimationStyle.noAnimation,
          onSelected: (_PlayerHeaderMenuAction action) {
            switch (action) {
              case _PlayerHeaderMenuAction.saveToPlaylist:
                unawaited(onSaveSong());
              case _PlayerHeaderMenuAction.download:
                unawaited(onDownloadSong());
            }
          },
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<_PlayerHeaderMenuAction>>[
                PopupMenuItem<_PlayerHeaderMenuAction>(
                  value: _PlayerHeaderMenuAction.saveToPlaylist,
                  child: _PlayerHeaderMenuItem(
                    icon: Icons.playlist_add_rounded,
                    label: 'Save to playlist',
                    color: color,
                  ),
                ),
                if (song.isRemote)
                  PopupMenuItem<_PlayerHeaderMenuAction>(
                    value: _PlayerHeaderMenuAction.download,
                    enabled: !isDownloaded && !isDownloading,
                    child: _PlayerHeaderMenuItem(
                      icon: isDownloaded
                          ? Icons.download_done_rounded
                          : Icons.downloading_outlined,
                      label: isDownloaded
                          ? 'Downloaded'
                          : isDownloading
                          ? 'Downloading'
                          : 'Download',
                      color: color,
                      trailing: isDownloading
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: _MusixLoader(
                                color: color,
                                size: 18,
                                strokeWidth: 2,
                              ),
                            )
                          : null,
                    ),
                  ),
              ],
          child: IgnorePointer(
            child: _PlayerHeaderActionButton(
              icon: Icons.more_horiz_rounded,
              semanticLabel: isDownloading
                  ? 'Downloading song'
                  : 'More actions',
              color: color,
              onPressed: () {},
              transparentStyle: transparentTriggerStyle,
              child: isDownloading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: _MusixLoader(
                        color: color,
                        size: 20,
                        strokeWidth: 2.2,
                      ),
                    )
                  : Icon(Icons.more_horiz_rounded, color: color, size: 22),
            ),
          ),
        );
      },
    );
  }
}

class _PlayerHeaderMenuItem extends StatelessWidget {
  const _PlayerHeaderMenuItem({
    required this.icon,
    required this.label,
    required this.color,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFFFFDFC9),
          fontWeight: FontWeight.w600,
        ) ??
        const TextStyle(color: Color(0xFFFFDFC9), fontWeight: FontWeight.w600);

    return Row(
      children: <Widget>[
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: baseStyle)),
        if (trailing != null) ...<Widget>[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class _DesktopPlayerScreen extends StatelessWidget {
  const _DesktopPlayerScreen({
    required this.controller,
    required this.song,
    required this.nowPlaying,
    required this.tapFeedbackController,
    required this.likeFeedbackController,
    required this.showPauseGlyph,
    required this.onSaveSong,
    required this.onDownloadSong,
    required this.onAlbumArtDoubleTap,
    required this.onAlbumArtTap,
    required this.onDislikeAction,
    required this.onTriggerPlaybackFeedback,
    required this.onTriggerLikeFeedback,
    required this.onShowQueueSheet,
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.surface,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.trackInactive,
  });

  final MusixController controller;
  final LibrarySong song;
  final NowPlayingState nowPlaying;
  final AnimationController tapFeedbackController;
  final AnimationController likeFeedbackController;
  final bool showPauseGlyph;
  final Future<void> Function(LibrarySong song) onSaveSong;
  final Future<void> Function(LibrarySong song) onDownloadSong;
  final Future<void> Function(LibrarySong song) onAlbumArtDoubleTap;
  final Future<void> Function() onAlbumArtTap;
  final Future<void> Function(LibrarySong song) onDislikeAction;
  final Future<void> Function() onTriggerPlaybackFeedback;
  final Future<void> Function() onTriggerLikeFeedback;
  final Future<void> Function() onShowQueueSheet;
  final Color backgroundTop;
  final Color backgroundBottom;
  final Color surface;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Color trackInactive;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[backgroundTop, backgroundBottom],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double queueWidth = (constraints.maxWidth * 0.32).clamp(
                  320.0,
                  430.0,
                );
                final double leftPanelWidth =
                    constraints.maxWidth - queueWidth - 18;
                final bool compactDesktop = leftPanelWidth < 980;
                final double artworkLayoutScale = (leftPanelWidth / 980).clamp(
                  0.72,
                  1.0,
                );

                final Widget mainPanel = _DesktopPlayerArtworkPanel(
                  controller: controller,
                  song: song,
                  nowPlaying: nowPlaying,
                  tapFeedbackController: tapFeedbackController,
                  likeFeedbackController: likeFeedbackController,
                  showPauseGlyph: showPauseGlyph,
                  accent: accent,
                  textPrimary: textPrimary,
                  textSecondary: textSecondary,
                  surface: surface,
                  onAlbumArtTap: onAlbumArtTap,
                  onAlbumArtDoubleTap: onAlbumArtDoubleTap,
                  onSaveSong: onSaveSong,
                  onDownloadSong: onDownloadSong,
                  onDislikeAction: onDislikeAction,
                  onTriggerLikeFeedback: onTriggerLikeFeedback,
                  onShowQueueSheet: onShowQueueSheet,
                  onTriggerPlaybackFeedback: onTriggerPlaybackFeedback,
                  trackInactive: trackInactive,
                  layoutScale: artworkLayoutScale,
                );

                final Widget queuePanel = _DesktopPlayerQueuePanel(
                  controller: controller,
                  accent: accent,
                  textPrimary: textPrimary,
                  textSecondary: textSecondary,
                  onShowQueueSheet: onShowQueueSheet,
                  compact: compactDesktop,
                );

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: mainPanel),
                    const SizedBox(width: 18),
                    SizedBox(width: queueWidth, child: queuePanel),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopPlayerArtworkPanel extends StatelessWidget {
  const _DesktopPlayerArtworkPanel({
    required this.controller,
    required this.song,
    required this.nowPlaying,
    required this.tapFeedbackController,
    required this.likeFeedbackController,
    required this.showPauseGlyph,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.surface,
    required this.onAlbumArtTap,
    required this.onAlbumArtDoubleTap,
    required this.onSaveSong,
    required this.onDownloadSong,
    required this.onDislikeAction,
    required this.onTriggerLikeFeedback,
    required this.onShowQueueSheet,
    required this.onTriggerPlaybackFeedback,
    required this.trackInactive,
    required this.layoutScale,
  });

  final MusixController controller;
  final LibrarySong song;
  final NowPlayingState nowPlaying;
  final AnimationController tapFeedbackController;
  final AnimationController likeFeedbackController;
  final bool showPauseGlyph;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Color surface;
  final Future<void> Function() onAlbumArtTap;
  final Future<void> Function(LibrarySong song) onAlbumArtDoubleTap;
  final Future<void> Function(LibrarySong song) onSaveSong;
  final Future<void> Function(LibrarySong song) onDownloadSong;
  final Future<void> Function(LibrarySong song) onDislikeAction;
  final Future<void> Function() onTriggerLikeFeedback;
  final Future<void> Function() onShowQueueSheet;
  final Future<void> Function() onTriggerPlaybackFeedback;
  final Color trackInactive;
  final double layoutScale;

  double _scale(double value, {double? min, double? max}) {
    final double scaled = value * layoutScale;
    return scaled.clamp(min ?? double.negativeInfinity, max ?? double.infinity);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(_scale(22, min: 18, max: 22)),
      decoration: BoxDecoration(
        color: const Color(0xFF1A0D09).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: const Color(0xFF342018)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.keyboard_arrow_down),
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'NOW PLAYING',
                  textAlign: TextAlign.center,
                  style: _musixBodyTextStyle(
                    color: accent,
                    fontWeight: FontWeight.w600,
                    letterSpacing: _scale(1.8, min: 1.2, max: 1.8),
                    fontSize: _scale(14, min: 12, max: 14),
                  ),
                ),
              ),
              _PlayerHeaderOverflowMenu(
                song: song,
                controller: controller,
                color: accent,
                onSaveSong: () => onSaveSong(song),
                onDownloadSong: () => onDownloadSong(song),
              ),
            ],
          ),
          SizedBox(height: _scale(18, min: 14, max: 18)),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: _scale(520, min: 360, max: 520),
                  maxHeight: _scale(520, min: 360, max: 520),
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onAlbumArtTap,
                    onDoubleTap: () => onAlbumArtDoubleTap(song),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(
                          _scale(38, min: 28, max: 38),
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.38),
                            blurRadius: _scale(34, min: 22, max: 34),
                            offset: Offset(0, _scale(24, min: 16, max: 24)),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          _scale(38, min: 28, max: 38),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: Stack(
                            key: ValueKey<String>(
                              '${song.id}|${song.artworkUrl ?? ''}',
                            ),
                            fit: StackFit.expand,
                            children: <Widget>[
                              if (song.artworkUrl != null &&
                                  song.artworkUrl!.trim().isNotEmpty)
                                _CachedArtworkImage(
                                  imageUrl: song.artworkUrl!,
                                  dimension: 520,
                                  placeholder: const _PlayerArtFallback(),
                                  errorWidget: const _PlayerArtFallback(),
                                )
                              else
                                const _PlayerArtFallback(),
                              IgnorePointer(
                                child: _PlayerArtInteractionOverlay(
                                  tapController: tapFeedbackController,
                                  likeController: likeFeedbackController,
                                  showPauseGlyph: showPauseGlyph,
                                  isLiked: song.isLiked,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: _scale(40, min: 40, max: 60)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _musixHeadingTextStyle(
                        color: _kTextPrimary,
                        fontSize: _scale(40, min: 30, max: 40),
                        fontWeight: FontWeight.w600,
                        height: 0.94,
                      ),
                    ),
                    SizedBox(height: _scale(8, min: 6, max: 8)),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _musixBodyTextStyle(
                        color: _kTextSecondary,
                        fontSize: _scale(16, min: 14, max: 16),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: _scale(16, min: 10, max: 16)),
              Padding(
                padding: EdgeInsets.only(bottom: _scale(6, min: 2, max: 6)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      onPressed: () async {
                        if (!song.isLiked) {
                          await onTriggerLikeFeedback();
                        }
                        await controller.likeSong(song.id);
                      },
                      icon: Icon(
                        song.isLiked
                            ? Icons.thumb_up_rounded
                            : Icons.thumb_up_outlined,
                        color: accent,
                        size: _scale(28, min: 24, max: 28),
                      ),
                    ),
                    SizedBox(width: _scale(4, min: 2, max: 4)),
                    IconButton(
                      onPressed: () => onDislikeAction(song),
                      icon: Icon(
                        song.isDisliked
                            ? Icons.thumb_down_rounded
                            : Icons.thumb_down_outlined,
                        color: song.isDisliked ? Colors.redAccent : accent,
                        size: _scale(28, min: 24, max: 28),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: _scale(18, min: 14, max: 18)),
          ValueListenableBuilder<PlaybackProgressState>(
            valueListenable: controller.playbackProgressState,
            builder:
                (
                  BuildContext context,
                  PlaybackProgressState progress,
                  Widget? child,
                ) {
                  final Duration position = nowPlaying.isLoading
                      ? Duration.zero
                      : progress.position;
                  final Duration duration = progress.duration == Duration.zero
                      ? song.duration
                      : progress.duration;
                  final double sliderMax = math.max(
                    duration.inMilliseconds.toDouble(),
                    1,
                  );
                  final double sliderValue = position.inMilliseconds
                      .clamp(0, sliderMax.toInt())
                      .toDouble();
                  final bool showPauseIcon =
                      progress.isPlaying && !nowPlaying.isLoading;

                  return _PlayerProgressAndControls(
                    layoutScale: layoutScale,
                    accent: accent,
                    textPrimary: textPrimary,
                    trackInactive: trackInactive,
                    sliderValue: sliderValue,
                    sliderMax: sliderMax,
                    position: position,
                    duration: duration,
                    isPlayerLoading: nowPlaying.isLoading,
                    isShuffleEnabled: nowPlaying.isShuffleEnabled,
                    repeatMode: nowPlaying.repeatMode,
                    onSeek: controller.seek,
                    onToggleShuffle: controller.toggleShuffle,
                    onPrevious: controller.previousTrack,
                    onTogglePlayback: () async {
                      await onTriggerPlaybackFeedback();
                      unawaited(controller.togglePlayback());
                    },
                    onNext: controller.nextTrack,
                    onCycleRepeatMode: controller.cycleRepeatMode,
                    showQueueHandle: false,
                    showPauseIcon: showPauseIcon,
                  );
                },
          ),
          SizedBox(height: _scale(20, min: 14, max: 20)),
        ],
      ),
    );
  }
}

class _VisibleQueueSong {
  const _VisibleQueueSong({required this.queueIndex, required this.song});

  final int queueIndex;
  final LibrarySong song;
}

List<_VisibleQueueSong> _visibleQueueSongs(MusixController controller) {
  final List<LibrarySong> queue = controller.queueSongs;
  final List<_VisibleQueueSong> result = <_VisibleQueueSong>[];
  for (int index = 0; index < queue.length; index += 1) {
    final LibrarySong song = queue[index];
    if (!controller.shouldShowSongOutsideSearch(song)) {
      continue;
    }
    result.add(_VisibleQueueSong(queueIndex: index, song: song));
  }
  return result;
}

class _DesktopPlayerQueuePanel extends StatefulWidget {
  const _DesktopPlayerQueuePanel({
    required this.controller,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.onShowQueueSheet,
    required this.compact,
  });

  final MusixController controller;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Future<void> Function() onShowQueueSheet;
  final bool compact;

  @override
  State<_DesktopPlayerQueuePanel> createState() =>
      _DesktopPlayerQueuePanelState();
}

class _DesktopPlayerQueuePanelState extends State<_DesktopPlayerQueuePanel> {
  static const double _queueItemExtentEstimate = 86;

  final ScrollController _scrollController = ScrollController();
  int? _lastCenteredQueueIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleCenterActiveSong() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final List<_VisibleQueueSong> songs = _visibleQueueSongs(
        widget.controller,
      );
      if (songs.isEmpty) {
        return;
      }
      final int activeIndex = songs.indexWhere(
        (_VisibleQueueSong item) =>
            item.queueIndex == widget.controller.visibleQueueIndex,
      );
      if (activeIndex < 0) {
        return;
      }
      final ScrollPosition position = _scrollController.position;
      final double viewport = position.viewportDimension;
      final double rawOffset =
          (activeIndex * _queueItemExtentEstimate) -
          ((viewport - _queueItemExtentEstimate) / 2);
      final double targetOffset = rawOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      final bool shouldAnimate =
          _lastCenteredQueueIndex != null &&
          _lastCenteredQueueIndex != widget.controller.visibleQueueIndex;
      _lastCenteredQueueIndex = widget.controller.visibleQueueIndex;
      if (shouldAnimate) {
        unawaited(
          _scrollController.animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
        return;
      }
      _scrollController.jumpTo(targetOffset);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final List<_VisibleQueueSong> songs = _visibleQueueSongs(
          widget.controller,
        );
        final bool loading = widget.controller.smartQueueLoading;
        final int activeQueueIndex = widget.controller.visibleQueueIndex;
        if (songs.isNotEmpty && _lastCenteredQueueIndex != activeQueueIndex) {
          _scheduleCenterActiveSong();
        }
        return Container(
          padding: EdgeInsets.all(widget.compact ? 18 : 22),
          decoration: BoxDecoration(
            color: const Color(0xFF1A0D09).withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: const Color(0xFF342018)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _DesktopPanelTitle(eyebrow: 'QUEUE', centered: true),
              const SizedBox(height: 14),
              if (loading)
                Row(
                  children: <Widget>[
                    const RepaintBoundary(
                      child: _MusixLoader(
                        color: _kAccent,
                        size: 16,
                        strokeWidth: 2.2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Loading related songs...',
                      style: _musixBodyTextStyle(
                        color: widget.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              if (songs.isEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  'Queue is empty. Start playback to generate smart suggestions.',
                  style: _musixBodyTextStyle(
                    color: widget.textSecondary,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ] else
                Expanded(
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount: songs.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (BuildContext context, int index) {
                      final _VisibleQueueSong queuedItem = songs[index];
                      final LibrarySong queuedSong = queuedItem.song;
                      final bool active =
                          widget.controller.visibleQueueIndex ==
                          queuedItem.queueIndex;
                      return Material(
                        color: active
                            ? widget.accent.withValues(alpha: 0.14)
                            : const Color(0xFF23100C),
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => widget.controller.jumpToQueue(
                            queuedItem.queueIndex,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            child: Row(
                              children: <Widget>[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: SizedBox(
                                    width: 56,
                                    height: 56,
                                    child:
                                        queuedSong.artworkUrl != null &&
                                            queuedSong.artworkUrl!
                                                .trim()
                                                .isNotEmpty
                                        ? _CachedArtworkImage(
                                            imageUrl: queuedSong.artworkUrl!,
                                            dimension: 56,
                                            placeholder:
                                                const _PlayerArtFallback(),
                                            errorWidget:
                                                const _PlayerArtFallback(),
                                          )
                                        : const _PlayerArtFallback(),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        queuedSong.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _musixBodyTextStyle(
                                          color: _kTextPrimary.withValues(
                                            alpha: 0.9,
                                          ),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _songArtistLabel(queuedSong),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: _musixBodyTextStyle(
                                          color: active
                                              ? widget.accent
                                              : _kTextSecondary.withValues(
                                                  alpha: 0.75,
                                                ),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => widget.controller
                                      .removeFromQueue(queuedItem.queueIndex),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  color: widget.textSecondary.withValues(
                                    alpha: 0.82,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PlayerProgressAndControls extends StatelessWidget {
  const _PlayerProgressAndControls({
    required this.layoutScale,
    required this.accent,
    required this.textPrimary,
    required this.trackInactive,
    required this.sliderValue,
    required this.sliderMax,
    required this.position,
    required this.duration,
    required this.isPlayerLoading,
    required this.isShuffleEnabled,
    required this.repeatMode,
    required this.onSeek,
    required this.onToggleShuffle,
    required this.onPrevious,
    required this.onTogglePlayback,
    required this.onNext,
    required this.onCycleRepeatMode,
    this.onShowQueue,
    this.showQueueHandle = true,
    required this.showPauseIcon,
  });

  final double layoutScale;
  final Color accent;
  final Color textPrimary;
  final Color trackInactive;
  final double sliderValue;
  final double sliderMax;
  final Duration position;
  final Duration duration;
  final bool isPlayerLoading;
  final bool isShuffleEnabled;
  final PlaylistMode repeatMode;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onToggleShuffle;
  final VoidCallback onPrevious;
  final VoidCallback onTogglePlayback;
  final VoidCallback onNext;
  final VoidCallback onCycleRepeatMode;
  final VoidCallback? onShowQueue;
  final bool showQueueHandle;
  final bool showPauseIcon;

  double _scale(double value, {double? min, double? max}) {
    final double scaled = value * layoutScale;
    return scaled.clamp(min ?? double.negativeInfinity, max ?? double.infinity);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IgnorePointer(
          ignoring: isPlayerLoading,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: _scale(6, min: 4, max: 6),
              activeTrackColor: accent,
              inactiveTrackColor: trackInactive,
              thumbColor: accent,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
            ),
            child: Slider(
              value: sliderValue,
              min: 0,
              max: sliderMax,
              onChanged: (double value) {
                onSeek(Duration(milliseconds: value.round()));
              },
            ),
          ),
        ),
        SizedBox(height: _scale(10, min: 6, max: 15)),
        Row(
          children: <Widget>[
            Text(
              _formatClock(position),
              style: _musixBodyTextStyle(
                color: textPrimary.withValues(alpha: 0.86),
                fontSize: _scale(14, min: 12, max: 14),
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              _formatClock(duration),
              style: _musixBodyTextStyle(
                color: textPrimary.withValues(alpha: 0.86),
                fontSize: _scale(14, min: 12, max: 14),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        SizedBox(height: _scale(22, min: 14, max: 22)),
        _PlayerTransportControls(
          layoutScale: layoutScale,
          accent: accent,
          textPrimary: textPrimary,
          isPlayerLoading: isPlayerLoading,
          isShuffleEnabled: isShuffleEnabled,
          repeatMode: repeatMode,
          showPauseIcon: showPauseIcon,
          onToggleShuffle: onToggleShuffle,
          onPrevious: onPrevious,
          onTogglePlayback: onTogglePlayback,
          onNext: onNext,
          onCycleRepeatMode: onCycleRepeatMode,
        ),
        if (showQueueHandle && onShowQueue != null) ...<Widget>[
          SizedBox(height: _scale(10, min: 6, max: 20)),
          Center(
            child: IconButton(
              onPressed: onShowQueue,
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
              color: textPrimary.withValues(alpha: 0.3),
              iconSize: _scale(34, min: 28, max: 34),
            ),
          ),
        ],
      ],
    );
  }
}

class _PlayerTransportControls extends StatelessWidget {
  const _PlayerTransportControls({
    required this.layoutScale,
    required this.accent,
    required this.textPrimary,
    required this.isPlayerLoading,
    required this.isShuffleEnabled,
    required this.repeatMode,
    required this.showPauseIcon,
    required this.onToggleShuffle,
    required this.onPrevious,
    required this.onTogglePlayback,
    required this.onNext,
    required this.onCycleRepeatMode,
    this.inactiveColor,
    this.iconButtonSize = 48,
    this.smallIconSize = 28,
    this.skipIconSize = 34,
    this.playButtonSize = 70,
    this.useCircularPlayButton = false,
    this.playIconSize = 42,
    this.pauseIconSize = 36,
    this.loadingSize = 25,
    this.loadingStrokeWidth = 3.2,
    this.shadowBlur = 28,
  });

  final double layoutScale;
  final Color accent;
  final Color textPrimary;
  final Color? inactiveColor;
  final bool isPlayerLoading;
  final bool isShuffleEnabled;
  final PlaylistMode repeatMode;
  final bool showPauseIcon;
  final VoidCallback onToggleShuffle;
  final VoidCallback onPrevious;
  final VoidCallback onTogglePlayback;
  final VoidCallback onNext;
  final VoidCallback onCycleRepeatMode;
  final double iconButtonSize;
  final double smallIconSize;
  final double skipIconSize;
  final double playButtonSize;
  final bool useCircularPlayButton;
  final double playIconSize;
  final double pauseIconSize;
  final double loadingSize;
  final double loadingStrokeWidth;
  final double shadowBlur;

  double _scale(double value, {double? min, double? max}) {
    final double scaled = value * layoutScale;
    return scaled.clamp(min ?? double.negativeInfinity, max ?? double.infinity);
  }

  Widget _buildTransportIcon() {
    if (isPlayerLoading) {
      return SizedBox(
        width: _scale(loadingSize, min: 16, max: loadingSize),
        height: _scale(loadingSize, min: 16, max: loadingSize),
        child: _MusixLoader(
          color: Colors.black,
          size: _scale(loadingSize, min: 16, max: loadingSize),
          strokeWidth: loadingStrokeWidth,
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        );
      },
      child: Icon(
        showPauseIcon ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey<bool>(showPauseIcon),
        size: showPauseIcon
            ? _scale(pauseIconSize, min: 20, max: pauseIconSize)
            : _scale(playIconSize, min: 22, max: playIconSize),
        color: Colors.black,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color effectiveInactive =
        inactiveColor ?? textPrimary.withValues(alpha: 0.6);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        _PlayerIconButton(
          icon: Icons.shuffle_rounded,
          onPressed: onToggleShuffle,
          color: isShuffleEnabled ? accent : effectiveInactive,
          size: _scale(smallIconSize, min: 20, max: smallIconSize),
          buttonSize: _scale(iconButtonSize, min: 28, max: iconButtonSize),
        ),
        _PlayerIconButton(
          icon: Icons.skip_previous_rounded,
          onPressed: onPrevious,
          color: textPrimary,
          size: _scale(skipIconSize, min: 22, max: skipIconSize),
          buttonSize: _scale(iconButtonSize, min: 28, max: iconButtonSize),
        ),
        GestureDetector(
          onTap: onTogglePlayback,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: _scale(playButtonSize, min: 42, max: playButtonSize),
            height: _scale(playButtonSize, min: 42, max: playButtonSize),
            decoration: BoxDecoration(
              shape: useCircularPlayButton
                  ? BoxShape.circle
                  : BoxShape.rectangle,
              borderRadius: useCircularPlayButton
                  ? null
                  : BorderRadius.circular(
                      _scale(playButtonSize * 0.34, min: 14, max: 28),
                    ),
              color: accent,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: accent.withValues(alpha: 0.38),
                  blurRadius: _scale(shadowBlur, min: 0, max: shadowBlur),
                  spreadRadius: shadowBlur <= 0 ? 0 : 1,
                ),
              ],
            ),
            child: Center(child: _buildTransportIcon()),
          ),
        ),
        _PlayerIconButton(
          icon: Icons.skip_next_rounded,
          onPressed: onNext,
          color: textPrimary,
          size: _scale(skipIconSize, min: 22, max: skipIconSize),
          buttonSize: _scale(iconButtonSize, min: 28, max: iconButtonSize),
        ),
        _PlayerIconButton(
          icon: _repeatIcon(repeatMode),
          onPressed: onCycleRepeatMode,
          color: repeatMode == PlaylistMode.none ? effectiveInactive : accent,
          size: _scale(smallIconSize, min: 20, max: smallIconSize),
          buttonSize: _scale(iconButtonSize, min: 28, max: iconButtonSize),
        ),
      ],
    );
  }
}

class _PlayerArtFallback extends StatelessWidget {
  const _PlayerArtFallback();

  @override
  Widget build(BuildContext context) {
    return const _ArtworkFallbackSurface(
      colors: <Color>[Color(0xFF43100B), Color(0xFF120607), Color(0xFF070508)],
    );
  }
}

class _PlayerArtInteractionOverlay extends StatelessWidget {
  const _PlayerArtInteractionOverlay({
    required this.tapController,
    required this.likeController,
    required this.showPauseGlyph,
    required this.isLiked,
  });

  final AnimationController tapController;
  final AnimationController likeController;
  final bool showPauseGlyph;
  final bool isLiked;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[tapController, likeController]),
      builder: (BuildContext context, _) {
        final double tapValue = tapController.value;
        final double likeValue = likeController.value;
        final double tapIn = Curves.easeOutCubic.transform(
          (tapValue / 0.55).clamp(0.0, 1.0),
        );
        final double tapOut =
            1 -
            Curves.easeInCubic.transform(
              ((tapValue - 0.45) / 0.55).clamp(0.0, 1.0),
            );
        final double tapOpacity = tapIn * tapOut;
        final double badgeScale =
            0.94 + (0.06 * Curves.easeOutCubic.transform(tapValue));
        final double likeFade =
            1 - Curves.easeInCubic.transform(likeValue.clamp(0.0, 1.0));
        final double veilOpacity = tapValue > 0
            ? 0.14 * tapOpacity.clamp(0.0, 1.0)
            : likeValue > 0
            ? 0.12 * likeFade.clamp(0.0, 1.0)
            : 0;
        final double heartScale =
            TweenSequence<double>(<TweenSequenceItem<double>>[
              TweenSequenceItem<double>(
                tween: Tween<double>(
                  begin: 0.72,
                  end: 1.12,
                ).chain(CurveTween(curve: Curves.easeOutBack)),
                weight: 58,
              ),
              TweenSequenceItem<double>(
                tween: Tween<double>(
                  begin: 1.12,
                  end: 1.0,
                ).chain(CurveTween(curve: Curves.easeOutCubic)),
                weight: 42,
              ),
            ]).transform(likeValue.clamp(0.0, 1.0));

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (veilOpacity > 0)
              Opacity(
                opacity: veilOpacity,
                child: const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xFF120907)),
                ),
              ),
            if (tapValue > 0)
              Center(
                child: Opacity(
                  opacity: 0.94 * tapOpacity.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: badgeScale,
                    child: Icon(
                      showPauseGlyph
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: const Color(0xFFFFF2E8),
                      size: showPauseGlyph ? 58 : 68,
                      shadows: const <Shadow>[
                        Shadow(
                          color: Color(0xAA000000),
                          blurRadius: 18,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (likeValue > 0)
              Center(
                child: Opacity(
                  opacity: likeFade.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: heartScale,
                    child: Icon(
                      isLiked || likeValue >= 0.16
                          ? Icons.favorite_rounded
                          : Icons.favorite_border,
                      color: Color.lerp(
                        const Color(0xFFFFF4F1),
                        const Color(0xFFFF786A),
                        Curves.easeOutCubic.transform(
                          (likeValue / 0.35).clamp(0.0, 1.0),
                        ),
                      ),
                      size: 70,
                      shadows: const <Shadow>[
                        Shadow(
                          color: Color(0xAA000000),
                          blurRadius: 18,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    required this.icon,
    required this.onPressed,
    required this.color,
    this.size = 28,
    this.buttonSize,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color color;
  final double size;
  final double? buttonSize;

  @override
  Widget build(BuildContext context) {
    final Widget iconChild = SizedBox(
      width: buttonSize ?? size + 20,
      height: buttonSize ?? size + 20,
      child: Center(
        child: Icon(icon, color: color, size: size),
      ),
    );
    return _ApplePressable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular((buttonSize ?? (size + 20)) / 2),
      child: iconChild,
    );
  }
}

class _PlayerQueueSheet extends StatefulWidget {
  const _PlayerQueueSheet({required this.controller});

  final MusixController controller;

  @override
  State<_PlayerQueueSheet> createState() => _PlayerQueueSheetState();
}

class _PlayerQueueSheetState extends State<_PlayerQueueSheet> {
  static const int _queueBatchSize = 10;
  static const double _queueItemExtentEstimate = 88;

  final ScrollController _scroll = ScrollController();
  final ValueNotifier<bool> _loadingMore = ValueNotifier<bool>(false);
  bool _initialPositioned = false;

  MusixController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureInitialQueueBatch();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _loadingMore.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _centerCurrentQueueSong({bool animated = true}) {
    final List<_VisibleQueueSong> songs = _visibleQueueSongs(controller);
    if (!mounted || !_scroll.hasClients || songs.isEmpty) {
      return;
    }
    final int activeIndex = songs.indexWhere(
      (_VisibleQueueSong item) => item.queueIndex == controller.queueIndex,
    );
    if (activeIndex < 0) {
      return;
    }
    final ScrollPosition position = _scroll.position;
    final double viewport = position.viewportDimension;
    final double rawOffset =
        (activeIndex * _queueItemExtentEstimate) -
        ((viewport - _queueItemExtentEstimate) / 2);
    final double targetOffset = rawOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (animated) {
      unawaited(
        _scroll.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
      return;
    }
    _scroll.jumpTo(targetOffset);
  }

  Future<void> _onScroll() async {
    if (_loadingMore.value || !mounted || !_scroll.hasClients) {
      return;
    }
    if (_scroll.position.extentAfter > 280) {
      return;
    }
    await _loadMoreQueue();
  }

  Future<void> _ensureInitialQueueBatch() async {
    if (!mounted) {
      return;
    }
    while (mounted && _visibleQueueSongs(controller).length < _queueBatchSize) {
      final int before = _visibleQueueSongs(controller).length;
      final int shortfall = _queueBatchSize - before;
      await _loadMoreQueue(batchSize: shortfall);
      final int after = _visibleQueueSongs(controller).length;
      if (after <= before) {
        break;
      }
    }
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialPositioned) {
        return;
      }
      _centerCurrentQueueSong(animated: false);
      _initialPositioned = true;
    });
  }

  Future<void> _loadMoreQueue({int batchSize = _queueBatchSize}) async {
    if (_loadingMore.value || controller.smartQueueLoading) {
      return;
    }
    _loadingMore.value = true;
    try {
      await controller.appendSmartQueue(batchSize: batchSize, force: true);
    } finally {
      _loadingMore.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _loadingMore,
      builder: (BuildContext context, bool loadingMore, Widget? child) {
        final List<_VisibleQueueSong> songs = _visibleQueueSongs(controller);
        final bool hasHiddenQueueSongs =
            songs.length != controller.queueSongs.length;
        const Color sheet = Color(0xFF140807);
        const Color tile = Color(0xFF23100C);
        const Color accent = Color(0xFFFF7F2A);
        const Color textPrimary = Color(0xFFFFDFC9);
        const Color textSecondary = Color(0xFFE9A56F);
        final bool loading = controller.smartQueueLoading || loadingMore;

        return Container(
          height: MediaQuery.sizeOf(context).height * 0.62,
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          decoration: const BoxDecoration(
            color: sheet,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  color: textPrimary.withValues(alpha: 0.92),
                  iconSize: 34,
                ),
              ),
              if (loading) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    const RepaintBoundary(
                      child: _MusixLoader(
                        color: accent,
                        size: 18,
                        strokeWidth: 2.2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Loading related songs...',
                      style: _musixBodyTextStyle(
                        color: textPrimary.withValues(alpha: 0.88),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: songs.isEmpty
                          ? Center(
                              child: Text(
                                'Queue is empty. Start playback to generate smart suggestions.',
                                textAlign: TextAlign.center,
                                style: _musixBodyTextStyle(
                                  color: textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            )
                          : ReorderableListView.builder(
                              scrollController: _scroll,
                              buildDefaultDragHandles: false,
                              proxyDecorator:
                                  (
                                    Widget child,
                                    int index,
                                    Animation<double> animation,
                                  ) {
                                    return AnimatedBuilder(
                                      animation: animation,
                                      builder:
                                          (BuildContext context, Widget? _) {
                                            final double t = Curves.easeOutCubic
                                                .transform(animation.value);
                                            return Transform.scale(
                                              scale: 1 + (t * 0.02),
                                              child: Material(
                                                color: Colors.transparent,
                                                elevation: 12 * t,
                                                borderRadius:
                                                    BorderRadius.circular(22),
                                                child: child,
                                              ),
                                            );
                                          },
                                    );
                                  },
                              onReorderStart: (int index) {
                                HapticFeedback.selectionClick();
                              },
                              onReorderEnd: (int index) {
                                HapticFeedback.selectionClick();
                              },
                              onReorder: (int oldIndex, int newIndex) async {
                                if (hasHiddenQueueSongs) {
                                  return;
                                }
                                if (newIndex > oldIndex) {
                                  newIndex -= 1;
                                }
                                await HapticFeedback.selectionClick();
                                await controller.reorderQueue(
                                  oldIndex,
                                  newIndex,
                                );
                              },
                              itemCount: songs.length,
                              itemBuilder: (BuildContext context, int index) {
                                final _VisibleQueueSong queueItem =
                                    songs[index];
                                final LibrarySong song = queueItem.song;
                                final bool active =
                                    controller.visibleQueueIndex ==
                                    queueItem.queueIndex;

                                return Padding(
                                  key: ValueKey<String>(
                                    'queue-${song.id}-$index',
                                  ),
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Dismissible(
                                    key: ValueKey<String>(
                                      'queue-dismiss-${queueItem.queueIndex}-${song.id}',
                                    ),
                                    direction: DismissDirection.endToStart,
                                    background: const _SwipeActionBackground(
                                      alignment: Alignment.centerRight,
                                      color: Color(0xFF5A1613),
                                      icon: Icons.delete_outline_rounded,
                                      label: 'Remove',
                                    ),
                                    confirmDismiss:
                                        (DismissDirection direction) async {
                                          await HapticFeedback.mediumImpact();
                                          return true;
                                        },
                                    onDismissed:
                                        (DismissDirection direction) async {
                                          final ScaffoldMessengerState
                                          messenger = ScaffoldMessenger.of(
                                            context,
                                          );
                                          await _removeQueueSongWithUndo(
                                            messenger,
                                            controller: controller,
                                            song: song,
                                            queueIndex: queueItem.queueIndex,
                                          );
                                        },
                                    child: Material(
                                      color: active
                                          ? accent.withValues(alpha: 0.14)
                                          : tile,
                                      borderRadius: BorderRadius.circular(22),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(22),
                                        onTap: () async {
                                          unawaited(
                                            HapticFeedback.selectionClick(),
                                          );
                                          await controller.jumpToQueue(
                                            queueItem.queueIndex,
                                          );
                                          if (context.mounted) {
                                            Navigator.of(context).pop();
                                          }
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            12,
                                            10,
                                            12,
                                            10,
                                          ),
                                          child: Row(
                                            children: <Widget>[
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                child: SizedBox(
                                                  width: 56,
                                                  height: 56,
                                                  child:
                                                      song.artworkUrl != null &&
                                                          song.artworkUrl!
                                                              .trim()
                                                              .isNotEmpty
                                                      ? _CachedArtworkImage(
                                                          imageUrl:
                                                              song.artworkUrl!,
                                                          dimension: 56,
                                                          errorWidget:
                                                              const _PlayerArtFallback(),
                                                          placeholder:
                                                              const _PlayerArtFallback(),
                                                        )
                                                      : const _PlayerArtFallback(),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: <Widget>[
                                                    Text(
                                                      song.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style:
                                                          _musixBodyTextStyle(
                                                            color: _kTextPrimary
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                ),
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      _songArtistLabel(song),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: _musixBodyTextStyle(
                                                        color: active
                                                            ? accent
                                                            : _kTextSecondary
                                                                  .withValues(
                                                                    alpha: 0.75,
                                                                  ),
                                                        fontSize: 13,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (!hasHiddenQueueSongs)
                                                ReorderableDelayedDragStartListener(
                                                  index: index,
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          left: 10,
                                                        ),
                                                    child: Icon(
                                                      Icons.drag_handle_rounded,
                                                      color: textSecondary
                                                          .withValues(
                                                            alpha: 0.84,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MusixCollectionSummary extends StatelessWidget {
  const _MusixCollectionSummary({
    required this.leading,
    required this.title,
    required this.lines,
  });

  final Widget leading;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final List<String> visibleLines = lines
        .where((String line) => line.trim().isNotEmpty)
        .toList(growable: false);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _kSurface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: _kSurfaceEdge),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          leading,
          const SizedBox(width: 26),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _musixBodyTextStyle(
                      color: _kTextPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 0.96,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...visibleLines.map(
                    (String line) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _musixBodyTextStyle(
                          color: _kTextSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MusixArtistScreen extends StatefulWidget {
  const _MusixArtistScreen({required this.controller, required this.artist});

  final MusixController controller;
  final ArtistCollection artist;

  @override
  State<_MusixArtistScreen> createState() => _MusixArtistScreenState();
}

class _MusixArtistScreenState extends State<_MusixArtistScreen> {
  static const int _pageSize = 10;

  final ScrollController _scrollController = ScrollController();
  ArtistCollection? _resolvedArtist;
  Object? _loadError;
  Object? _appendError;
  bool _initialLoading = true;
  bool _appendingPage = false;
  bool _hasMoreSongs = true;
  int _requestedSongCount = _pageSize;
  bool _hasUserScrolledForNextPage = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    unawaited(_loadArtist());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    widget.controller.disposeOnlineArtistCollectionSession(
      widget.artist.id,
      artistName: widget.artist.name,
    );
    super.dispose();
  }

  List<LibrarySong> get _songs =>
      _resolvedArtist?.songs ?? const <LibrarySong>[];

  Future<void> _loadArtist() async {
    try {
      final OnlineArtistCollectionPage? resolved = await widget.controller
          .fetchOnlineArtistCollectionPage(
            widget.artist.id,
            artistName: widget.artist.name,
            minimumSongCount: _requestedSongCount,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _resolvedArtist = resolved?.artist;
        _loadError = null;
        _appendError = null;
        _initialLoading = false;
        _appendingPage = false;
        _hasMoreSongs = resolved?.hasMore ?? false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_resolvedArtist == null || _songs.isEmpty) {
          _loadError = error;
        } else {
          _appendError = error;
        }
        _initialLoading = false;
        _appendingPage = false;
      });
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _initialLoading ||
        _appendingPage ||
        !_hasMoreSongs) {
      return;
    }
    final ScrollPosition position = _scrollController.position;
    if (position.userScrollDirection == ScrollDirection.reverse &&
        position.pixels > 0) {
      _hasUserScrolledForNextPage = true;
    }
    if (!_hasUserScrolledForNextPage) {
      return;
    }
    if (position.extentAfter > 280) {
      return;
    }
    unawaited(_appendNextPage());
  }

  Future<void> _appendNextPage() async {
    if (_appendingPage || !_hasMoreSongs) {
      return;
    }
    setState(() {
      _appendingPage = true;
      _appendError = null;
      _requestedSongCount += _pageSize;
    });
    _hasUserScrolledForNextPage = false;
    await _loadArtist();
  }

  List<Widget> _buildSongList() {
    if (_initialLoading) {
      return List<Widget>.generate(
        _pageSize,
        (int index) => const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: _ArtistSongTileSkeleton(),
        ),
      );
    }

    if (_loadError != null && (_resolvedArtist == null || _songs.isEmpty)) {
      return const <Widget>[
        _PersonalizationHintCard(
          message:
              'This artist could not be loaded right now. Please try again later.',
        ),
      ];
    }

    if (_resolvedArtist == null || _songs.isEmpty) {
      return const <Widget>[
        _PersonalizationHintCard(message: 'No songs found for this artist.'),
      ];
    }

    return <Widget>[
      ...List<Widget>.generate(_songs.length, (int index) {
        final LibrarySong song = _songs[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _SongTile(
            song: song,
            controller: widget.controller,
            index: index + 1,
          ),
        );
      }),
      if (_appendingPage)
        ...List<Widget>.generate(
          _pageSize,
          (int index) => const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: _ArtistSongTileSkeleton(),
          ),
        ),
      if (_appendError != null)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: _PersonalizationHintCard(
            message:
                'Could not load more songs right now. Scroll again to retry.',
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ArtistCollection artist = _resolvedArtist ?? widget.artist;

    return _MusixSubscreenScaffold(
      title: artist.name,
      scrollController: _scrollController,
      actions: <Widget>[
        _MusixHeaderActionButton(
          icon: Icons.play_arrow_rounded,
          primary: true,
          onPressed: _resolvedArtist == null || _songs.isEmpty
              ? null
              : () => widget.controller.playArtist(_resolvedArtist!),
        ),
      ],
      child: Column(
        children: <Widget>[
          _MusixCollectionSummary(
            leading: _ResolvedArtistAvatar(
              controller: widget.controller,
              artistName: artist.name,
              seed: artist.id,
              size: 120,
            ),
            title: artist.name,
            lines: <String>[
              if (_initialLoading)
                'Loading songs...'
              else if (_loadError != null)
                'Could not load this artist right now.'
              else if (_resolvedArtist == null || _songs.isEmpty)
                'No songs found for this artist.'
              else if (_hasMoreSongs)
                '${_songs.length} songs loaded'
              else
                '${_songs.length} songs loaded',
            ],
          ),
          const SizedBox(height: 20),
          ..._buildSongList(),
        ],
      ),
    );
  }
}

class _ArtistSongTileSkeleton extends StatelessWidget {
  const _ArtistSongTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const _SongCardSkeleton(index: 1);
  }
}

class _MusixPlaylistScreen extends StatefulWidget {
  const _MusixPlaylistScreen({
    required this.controller,
    required this.title,
    required this.songs,
    this.playlist,
    this.localPlaybackOnly = false,
    this.showLocalImportActions = false,
  });

  final MusixController controller;
  final String title;
  final List<LibrarySong> songs;
  final UserPlaylist? playlist;
  final bool localPlaybackOnly;
  final bool showLocalImportActions;

  @override
  State<_MusixPlaylistScreen> createState() => _MusixPlaylistScreenState();
}

class _MusixPlaylistScreenState extends State<_MusixPlaylistScreen> {
  UserPlaylist? _activePlaylist() {
    final UserPlaylist? playlist = widget.playlist;
    if (playlist == null) {
      return null;
    }
    return widget.controller.playlists.firstWhereOrNull(
          (UserPlaylist item) => item.id == playlist.id,
        ) ??
        playlist;
  }

  bool _isDownloadsCollectionTitle(String title) {
    return title.trim().toLowerCase() == 'downloads';
  }

  bool _isLocalFilesCollectionTitle(String title) {
    return title.trim().toLowerCase() == 'local files';
  }

  @override
  void initState() {
    super.initState();
    _loadCloudSongsIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _MusixPlaylistScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist?.id != widget.playlist?.id) {
      _loadCloudSongsIfNeeded();
    }
  }

  void _loadCloudSongsIfNeeded() {
    final UserPlaylist? playlist = widget.playlist;
    if (playlist == null || playlist.songIdsComplete) {
      return;
    }
    unawaited(widget.controller.loadPlaylistSongsFromCloud(playlist.id));
  }

  List<LibrarySong> _currentSongs() {
    final UserPlaylist? playlist = _activePlaylist();
    if (playlist != null) {
      return widget.controller.songsForPlaylist(playlist);
    }
    if (widget.localPlaybackOnly && _isDownloadsCollectionTitle(widget.title)) {
      return widget.controller.downloadedSongs;
    }
    if (widget.localPlaybackOnly &&
        _isLocalFilesCollectionTitle(widget.title)) {
      return widget.controller.browsableSongs;
    }
    return widget.songs;
  }

  int _expectedSongCount(List<LibrarySong> songs) {
    return _activePlaylist()?.displaySongCount ?? songs.length;
  }

  int _pendingCloudSongs() {
    final UserPlaylist? playlist = _activePlaylist();
    if (playlist == null || !playlist.songIdsComplete) {
      return 0;
    }
    return widget.controller.pendingCloudSongCountForIds(playlist.songIds);
  }

  int _unavailableCloudSongs() {
    final UserPlaylist? playlist = _activePlaylist();
    if (playlist == null || !playlist.songIdsComplete) {
      return 0;
    }
    return widget.controller.unavailableCloudSongCountForIds(playlist.songIds);
  }

  Future<void> _playSongFromList(
    List<LibrarySong> songs,
    LibrarySong tappedSong,
    String label,
  ) async {
    if (widget.localPlaybackOnly) {
      if (tappedSong.isRemote) {
        return;
      }
      final List<LibrarySong> localSongs = songs
          .where((LibrarySong item) => !item.isRemote)
          .toList(growable: false);
      final int startIndex = localSongs.indexWhere(
        (LibrarySong item) => item.id == tappedSong.id,
      );
      if (startIndex >= 0) {
        await widget.controller.playSongs(
          localSongs,
          startIndex: startIndex,
          label: label,
        );
      }
      return;
    }

    final int startIndex = songs.indexWhere(
      (LibrarySong item) => item.id == tappedSong.id,
    );
    if (startIndex >= 0) {
      await widget.controller.playSongs(
        songs,
        startIndex: startIndex,
        label: label,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, _) {
        final UserPlaylist? playlist = _activePlaylist();
        final String title = playlist?.name ?? widget.title;
        final List<LibrarySong> songs = _currentSongs();
        final int expectedSongCount = _expectedSongCount(songs);
        final int pendingCloudSongs = _pendingCloudSongs();
        final int unavailableCloudSongs = _unavailableCloudSongs();
        final bool loadingPlaylistMetadata =
            playlist != null &&
            !playlist.songIdsComplete &&
            widget.controller.isPlaylistSongsLoading(playlist.id) &&
            songs.isEmpty &&
            playlist.displaySongCount > 0;
        final bool loadingHydratedSongs =
            songs.isEmpty && pendingCloudSongs > 0 && expectedSongCount > 0;

        return _MusixSubscreenScaffold(
          title: title,
          actions: <Widget>[
            if (widget.showLocalImportActions &&
                widget.controller.supportsLocalFileImport)
              _MusixHeaderActionButton(
                icon: Icons.folder_open_rounded,
                onPressed: widget.controller.scanning
                    ? null
                    : () => widget.controller.importFolder(),
              ),
            if (widget.showLocalImportActions &&
                widget.controller.supportsLocalFileImport)
              _MusixHeaderActionButton(
                icon: Icons.audio_file_outlined,
                onPressed: widget.controller.scanning
                    ? null
                    : () => widget.controller.importFiles(),
              ),
            if (playlist != null)
              _MusixHeaderActionButton(
                icon: Icons.edit_outlined,
                onPressed: () => _showRenamePlaylistDialog(
                  context,
                  widget.controller,
                  playlist,
                ),
              ),
            if (playlist != null)
              _MusixHeaderActionButton(
                icon: Icons.delete_outline_rounded,
                destructive: true,
                onPressed: () async {
                  final int playlistIndex = widget.controller.playlists
                      .indexWhere(
                        (UserPlaylist item) => item.id == playlist.id,
                      );
                  final UserPlaylist? removed = await widget.controller
                      .removePlaylistLocally(playlist.id);
                  if (removed == null || !context.mounted) {
                    return;
                  }
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                    context,
                  );
                  Navigator.of(context).pop();
                  await WidgetsBinding.instance.endOfFrame;
                  final bool undone = await _showMusixUndoSnackBarWithMessenger(
                    messenger,
                    'Playlist deleted',
                  );
                  if (undone) {
                    await widget.controller.restorePlaylist(
                      removed,
                      index: playlistIndex < 0 ? null : playlistIndex,
                    );
                    return;
                  }
                  await widget.controller.finalizeDeletedPlaylist(removed.id);
                },
              ),
          ],
          child: Column(
            children: <Widget>[
              _MusixCollectionSummary(
                leading: songs.isNotEmpty
                    ? _Artwork(
                        seed: playlist?.id ?? title,
                        title: title,
                        size: 120,
                        imageUrl: songs.first.artworkUrl,
                      )
                    : _Artwork(
                        seed: playlist?.id ?? title,
                        title: title,
                        size: 120,
                        icon: Icons.queue_music_rounded,
                      ),
                title: title,
                lines: <String>[
                  '$expectedSongCount songs',
                  if (pendingCloudSongs > 0)
                    'Loading $pendingCloudSongs more from cloud',
                  if (unavailableCloudSongs > 0)
                    '$unavailableCloudSongs songs only exist on another device',
                ],
              ),
              const SizedBox(height: 20),
              if (widget.showLocalImportActions &&
                  songs.isEmpty &&
                  widget.controller.supportsLocalFileImport)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: _WindowsLocalImportPanel(
                    controller: widget.controller,
                  ),
                ),
              if (loadingPlaylistMetadata || loadingHydratedSongs)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(child: _MusixLoader(color: _kAccent, size: 24)),
                )
              else
                ...songs.asMap().entries.map(
                  (MapEntry<int, LibrarySong> entry) => _SongTile(
                    song: entry.value,
                    controller: widget.controller,
                    index: entry.key + 1,
                    extraPlaylistId: playlist?.id,
                    playlistSongIndex: playlist != null ? entry.key : null,
                    allowDownloadRemoval:
                        playlist == null && _isDownloadsCollectionTitle(title),
                    onTap: () => _playSongFromList(songs, entry.value, title),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeFeedSkeleton extends StatelessWidget {
  const _HomeFeedSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: <Widget>[
        _MusixSectionHeaderSkeleton(),
        SizedBox(height: 8),
        _MusixListSkeleton(count: 4),
        SizedBox(height: 22),
        _MusixSectionHeaderSkeleton(),
        SizedBox(height: 8),
        _MusixListSkeleton(count: 4),
      ],
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    required this.width,
    required this.height,
    this.radius = 12,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          colors: <Color>[
            scheme.surfaceContainerHighest.withValues(alpha: 0.9),
            scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          ],
        ),
      ),
    );
  }
}

class _ApplePressable extends StatefulWidget {
  const _ApplePressable({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;

  @override
  State<_ApplePressable> createState() => _ApplePressableState();
}

class _ApplePressableState extends State<_ApplePressable> {
  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  Future<void> _handleTap() async {
    await HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  Future<void> _handleLongPress() async {
    await HapticFeedback.mediumImpact();
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = widget.child;

    if (!_enabled) {
      return content;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onLongPress: widget.onLongPress == null
            ? null
            : () => unawaited(_handleLongPress()),
        child: ClipRRect(
          borderRadius: widget.borderRadius ?? BorderRadius.zero,
          child: content,
        ),
      ),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader();

  @override
  Widget build(BuildContext context) {
    return const _HomeStyleHeader(
      title: 'LIBRARY',
      leading: _HomeStyleProfileBadge(),
      trailing: _HomeStyleNotificationIcon(),
    );
  }
}

class _LibraryFeatureCard extends StatelessWidget {
  const _LibraryFeatureCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.secondary,
    required this.watermark,
    required this.onTap,
    this.darkText = true,
    this.iconBackgroundColor,
    this.iconColor,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final Color secondary;
  final IconData watermark;
  final VoidCallback onTap;
  final bool darkText;
  final Color? iconBackgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return _ApplePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compactLayout = constraints.maxWidth < 260;

          return Container(
            height: 164,
            padding: EdgeInsets.fromLTRB(
              compactLayout ? 16 : 18,
              16,
              compactLayout ? 16 : 18,
              18,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                colors: <Color>[accent, secondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Stack(
              children: <Widget>[
                if (compactLayout)
                  Positioned(
                    top: 0,
                    left: 0,
                    child: Icon(
                      icon,
                      color:
                          iconColor ??
                          (darkText ? Colors.white : const Color(0xFFFFC99F)),
                      size: 24,
                    ),
                  )
                else
                  Positioned(
                    top: 0,
                    left: 0,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            iconBackgroundColor ??
                            (darkText
                                ? Colors.black.withValues(alpha: 0.3)
                                : Colors.black.withValues(alpha: 0.18)),
                      ),
                      child: Icon(
                        icon,
                        color:
                            iconColor ??
                            (darkText ? Colors.white : const Color(0xFFFFC99F)),
                        size: 24,
                      ),
                    ),
                  ),
                Align(
                  alignment: compactLayout
                      ? Alignment.topCenter
                      : Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: compactLayout ? 4 : 0,
                      right: compactLayout ? 0 : 0,
                    ),
                    child: Icon(
                      watermark,
                      size: compactLayout ? 92 : 114,
                      color: darkText
                          ? Colors.white.withValues(alpha: 0.16)
                          : Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    crossAxisAlignment: compactLayout
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        textAlign: compactLayout
                            ? TextAlign.center
                            : TextAlign.left,
                        style: _musixBodyTextStyle(
                          color: darkText
                              ? Colors.black.withValues(alpha: 0.94)
                              : const Color(0xFFF6E3D2),
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          height: 0.98,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        textAlign: compactLayout
                            ? TextAlign.center
                            : TextAlign.left,
                        style: _musixBodyTextStyle(
                          color: darkText
                              ? Colors.black.withValues(alpha: 0.76)
                              : const Color(0xFFD6B099),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LibraryBlockedCard extends StatelessWidget {
  const _LibraryBlockedCard({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 164,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF29120D), Color(0xFF1A0A08)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF8A2A).withValues(alpha: 0.16),
              ),
              child: Icon(icon, color: const Color(0xFFFFC79F), size: 24),
            ),
          ),
          Positioned(
            right: -18,
            top: -10,
            child: Icon(
              Icons.lock_rounded,
              size: 110,
              color: Colors.white.withValues(alpha: 0.05),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: _musixBodyTextStyle(
                    color: const Color(0xFFF6E3D2),
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    height: 0.98,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: _musixBodyTextStyle(
                    color: const Color(0xFFD6B099),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryEmptyPlaylistCard extends StatelessWidget {
  const _LibraryEmptyPlaylistCard({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: const Color(0xFF2A1209),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.queue_music_rounded,
            color: Color(0xFFFF9C54),
            size: 30,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No playlists yet. Create one and save songs into it.',
              style: _musixBodyTextStyle(
                color: const Color(0xFFF4D7C4),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onCreate,
            style: TextButton.styleFrom(foregroundColor: _kAccent),
            child: Text(
              'Create',
              style: _musixBodyTextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryPlaylistRow extends StatelessWidget {
  const _LibraryPlaylistRow({
    required this.controller,
    required this.title,
    required this.seed,
    required this.songs,
    this.playlist,
    this.subtitle,
    this.forceEnabled = false,
  });

  final MusixController controller;
  final String title;
  final String seed;
  final List<LibrarySong> songs;
  final UserPlaylist? playlist;
  final String? subtitle;
  final bool forceEnabled;

  @override
  Widget build(BuildContext context) {
    final LibrarySong? leadSong = songs.isEmpty ? null : songs.first;
    final bool blocked = controller.isOfflineViewActive && !forceEnabled;

    return _ApplePressable(
      onTap: blocked
          ? null
          : () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => _MusixPlaylistScreen(
                    controller: controller,
                    title: title,
                    songs: songs,
                    playlist: playlist,
                  ),
                ),
              );
            },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: _kSongCardSurface.withValues(alpha: 0.70),
          border: Border.all(color: _kSongCardBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 64,
                height: 64,
                child: leadSong != null
                    ? _Artwork(
                        seed: seed,
                        title: title,
                        size: 64,
                        imageUrl: leadSong.artworkUrl,
                      )
                    : Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: <Color>[
                              Color(0xFF6C2D08),
                              Color(0xFF1B0D05),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: const Icon(
                          Icons.queue_music_rounded,
                          color: Color(0xFFFFD1AD),
                          size: 32,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _musixBodyTextStyle(
                        color: _kSongCardTitle,
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ??
                          'Playlist - ${playlist?.displaySongCount ?? songs.length} Songs',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _musixBodyTextStyle(
                        color: _kSongCardSubtitle,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              blocked ? Icons.cloud_off_rounded : Icons.chevron_right_rounded,
              color: blocked ? const Color(0xFFFF9B54) : _kSongCardMeta,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipeActionBackground extends StatelessWidget {
  const _SwipeActionBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: _musixBodyTextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _removeQueueSongWithUndo(
  ScaffoldMessengerState messenger, {
  required MusixController controller,
  required LibrarySong song,
  required int queueIndex,
}) async {
  final bool wasPlaying = controller.isPlaying;
  final Future<bool> removeFuture = controller.removeFromQueue(queueIndex);
  final Future<bool> undoFuture = _showMusixUndoSnackBarWithMessenger(
    messenger,
    'Removed from queue',
  );
  final bool removed = await removeFuture;
  if (!removed) {
    messenger.removeCurrentSnackBar();
    return;
  }
  final bool undone = await undoFuture;
  if (undone) {
    await controller.insertSongIntoQueueAt(
      song,
      index: queueIndex,
      resumePlaybackWhenQueueWasEmpty: wasPlaying,
    );
  }
}

Future<void> _removePlaylistSongWithUndo(
  ScaffoldMessengerState messenger, {
  required MusixController controller,
  required String playlistId,
  required String songId,
  required int playlistSongIndex,
}) async {
  final Future<int?> removeFuture = controller.removeSongFromPlaylistAt(
    playlistId,
    playlistSongIndex,
  );
  final Future<bool> undoFuture = _showMusixUndoSnackBarWithMessenger(
    messenger,
    'Removed from playlist',
  );
  final int? removedIndex = await removeFuture;
  if (removedIndex == null) {
    messenger.removeCurrentSnackBar();
    return;
  }
  final bool undone = await undoFuture;
  if (undone) {
    await controller.insertSongIntoPlaylistAt(
      playlistId,
      songId,
      index: removedIndex,
    );
    return;
  }
  await controller.finalizeRemovedSongFromPlaylist(playlistId, songId);
}

Future<void> _removeDownloadedSongWithUndo(
  ScaffoldMessengerState messenger, {
  required MusixController controller,
  required LibrarySong song,
}) async {
  final Future<int?> removeFuture = controller.removeDownloadedSong(song);
  final Future<bool> undoFuture = _showMusixUndoSnackBarWithMessenger(
    messenger,
    'Removed downloaded song',
  );
  final int? removedIndex = await removeFuture;
  if (removedIndex == null) {
    messenger.removeCurrentSnackBar();
    return;
  }
  final bool undone = await undoFuture;
  if (undone) {
    await controller.restoreDownloadedSong(song, index: removedIndex);
    return;
  }
  await controller.finalizeRemovedDownloadedSong(song);
}

class _SongTile extends StatelessWidget {
  const _SongTile({
    required this.song,
    required this.controller,
    this.index,
    this.onTap,
    this.extraPlaylistId,
    this.playlistSongIndex,
    this.allowDownloadRemoval = false,
  });

  final LibrarySong song;
  final MusixController controller;
  final int? index;
  final VoidCallback? onTap;
  final String? extraPlaylistId;
  final int? playlistSongIndex;
  final bool allowDownloadRemoval;

  @override
  Widget build(BuildContext context) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool active = controller.currentSong?.id == song.id;
    final VoidCallback resolvedTap =
        onTap ??
        () {
          if (song.isRemote) {
            controller.playOnlineSong(song);
          } else {
            controller.playSong(song, label: song.sourceLabel);
          }
        };

    final Widget tile = _SongCardRow(
      song: song,
      index: index,
      subtitle: _songArtistLabel(song),
      metaText: _formatClock(song.duration),
      active: active,
      onTap: resolvedTap,
      onLongPress: () {
        unawaited(
          _showSongActionsSheet(
            context,
            controller: controller,
            song: song,
            extraPlaylistId: extraPlaylistId,
            playlistSongIndex: playlistSongIndex,
            allowDownloadRemoval: allowDownloadRemoval,
          ),
        );
      },
    );

    final bool canRemoveFromPlaylist =
        extraPlaylistId != null && extraPlaylistId!.trim().isNotEmpty;
    final bool canRemoveDownloadedSong =
        allowDownloadRemoval && song.isDownloaded;
    final bool canSwipeLeftToRemove =
        canRemoveFromPlaylist || canRemoveDownloadedSong;

    final DismissDirection direction = canSwipeLeftToRemove
        ? DismissDirection.horizontal
        : DismissDirection.startToEnd;

    return Dismissible(
      key: ValueKey<String>(
        'song-tile-${extraPlaylistId ?? song.sourceLabel}-${index ?? -1}-${song.id}',
      ),
      direction: direction,
      background: const _SwipeActionBackground(
        alignment: Alignment.centerLeft,
        color: Color(0xFF18432B),
        icon: Icons.queue_music_rounded,
        label: 'Queue',
      ),
      secondaryBackground: canSwipeLeftToRemove
          ? const _SwipeActionBackground(
              alignment: Alignment.centerRight,
              color: Color(0xFF5A1613),
              icon: Icons.remove_circle_outline_rounded,
              label: 'Remove',
            )
          : null,
      confirmDismiss: (DismissDirection dismissedDirection) async {
        final bool swipedRight =
            dismissedDirection == DismissDirection.startToEnd;
        if (swipedRight) {
          await HapticFeedback.selectionClick();
          await controller.enqueueSong(song);
          if (context.mounted) {
            _showMusixSnackBar(context, 'Added to queue');
          }
          return false;
        }
        if (!swipedRight && canSwipeLeftToRemove) {
          await HapticFeedback.mediumImpact();
          return true;
        }
        return false;
      },
      onDismissed: (DismissDirection dismissedDirection) async {
        if (dismissedDirection == DismissDirection.endToStart &&
            canRemoveFromPlaylist &&
            extraPlaylistId != null &&
            playlistSongIndex != null) {
          await _removePlaylistSongWithUndo(
            messenger,
            controller: controller,
            playlistId: extraPlaylistId!,
            songId: song.id,
            playlistSongIndex: playlistSongIndex!,
          );
        } else if (dismissedDirection == DismissDirection.endToStart &&
            canRemoveDownloadedSong) {
          await _removeDownloadedSongWithUndo(
            messenger,
            controller: controller,
            song: song,
          );
        }
      },
      child: tile,
    );
  }
}

String _songArtistLabel(LibrarySong song) {
  final String artist = song.artist.trim();
  return artist.isEmpty ? 'Unknown artist' : artist;
}

Future<void> _showSongActionsSheet(
  BuildContext context, {
  required MusixController controller,
  required LibrarySong song,
  String? extraPlaylistId,
  int? playlistSongIndex,
  bool allowFavorite = true,
  bool allowQueue = true,
  bool allowPlaylist = true,
  bool allowDownloadRemoval = false,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final int? resolvedPlaylistSongIndex =
      extraPlaylistId != null && extraPlaylistId.trim().isNotEmpty
      ? (playlistSongIndex ??
            controller.playlists
                .firstWhereOrNull(
                  (UserPlaylist playlist) => playlist.id == extraPlaylistId,
                )
                ?.songIds
                .indexOf(song.id))
      : null;
  final List<({IconData icon, String label, FutureOr<void> Function() action})>
  actions = <({IconData icon, String label, FutureOr<void> Function() action})>[
    if (allowFavorite)
      (
        icon: song.isFavorite
            ? Icons.favorite_outline_rounded
            : Icons.favorite_border_rounded,
        label: song.isFavorite ? 'Unfavorite' : 'Favorite',
        action: () => controller.toggleFavorite(song.id),
      ),
    if (allowQueue)
      (
        icon: Icons.queue_music_rounded,
        label: 'Add to queue',
        action: () => controller.enqueueSong(song),
      ),
    if (allowPlaylist && !song.isRemote)
      (
        icon: Icons.playlist_add_rounded,
        label: 'Add to playlist',
        action: () => _showAddToPlaylistDialog(context, controller, song),
      ),
    if (extraPlaylistId != null && extraPlaylistId.trim().isNotEmpty)
      (
        icon: Icons.remove_circle_outline_rounded,
        label: 'Remove from playlist',
        action: () =>
            resolvedPlaylistSongIndex == null || resolvedPlaylistSongIndex < 0
            ? controller.removeSongFromPlaylist(extraPlaylistId, song.id)
            : _removePlaylistSongWithUndo(
                messenger,
                controller: controller,
                playlistId: extraPlaylistId,
                songId: song.id,
                playlistSongIndex: resolvedPlaylistSongIndex,
              ),
      ),
    if (allowDownloadRemoval)
      (
        icon: Icons.delete_outline_rounded,
        label: 'Remove download',
        action: () => _removeDownloadedSongWithUndo(
          messenger,
          controller: controller,
          song: song,
        ),
      ),
  ];

  if (actions.isEmpty) {
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext modalContext) {
      return SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: _kSurface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _kSurfaceEdge),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                child: _SongCardRow(
                  song: song,
                  subtitle: _songArtistLabel(song),
                  metaText: _formatClock(song.duration),
                  onTap: () {},
                  borderRadius: 18,
                  addBottomGap: false,
                ),
              ),
              const Divider(height: 1, color: _kSurfaceEdge),
              ...actions.map((
                ({
                  IconData icon,
                  String label,
                  FutureOr<void> Function() action,
                })
                item,
              ) {
                return ListTile(
                  leading: Icon(item.icon, color: _kTextPrimary),
                  title: Text(
                    item.label,
                    style: _musixBodyTextStyle(
                      color: _kTextPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    await item.action();
                    if (!context.mounted) {
                      return;
                    }
                    if (item.label == 'Add to queue') {
                      _showMusixSnackBar(context, 'Added to queue');
                    }
                  },
                );
              }),
            ],
          ),
        ),
      );
    },
  );
}

class _SongCardRow extends StatelessWidget {
  const _SongCardRow({
    required this.song,
    required this.subtitle,
    required this.metaText,
    required this.onTap,
    this.index,
    this.onLongPress,
    this.active = false,
    this.artworkSize = 52,
    this.borderRadius = 18,
    this.addBottomGap = true,
  });

  final LibrarySong song;
  final int? index;
  final String subtitle;
  final String metaText;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool active;
  final double artworkSize;
  final double borderRadius;
  final bool addBottomGap;

  @override
  Widget build(BuildContext context) {
    final String indexLabel = index == null
        ? ''
        : index!.toString().padLeft(2, '0');

    return Padding(
      padding: EdgeInsets.only(bottom: addBottomGap ? 12 : 0),
      child: RepaintBoundary(
        child: _ApplePressable(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(borderRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 32,
                  child: Text(
                    indexLabel,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: _kSongCardMeta,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    _Artwork(
                      seed: song.id,
                      title: song.title,
                      size: artworkSize,
                      imageUrl: song.artworkUrl,
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: _kSongCardTitle,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _kSongCardSubtitle,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 44,
                  child: Text(
                    metaText,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: _kSongCardMeta,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SongCardSkeleton extends StatelessWidget {
  const _SongCardSkeleton({required this.index, this.artworkSize = 52});

  final int index;
  final double artworkSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 32,
              child: Align(
                alignment: Alignment.center,
                child: _SkeletonBlock(
                  width: index >= 10 ? 22 : 18,
                  height: 16,
                  radius: 6,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _SkeletonBlock(width: artworkSize, height: artworkSize, radius: 14),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _SkeletonBlock(width: double.infinity, height: 14, radius: 8),
                  SizedBox(height: 8),
                  _SkeletonBlock(width: 170, height: 12, radius: 8),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const _SkeletonBlock(width: 40, height: 14, radius: 8),
          ],
        ),
      ),
    );
  }
}

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({required this.controller, required this.onOpenPlayer});

  static const double _kMiniPlayerExpandVelocity = 360;

  final MusixController controller;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlayingState>(
      valueListenable: controller.nowPlayingState,
      builder: (BuildContext context, NowPlayingState nowPlaying, Widget? child) {
        final LibrarySong? song = nowPlaying.song;
        if (song == null) {
          return const SizedBox.shrink();
        }

        const Color shell = Color(0xFF100502);
        const Color card = Color(0xFF2A1209);
        const Color cardEdge = Color(0xFF402016);
        const Color accent = Color(0xFFFF7F17);
        const Color inactive = Color(0xFFEEDDCF);
        const Color track = Color(0xFF4D2A1D);

        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                await HapticFeedback.selectionClick();
                onOpenPlayer();
              },
              onVerticalDragEnd: (DragEndDetails details) async {
                if (details.velocity.pixelsPerSecond.dy <
                    -_kMiniPlayerExpandVelocity) {
                  await HapticFeedback.selectionClick();
                  onOpenPlayer();
                }
              },
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  constraints: const BoxConstraints(minHeight: 78),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: cardEdge, width: 1),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: shell.withValues(alpha: 0.42),
                        blurRadius: 14,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                  child: Row(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          width: 50,
                          height: 50,
                          child:
                              song.artworkUrl != null &&
                                  song.artworkUrl!.trim().isNotEmpty
                              ? _CachedArtworkImage(
                                  imageUrl: song.artworkUrl!,
                                  dimension: 50,
                                  placeholder: const _MiniArtworkFallback(),
                                  errorWidget: const _MiniArtworkFallback(),
                                )
                              : const _MiniArtworkFallback(),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final bool compact = constraints.maxWidth < 250;

                                return ValueListenableBuilder<
                                  PlaybackProgressState
                                >(
                                  valueListenable:
                                      controller.playbackProgressState,
                                  builder:
                                      (
                                        BuildContext context,
                                        PlaybackProgressState progressState,
                                        Widget? child,
                                      ) {
                                        final bool isMiniLoading =
                                            nowPlaying.isLoading;
                                        final Duration position = isMiniLoading
                                            ? Duration.zero
                                            : progressState.position;
                                        final Duration duration =
                                            progressState.duration ==
                                                Duration.zero
                                            ? song.duration
                                            : progressState.duration;
                                        final double progress =
                                            duration.inMilliseconds <= 0
                                            ? 0
                                            : position.inMilliseconds /
                                                  duration.inMilliseconds;
                                        final double safeProgress =
                                            progress.isFinite
                                            ? progress.clamp(0.0, 1.0)
                                            : 0.0;
                                        final bool showPauseIcon =
                                            progressState.isPlaying &&
                                            !isMiniLoading;

                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Row(
                                              children: <Widget>[
                                                Expanded(
                                                  child: _PlayerTransportControls(
                                                    layoutScale: 1,
                                                    accent: accent,
                                                    textPrimary: inactive,
                                                    inactiveColor: inactive
                                                        .withValues(alpha: 0.6),
                                                    isPlayerLoading:
                                                        isMiniLoading,
                                                    isShuffleEnabled: nowPlaying
                                                        .isShuffleEnabled,
                                                    repeatMode:
                                                        nowPlaying.repeatMode,
                                                    showPauseIcon:
                                                        showPauseIcon,
                                                    onToggleShuffle: controller
                                                        .toggleShuffle,
                                                    onPrevious: controller
                                                        .previousTrack,
                                                    onTogglePlayback: controller
                                                        .togglePlayback,
                                                    onNext:
                                                        controller.nextTrack,
                                                    onCycleRepeatMode:
                                                        controller
                                                            .cycleRepeatMode,
                                                    iconButtonSize: compact
                                                        ? 28
                                                        : 34,
                                                    smallIconSize: compact
                                                        ? 22
                                                        : 28,
                                                    skipIconSize: compact
                                                        ? 22
                                                        : 28,
                                                    playButtonSize: compact
                                                        ? 42
                                                        : 48,
                                                    useCircularPlayButton:
                                                        defaultTargetPlatform ==
                                                        TargetPlatform.android,
                                                    playIconSize: compact
                                                        ? 25
                                                        : 28,
                                                    pauseIconSize: compact
                                                        ? 22
                                                        : 24,
                                                    loadingSize: compact
                                                        ? 18
                                                        : 20,
                                                    loadingStrokeWidth: 2.5,
                                                    shadowBlur: 0,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              child: SizedBox(
                                                height: 5,
                                                width: double.infinity,
                                                child: ColoredBox(
                                                  color: track,
                                                  child: Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: FractionallySizedBox(
                                                      widthFactor: isMiniLoading
                                                          ? 0.0
                                                          : safeProgress,
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      child:
                                                          const SizedBox.expand(
                                                            child: ColoredBox(
                                                              color: accent,
                                                            ),
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                );
                              },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniArtworkFallback extends StatelessWidget {
  const _MiniArtworkFallback();

  @override
  Widget build(BuildContext context) {
    return const _ArtworkFallbackSurface(
      colors: <Color>[Color(0xFF1F8E96), Color(0xFF23516E)],
    );
  }
}

class _ArtworkFallbackSurface extends StatelessWidget {
  const _ArtworkFallbackSurface({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            right: -12,
            top: -10,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.10),
              ),
            ),
          ),
          Positioned(
            left: -10,
            bottom: -12,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.12),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CachedArtworkImage extends StatelessWidget {
  const _CachedArtworkImage({
    required this.imageUrl,
    this.dimension,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorWidget,
    this.debugLabel,
  });

  final String imageUrl;
  final double? dimension;
  final Alignment alignment;
  final Widget? placeholder;
  final Widget? errorWidget;
  final String? debugLabel;

  @override
  Widget build(BuildContext context) {
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final int? cacheDimension = dimension == null
        ? null
        : (dimension! * devicePixelRatio).round();
    final String normalizedImageUrl = imageUrl.trim();
    final Uri? uri = Uri.tryParse(normalizedImageUrl);
    final bool looksLikeWindowsAbsolutePath = RegExp(
      r'^[A-Za-z]:[\\/]',
    ).hasMatch(normalizedImageUrl);
    final bool isLocalFile =
        normalizedImageUrl.isNotEmpty &&
        (looksLikeWindowsAbsolutePath ||
            uri == null ||
            uri.scheme == 'file' ||
            !uri.hasScheme);

    if (isLocalFile) {
      return Image.file(
        File(uri != null && uri.scheme == 'file' ? uri.toFilePath() : imageUrl),
        fit: BoxFit.cover,
        alignment: alignment,
        filterQuality: FilterQuality.medium,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
          if ((debugLabel ?? '').trim().isNotEmpty) {
            AppLogger.warn(
              'ArtistImage',
              'Local image failed for ${debugLabel!.trim()}: $error',
            );
          }
          return errorWidget ?? placeholder ?? const SizedBox.shrink();
        },
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      alignment: alignment,
      memCacheWidth: cacheDimension,
      memCacheHeight: cacheDimension,
      filterQuality: FilterQuality.medium,
      fadeInDuration: const Duration(milliseconds: 120),
      imageBuilder: (BuildContext context, ImageProvider imageProvider) {
        if ((debugLabel ?? '').trim().isNotEmpty) {
          AppLogger.info(
            'ArtistImage',
            'Loaded image for ${debugLabel!.trim()} from $imageUrl',
          );
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: imageProvider,
              fit: BoxFit.cover,
              alignment: alignment,
            ),
          ),
        );
      },
      placeholder: (BuildContext context, String url) =>
          placeholder ?? const SizedBox.shrink(),
      errorWidget: (BuildContext context, String url, Object error) {
        if ((debugLabel ?? '').trim().isNotEmpty) {
          AppLogger.warn(
            'ArtistImage',
            'Image failed for ${debugLabel!.trim()}: $error',
          );
        }
        return errorWidget ?? placeholder ?? const SizedBox.shrink();
      },
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.seed,
    required this.title,
    required this.size,
    this.icon,
    this.imageUrl,
  });

  final String seed;
  final String title;
  final double size;
  final IconData? icon;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> colors = _gradientFor(seed, scheme);
    final bool hasArtwork = imageUrl != null && imageUrl!.trim().isNotEmpty;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: <Widget>[
          if (hasArtwork)
            Positioned.fill(
              child: _CachedArtworkImage(imageUrl: imageUrl!, dimension: size),
            ),
          if (!hasArtwork) _ArtworkFallbackSurface(colors: colors),
          if (!hasArtwork && icon != null)
            Align(
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: size * 0.34,
                color: Colors.white.withValues(alpha: 0.82),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtistAvatar extends StatelessWidget {
  const _ArtistAvatar({
    required this.seed,
    required this.title,
    required this.size,
    this.imageUrl,
  });

  final String seed;
  final String title;
  final double size;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> colors = _gradientFor(seed, scheme);
    final bool hasArtwork = imageUrl != null && imageUrl!.trim().isNotEmpty;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(
            child: Text(
              _initials(title),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color:
                    ThemeData.estimateBrightnessForColor(colors.first) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hasArtwork)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 1.2,
                  ),
                ),
                child: _CachedArtworkImage(
                  imageUrl: imageUrl!,
                  dimension: size,
                  alignment: Alignment.center,
                  debugLabel: title,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResolvedArtistAvatar extends StatefulWidget {
  const _ResolvedArtistAvatar({
    required this.controller,
    required this.artistName,
    required this.seed,
    required this.size,
  });

  final MusixController controller;
  final String artistName;
  final String seed;
  final double size;

  @override
  State<_ResolvedArtistAvatar> createState() => _ResolvedArtistAvatarState();
}

class _ResolvedArtistAvatarState extends State<_ResolvedArtistAvatar> {
  late Future<String?> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = widget.controller.resolveArtistImage(widget.artistName);
  }

  @override
  void didUpdateWidget(covariant _ResolvedArtistAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.artistName != oldWidget.artistName ||
        widget.controller != oldWidget.controller) {
      _imageFuture = widget.controller.resolveArtistImage(widget.artistName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _imageFuture,
      builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
        final String? resolvedImageUrl = switch (snapshot.data?.trim()) {
          final String value when value.isNotEmpty => value,
          _ => null,
        };
        final bool hadError = snapshot.hasError;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: _RevealIn(
            key: ValueKey<String>(
              'artist-loaded-${widget.seed}-${resolvedImageUrl ?? 'fallback'}',
            ),
            child: _ArtistAvatar(
              seed: widget.seed,
              title: widget.artistName,
              size: widget.size,
              imageUrl: hadError ? null : resolvedImageUrl,
            ),
          ),
        );
      },
    );
  }
}
