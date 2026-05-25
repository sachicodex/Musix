part of '../../musix_ui.dart';

@immutable
class _ProfileViewState {
  const _ProfileViewState({
    required this.preloadNextSongCount,
    required this.sleepTimerStatusLabel,
    required this.preferredRegionLabel,
    required this.currentStreamSongId,
    required this.currentStreamBitrateLabel,
    required this.hasMiniPlayer,
  });

  final int preloadNextSongCount;
  final String sleepTimerStatusLabel;
  final String preferredRegionLabel;
  final String? currentStreamSongId;
  final String? currentStreamBitrateLabel;
  final bool hasMiniPlayer;

  @override
  bool operator ==(Object other) {
    return other is _ProfileViewState &&
        preloadNextSongCount == other.preloadNextSongCount &&
        sleepTimerStatusLabel == other.sleepTimerStatusLabel &&
        preferredRegionLabel == other.preferredRegionLabel &&
        currentStreamSongId == other.currentStreamSongId &&
        currentStreamBitrateLabel == other.currentStreamBitrateLabel &&
        hasMiniPlayer == other.hasMiniPlayer;
  }

  @override
  int get hashCode => Object.hash(
    preloadNextSongCount,
    sleepTimerStatusLabel,
    preferredRegionLabel,
    currentStreamSongId,
    currentStreamBitrateLabel,
    hasMiniPlayer,
  );
}

class _ProfileScreen extends StatelessWidget {
  const _ProfileScreen({super.key, required this.controller});

  final MusixController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller.appSettings,
        controller.queue,
      ]),
      builder: (BuildContext context, Widget? _) {
        final LibrarySong? currentStreamSong = controller.currentSong;
        final PlaybackStreamInfo? currentStreamInfo =
            controller.currentPlaybackStreamInfo;
        final _ProfileViewState view = _ProfileViewState(
          preloadNextSongCount: controller.preloadNextSongCount,
          sleepTimerStatusLabel: controller.sleepTimerStatusLabel,
          preferredRegionLabel: controller.preferredRegionLabel,
          currentStreamSongId: currentStreamSong?.id,
          currentStreamBitrateLabel: currentStreamInfo?.bitrateLabel,
          hasMiniPlayer: controller.miniPlayerSong != null,
        );
        return _ProfileScreenBody(controller: controller, view: view);
      },
    );
  }
}

class _ProfileScreenBody extends StatelessWidget {
  const _ProfileScreenBody({required this.controller, required this.view});

  final MusixController controller;
  final _ProfileViewState view;

  @override
  Widget build(BuildContext context) {
    final AuthService authService = context.read<AuthService>();
    final int preloadNextSongCount = view.preloadNextSongCount;
    final String preloadNextSongsLabel = preloadNextSongCount == 0
        ? 'Off'
        : preloadNextSongCount.toString();
    final String sleepTimerStatusLabel = view.sleepTimerStatusLabel;
    final String preferredRegion = view.preferredRegionLabel;
    final String userName = authService.currentUserDisplayName;
    final String userEmail = authService.currentUserEmail;
    final String userId = authService.currentUserShortUid;
    final bool emailVerified = authService.isCurrentUserEmailVerified;
    final LibrarySong? currentStreamSong = view.currentStreamSongId == null
        ? null
        : controller.currentSong;
    final String currentStreamSizeLabel = currentStreamSong != null &&
            view.currentStreamBitrateLabel != null
        ? controller.currentStreamSongDataLabel(
            song: currentStreamSong,
            info: controller.currentPlaybackStreamInfo!,
            fallbackLabel: view.currentStreamBitrateLabel!,
          )
        : 'No active stream';

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

    Future<void> pickRegion() async {
      final String? selected =
          await _showSettingsSelectionSheet<AppRegion, String>(
            context: context,
            title: 'Choose region',
            description:
                'Regional trending and charts will follow this region.',
            selectedValue: controller.preferredCountryCode,
            items: controller.availableRegions,
            valueOf: (AppRegion region) => region.countryCode,
            titleOf: (AppRegion region) => region.label,
            subtitleOf: (AppRegion region) => region.countryCode,
          );
      if (selected != null) {
        await controller.setPreferredRegion(selected);
      }
    }

    Future<void> pickPreloadCount() async {
      final List<int> preloadOptions = List<int>.generate(
        6,
        (int value) => value,
      );
      final int? selected = await _showSettingsSelectionSheet<int, int>(
        context: context,
        title: 'Next song preload',
        description: 'Keep upcoming songs ready so playback starts faster.',
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
        description:
            'Stops playback after the selected inactive time. The countdown only runs while music is playing and turns off when the app is reopened.',
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
          _ =>
            'Tracks gestures and controls, and starts counting when playback starts',
        },
      );
      if (selected == null) {
        return;
      }
      await controller.setSleepTimerMinutes(selected);
    }

    if (_isDesktopPlatform()) {
      return _DesktopProfileScreen(
        controller: controller,
        onPickRegion: pickRegion,
      );
    }

    return DecoratedBox(
      decoration: musixPageDecoration(),
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: _rootScreenContentPadding(
            context,
            hasMiniPlayer: view.hasMiniPlayer,
          ),
          children: <Widget>[
            const _HomeStyleHeader(
              title: 'PROFILE',
              leading: _HomeStyleProfileBadge(),
              trailing: _HomeStyleNotificationIcon(),
            ),
            const SizedBox(height: 14),

            Container(
              decoration: musixPanelDecoration(
                radius: 20,
                color: MusixColors.surface,
                borderColor: MusixColors.surfaceEdge,
              ),
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 86,
                    height: 86,
                    decoration: BoxDecoration(
                      color: MusixColors.surfaceBlack,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(15),
                        child: Image.asset('assets/icons/Musix - Full.png'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(height: 2),
                        Text(
                          userName.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: _kTextPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          userEmail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: MusixColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            Container(
              decoration: musixPanelDecoration(
                radius: 20,
                color: MusixColors.surface,
                borderColor: MusixColors.surfaceEdge,
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(
                        Icons.person_outline_rounded,
                        color: MusixColors.textMuted,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Account',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: _kTextPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _ProfileRow(
                    title: 'Email Verification',
                    subtitle: emailVerified
                        ? 'Your Firebase account email is verified.'
                        : 'Email verification is currently not completed.',
                    trailing: emailVerified ? 'Verified' : 'Pending',
                  ),
                  const Divider(color: MusixColors.surfaceEdge, height: 20),
                  _ProfileRow(
                    title: 'Firebase User ID',
                    subtitle: 'Short reference for your signed-in account.',
                    trailing: userId,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              decoration: musixPanelDecoration(
                radius: 20,
                color: MusixColors.surface,
                borderColor: MusixColors.surfaceEdge,
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
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
                  const SizedBox(height: 14),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Next Song Preload',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: _kTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'Off, or keep the next 1 to 5 songs ready to play',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: MusixColors.textMuted,
                      ),
                    ),
                    trailing: Text(
                      preloadNextSongsLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: MusixColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: pickPreloadCount,
                  ),
                  const Divider(color: MusixColors.surfaceEdge, height: 20),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Sleep Timer',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: _kTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'Tracks gestures and controls, and starts counting when playback starts',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: MusixColors.textMuted,
                      ),
                    ),
                    trailing: Text(
                      sleepTimerStatusLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: MusixColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: pickSleepTimer,
                  ),
                  const Divider(color: MusixColors.surfaceEdge, height: 20),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Current Stream Source Size',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: _kTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      currentStreamSong == null
                          ? 'Play a song to inspect the active source size.'
                          : currentStreamSong.title,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: MusixColors.textMuted,
                      ),
                    ),
                    trailing: Text(
                      currentStreamSizeLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: MusixColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              decoration: musixPanelDecoration(
                radius: 20,
                color: MusixColors.surface,
                borderColor: MusixColors.surfaceEdge,
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(
                        Icons.public_rounded,
                        color: MusixColors.textMuted,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Discovery Region',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: _kTextPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Region',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: _kTextPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'Controls Trending Now and regional chart shelves',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: MusixColors.textMuted,
                      ),
                    ),
                    trailing: GestureDetector(
                      onTap: pickRegion,
                      child: Text(
                        preferredRegion,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: MusixColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    onTap: pickRegion,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              decoration: musixPanelDecoration(
                radius: 20,
                color: MusixColors.surface,
                borderColor: MusixColors.surfaceEdge,
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Pulse Audio v4.2.1-stable',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: MusixColors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Proudly built for music enthusiasts.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: MusixColors.textMuted.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'PRIVACY      TERMS      CREDITS',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: MusixColors.textMuted,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Center(
              child: OutlinedButton(
                onPressed: signOutUser,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(220, 42),
                  side: const BorderSide(color: MusixColors.surfaceEdge),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  foregroundColor: MusixColors.accent,
                ),
                child: const Text('LOG OUT'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.title,
    required this.trailing,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final String displayTrailing = trailing;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: _kTextPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: MusixColors.textMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 132),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              displayTrailing,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: _kTextPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<V?> _showSettingsSelectionSheet<T, V>({
  required BuildContext context,
  required String title,
  required String description,
  required V selectedValue,
  required List<T> items,
  required V Function(T item) valueOf,
  required String Function(T item) titleOf,
  String Function(T item)? subtitleOf,
}) {
  return showModalBottomSheet<V>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) {
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: _kTextPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: MusixColors.textMuted),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final T item = items[index];
                      final bool active = valueOf(item) == selectedValue;
                      return _SettingsSelectionTile(
                        title: titleOf(item),
                        subtitle: subtitleOf?.call(item),
                        active: active,
                        onTap: () => Navigator.of(context).pop(valueOf(item)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _SettingsSelectionTile extends StatelessWidget {
  const _SettingsSelectionTile({
    required this.title,
    required this.active,
    required this.onTap,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? MusixColors.accent.withValues(alpha: 0.10)
          : MusixColors.surfaceRaised.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: active
                  ? MusixColors.accent.withValues(alpha: 0.75)
                  : MusixColors.surfaceEdge,
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: active ? MusixColors.accent : _kTextPrimary,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w600,
                      ),
                    ),
                    if ((subtitle ?? '').isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: MusixColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (active)
                const Icon(Icons.check_rounded, color: MusixColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
