part of '../../../musix_ui.dart';

class _DesktopProfileScreen extends StatelessWidget {
  const _DesktopProfileScreen({
    required this.controller,
    required this.onPickRegion,
  });

  final MusixController controller;
  final Future<void> Function() onPickRegion;

  @override
  Widget build(BuildContext context) {
    final AuthService authService = context.read<AuthService>();
    final int preloadNextSongCount = controller.preloadNextSongCount;
    final String preloadNextSongsLabel = preloadNextSongCount == 0
        ? 'Off'
        : preloadNextSongCount.toString();
    final String sleepTimerStatusLabel = controller.sleepTimerStatusLabel;
    final String userName = _profileDisplayName(
      authService.currentUserDisplayName,
    );
    final String userEmail = authService.currentUserEmail;
    final LibrarySong? currentStreamSong = controller.currentSong;
    final PlaybackStreamInfo? currentStreamInfo =
        controller.currentPlaybackStreamInfo;
    final String currentStreamSizeLabel =
        currentStreamSong != null && currentStreamInfo != null
        ? controller.currentStreamSongDataLabel(
            song: currentStreamSong,
            info: currentStreamInfo,
            fallbackLabel: currentStreamInfo.bitrateLabel,
          )
        : 'Idle';

    Future<void> signOutUser() async {
      try {
        await authService.signOut();
        await controller.clearUserDataFromCloud();
        if (!context.mounted) {
          return;
        }
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
          (Route<dynamic> route) => false,
        );
      } on AuthException catch (error) {
        if (context.mounted) {
          _showMusixSnackBar(context, error.message);
        }
      }
    }

    Future<void> pickPreloadCount() async {
      final List<int> preloadOptions = List<int>.generate(
        4,
        (int value) => value,
      );
      final int? selected = await _showSettingsSelectionSheet<int, int>(
        context: context,
        title: 'Next song preload',
        description: 'Keep upcoming songs ready for smoother playback',
        selectedValue: preloadNextSongCount,
        items: preloadOptions,
        valueOf: (int value) => value,
        titleOf: (int value) => value == 0 ? 'Off' : '$value songs',
        subtitleOf: (int value) => switch (value) {
          0 => 'Do not preload the queue',
          1 => 'Prepare the next song only',
          _ => 'Prepare the next $value songs',
        },
      );
      if (selected == null) {
        return;
      }
      await controller.setPreloadNextSongCount(selected);
    }

    Future<void> pickSleepTimer() async {
      const List<int> sleepTimerOptions = <int>[0, 10, 20, 30, 45, 60];
      final int? selected = await _showSettingsSelectionSheet<int, int>(
        context: context,
        title: 'Sleep timer',
        description: 'Music stops automatically after the timer ends',
        selectedValue: controller.sleepTimerMinutes,
        items: sleepTimerOptions,
        valueOf: (int value) => value,
        titleOf: (int value) => switch (value) {
          0 => 'Off',
          10 => '10 minutes',
          20 => '20 minutes',
          30 => '30 minutes',
          45 => '45 minutes',
          60 => '1 hour',
          _ => '$value minutes',
        },
        subtitleOf: (int value) => switch (value) {
          0 => 'Disable the inactivity sleep timer',
          _ => 'Music stops automatically after the timer ends',
        },
      );
      if (selected == null) {
        return;
      }
      await controller.setSleepTimerMinutes(selected);
    }

    return _DesktopPageScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            decoration: musixPanelDecoration(
              color: MusixColors.surface,
              borderColor: MusixColors.surfaceEdge,
            ),
            padding: const EdgeInsets.all(24),
            child: Row(
              children: <Widget>[
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: MusixColors.surfaceBlack,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Image.asset('assets/icons/Musix - Full.png'),
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: _kTextPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        userEmail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: MusixColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool stacked = constraints.maxWidth < 1160;
              final Widget leftColumn = Column(
                children: <Widget>[
                  Container(
                    decoration: musixPanelDecoration(
                      color: MusixColors.surface,
                      borderColor: MusixColors.surfaceEdge,
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Icon(
                              Icons.slow_motion_video_rounded,
                              color: MusixColors.textMuted,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Playback',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: _kTextPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _DesktopSettingsActionRow(
                          title: 'Next Song Preload',
                          subtitle:
                              'Keep upcoming songs ready for smoother playback',
                          trailing: GestureDetector(
                            onTap: pickPreloadCount,
                            child: Text(
                              preloadNextSongsLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: MusixColors.accent,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          onTap: pickPreloadCount,
                        ),
                        const Divider(
                          color: MusixColors.surfaceEdge,
                          height: 24,
                        ),
                        _DesktopSettingsActionRow(
                          title: 'Sleep Timer',
                          subtitle:
                              'Music stops automatically after the timer ends',
                          trailing: GestureDetector(
                            onTap: pickSleepTimer,
                            child: Text(
                              sleepTimerStatusLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: MusixColors.accent,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          onTap: pickSleepTimer,
                        ),
                        const Divider(
                          color: MusixColors.surfaceEdge,
                          height: 24,
                        ),
                        _DesktopSettingsActionRow(
                          title: 'Data Usage',
                          subtitle: currentStreamSong == null
                              ? 'Displays the size of the current audio stream'
                              : currentStreamSong.title,
                          trailing: Text(
                            currentStreamSizeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: MusixColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );

              final Widget rightColumn = Column(
                children: <Widget>[
                  Container(
                    decoration: musixPanelDecoration(
                      color: MusixColors.surface,
                      borderColor: MusixColors.surfaceEdge,
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Icon(
                              Icons.auto_awesome_rounded,
                              color: MusixColors.textMuted,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Personalization',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: _kTextPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _DesktopSettingsActionRow(
                          title: 'Region',
                          subtitle: 'Personalize trending music by region',
                          onTap: onPickRegion,
                          trailing: Text(
                            controller.preferredRegionLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: MusixColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    decoration: musixPanelDecoration(
                      color: MusixColors.surface,
                      borderColor: MusixColors.surfaceEdge,
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Musix 4.3.17',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: MusixColors.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Proudly built for music enthusiasts.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: MusixColors.textMuted.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: signOutUser,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(46),
                              side: const BorderSide(
                                color: MusixColors.surfaceEdge,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              foregroundColor: MusixColors.accent,
                            ),
                            child: const Text('LOG OUT'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );

              if (stacked) {
                return Column(
                  children: <Widget>[
                    leftColumn,
                    const SizedBox(height: 20),
                    rightColumn,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: leftColumn),
                  const SizedBox(width: 20),
                  Expanded(child: rightColumn),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
