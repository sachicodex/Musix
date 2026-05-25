part of '../../../musix_ui.dart';

class _DesktopNowPlayingRail extends StatelessWidget {
  const _DesktopNowPlayingRail({
    required this.controller,
    required this.onOpenPlayer,
  });

  final MusixController controller;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NowPlayingState>(
      valueListenable: controller.nowPlayingState,
      builder: (BuildContext context, NowPlayingState nowPlaying, Widget? _) {
        final LibrarySong? song = nowPlaying.song;
        if (song == null) {
          return const SizedBox.shrink();
        }

        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compactHeight = constraints.maxHeight < 760;
            final double artworkExtent = math.max(
              0,
              constraints.maxWidth - (compactHeight ? 44 : 52),
            );

            return _DesktopPanel(
              padding: EdgeInsets.fromLTRB(
                compactHeight ? 22 : 26,
                compactHeight ? 22 : 28,
                compactHeight ? 22 : 26,
                compactHeight ? 22 : 26,
              ),
              child: ValueListenableBuilder<PlaybackProgressState>(
                valueListenable: controller.playbackProgressState,
                builder:
                    (
                      BuildContext context,
                      PlaybackProgressState progress,
                      Widget? child,
                    ) {
                      final Duration duration =
                          progress.duration == Duration.zero
                          ? song.duration
                          : progress.duration;
                      final Duration position = nowPlaying.isLoading
                          ? Duration.zero
                          : progress.position;
                      final double progressValue = duration.inMilliseconds <= 0
                          ? 0
                          : position.inMilliseconds / duration.inMilliseconds;
                      final double safeProgress = progressValue.isFinite
                          ? progressValue.clamp(0.0, 1.0)
                          : 0.0;
                      final bool showPauseIcon =
                          progress.isPlaying && !nowPlaying.isLoading;

                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const _DesktopPanelTitle(
                              eyebrow: 'LOST IN SOUND',
                              title: 'Listening Now',
                              centered: true,
                            ),
                            SizedBox(height: compactHeight ? 18 : 22),
                            Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: artworkExtent,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: <Widget>[
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(34),
                                      child: SizedBox(
                                        width: artworkExtent,
                                        height: artworkExtent,
                                        child:
                                            song.artworkUrl != null &&
                                                song.artworkUrl!
                                                    .trim()
                                                    .isNotEmpty
                                            ? _CachedArtworkImage(
                                                imageUrl: song.artworkUrl!,
                                                dimension: artworkExtent,
                                                placeholder:
                                                    const _PlayerArtFallback(),
                                                errorWidget:
                                                    const _PlayerArtFallback(),
                                              )
                                            : const _PlayerArtFallback(),
                                      ),
                                    ),
                                    SizedBox(height: compactHeight ? 18 : 22),
                                    Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: _musixHeadingTextStyle(
                                        color: _kTextPrimary,
                                        fontSize: compactHeight ? 24 : 28,
                                        fontWeight: FontWeight.w600,
                                        height: 1.0,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _songArtistLabel(song),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: _musixBodyTextStyle(
                                        color: _kTextSecondary,
                                        fontWeight: FontWeight.w500,
                                        fontSize: compactHeight ? 15 : 16,
                                        height: 1.35,
                                      ),
                                    ),
                                    SizedBox(height: compactHeight ? 18 : 22),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(999),
                                      child: SizedBox(
                                        height: 6,
                                        child: ColoredBox(
                                          color: const Color(0xFF73432C),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: FractionallySizedBox(
                                              widthFactor: safeProgress,
                                              alignment: Alignment.centerLeft,
                                              child: const SizedBox.expand(
                                                child: ColoredBox(
                                                  color: _kAccent,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: <Widget>[
                                        Text(
                                          _formatClock(position),
                                          style: _musixBodyTextStyle(
                                            color: _kTextPrimary.withValues(
                                              alpha: 0.92,
                                            ),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          _formatClock(duration),
                                          style: _musixBodyTextStyle(
                                            color: _kTextPrimary.withValues(
                                              alpha: 0.92,
                                            ),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: compactHeight ? 18 : 22),
                                    _PlayerTransportControls(
                                      layoutScale: 1,
                                      accent: _kAccent,
                                      textPrimary: _kTextPrimary,
                                      inactiveColor: _kTextSecondary.withValues(
                                        alpha: 0.7,
                                      ),
                                      isPlayerLoading: nowPlaying.isLoading,
                                      isShuffleEnabled:
                                          nowPlaying.isShuffleEnabled,
                                      repeatMode: nowPlaying.repeatMode,
                                      showPauseIcon: showPauseIcon,
                                      onToggleShuffle: controller.toggleShuffle,
                                      onPrevious: controller.previousTrack,
                                      onTogglePlayback:
                                          controller.togglePlayback,
                                      onNext: controller.nextTrack,
                                      onCycleRepeatMode:
                                          controller.cycleRepeatMode,
                                      iconButtonSize: compactHeight ? 40 : 44,
                                      smallIconSize: compactHeight ? 24 : 26,
                                      skipIconSize: compactHeight ? 28 : 30,
                                      playButtonSize: compactHeight ? 60 : 65,
                                      playIconSize: compactHeight ? 32 : 34,
                                      pauseIconSize: compactHeight ? 28 : 30,
                                      loadingSize: 20,
                                      loadingStrokeWidth: 2.4,
                                      shadowBlur: 0,
                                    ),
                                    SizedBox(height: compactHeight ? 36 : 42),
                                    SizedBox(
                                      width: double.infinity,
                                      child: _ApplePressable(
                                        onTap: onOpenPlayer,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        child: AbsorbPointer(
                                          child: FilledButton.icon(
                                            onPressed: onOpenPlayer,
                                            style: FilledButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xff2A120A,
                                              ),
                                              foregroundColor: _kTextPrimary,
                                              padding: EdgeInsets.symmetric(
                                                vertical: compactHeight
                                                    ? 16
                                                    : 18,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                side: const BorderSide(
                                                  color: Color(0xff3A170C),
                                                ),
                                              ),
                                            ),
                                            icon: Icon(
                                              Icons.fullscreen_sharp,
                                              color: _kTextSecondary.withValues(
                                                alpha: 0.8,
                                              ),
                                            ),
                                            label: Text(
                                              'Open Full Player',
                                              overflow: TextOverflow.ellipsis,
                                              style: _musixBodyTextStyle(
                                                fontWeight: FontWeight.w600,
                                                color: _kTextSecondary
                                                    .withValues(alpha: 0.8),
                                              ),
                                            ),
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
                    },
              ),
            );
          },
        );
      },
    );
  }
}