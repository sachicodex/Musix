part of '../musix_ui.dart';

Future<bool> _showMusixConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  Color? confirmColor,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: musixDialogSecondaryButtonStyle(),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: musixDialogPrimaryButtonStyle(backgroundColor: confirmColor),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

Future<UserPlaylist?> _promptForPlaylistCreation(
  BuildContext context,
  MusixController controller,
) async {
  final String? name = await _showPlaylistNameDialog(
    context: context,
    title: 'Create playlist',
    actionLabel: 'Create',
    hintText: 'New playlist',
  );

  if (name == null || name.trim().isEmpty) {
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  return controller.createPlaylist(name);
}

Future<void> _showCreatePlaylistDialog(
  BuildContext context,
  MusixController controller,
) async {
  await _promptForPlaylistCreation(context, controller);
}

Future<void> _showRenamePlaylistDialog(
  BuildContext context,
  MusixController controller,
  UserPlaylist playlist,
) async {
  final String? name = await _showPlaylistNameDialog(
    context: context,
    title: 'Rename playlist',
    actionLabel: 'Save',
    hintText: 'Playlist name',
    initialValue: playlist.name,
  );
  if (name == null || !context.mounted) {
    return;
  }
  await controller.renamePlaylist(playlist.id, name);
}

Future<String?> _showPlaylistNameDialog({
  required BuildContext context,
  required String title,
  required String actionLabel,
  required String hintText,
  String initialValue = '',
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext context) => _PlaylistNameDialog(
      title: title,
      actionLabel: actionLabel,
      hintText: hintText,
      initialValue: initialValue,
    ),
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.actionLabel,
    required this.hintText,
    this.initialValue = '',
  });

  final String title;
  final String actionLabel;
  final String hintText;
  final String initialValue;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _input;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final String trimmed = _input.text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final bool canCreate = _input.text.trim().isNotEmpty;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
        surfaceTintColor: Theme.of(context).dialogTheme.surfaceTintColor,
        shape: Theme.of(context).dialogTheme.shape,
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.title,
                style: Theme.of(context).dialogTheme.titleTextStyle,
              ),
              const SizedBox(height: 26),
              TextField(
                controller: _input,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                style: _musixBodyTextStyle(color: _kTextPrimary, fontSize: 18),
                cursorColor: _kAccent,
                decoration: musixInputDecoration(
                  hintText: widget.hintText,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                  borderRadius: 18,
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(),
                    style: musixDialogSecondaryButtonStyle(),
                    child: Text(
                      'Cancel',
                      style: _musixBodyTextStyle(fontSize: 16),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: canCreate ? _submit : null,
                    style: musixDialogPrimaryButtonStyle(),
                    child: Text(
                      widget.actionLabel,
                      style: _musixBodyTextStyle(
                        fontSize: 16,
                        color: MusixColors.shellBackground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showAddToPlaylistDialog(
  BuildContext context,
  MusixController controller,
  LibrarySong song,
) async {
  final _AddToPlaylistSelection? selection =
      await showDialog<_AddToPlaylistSelection>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text('Add "${song.title}"'),
            content: SizedBox(
              width: 380,
              child: AnimatedBuilder(
                animation: controller,
                builder: (BuildContext context, _) {
                  final List<UserPlaylist> playlists = controller.playlists;
                  return ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.add_circle_outline_rounded,
                          color: _kAccent,
                        ),
                        title: Text(
                          'Create new playlist',
                          style: _musixBodyTextStyle(
                            color: _kTextPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Create and save this song right away',
                          style: _musixBodyTextStyle(color: _kTextSecondary),
                        ),
                        onTap: () async {
                          final String? name = await _showPlaylistNameDialog(
                            context: context,
                            title: 'Create playlist',
                            actionLabel: 'Create',
                            hintText: 'New playlist',
                          );
                          if (name == null || !context.mounted) {
                            return;
                          }
                          Navigator.of(
                            context,
                          ).pop(_AddToPlaylistSelection.createNew(name));
                        },
                      ),
                      if (playlists.isNotEmpty) const Divider(height: 24),
                      if (playlists.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 4),
                          child: Text(
                            'No playlists yet. Create one to save this song.',
                            style: _musixBodyTextStyle(color: _kTextSecondary),
                          ),
                        ),
                      ...playlists.map(
                        (UserPlaylist playlist) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            playlist.name,
                            style: _musixBodyTextStyle(
                              color: _kTextPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${playlist.displaySongCount} songs',
                            style: _musixBodyTextStyle(color: _kTextSecondary),
                          ),
                          onTap: () {
                            Navigator.of(
                              context,
                            ).pop(_AddToPlaylistSelection.existing(playlist));
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      );

  if (!context.mounted || selection == null) {
    return;
  }

  if (selection.createPlaylistName != null) {
    final UserPlaylist? playlist = await _promptForPlaylistCreationFromName(
      context,
      controller,
      selection.createPlaylistName!,
    );
    if (playlist == null || !context.mounted) {
      return;
    }
    unawaited(controller.addSongToPlaylist(playlist.id, song.id));
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) {
      return;
    }
    _showMusixSnackBar(context, 'Saved to ${playlist.name}');
    return;
  }

  final UserPlaylist playlist = selection.playlist!;
  unawaited(controller.addSongToPlaylist(playlist.id, song.id));
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) {
    return;
  }
  _showMusixSnackBar(context, 'Added to ${playlist.name}');
}

Future<UserPlaylist?> _promptForPlaylistCreationFromName(
  BuildContext context,
  MusixController controller,
  String name,
) async {
  final String trimmed = name.trim();
  if (trimmed.isEmpty || !context.mounted) {
    return null;
  }
  return controller.createPlaylist(trimmed);
}

class _AddToPlaylistSelection {
  const _AddToPlaylistSelection._({this.playlist, this.createPlaylistName});

  const _AddToPlaylistSelection.existing(UserPlaylist playlist)
    : this._(playlist: playlist);

  const _AddToPlaylistSelection.createNew(String name)
    : this._(createPlaylistName: name);

  final UserPlaylist? playlist;
  final String? createPlaylistName;
}

List<Color> _gradientFor(String seed, ColorScheme scheme) {
  final int hash = seed.hashCode;
  final double hue = (hash % 360).toDouble();
  return <Color>[
    HSLColor.fromAHSL(
      1,
      hue,
      0.58,
      scheme.brightness == Brightness.dark ? 0.34 : 0.68,
    ).toColor(),
    HSLColor.fromAHSL(
      1,
      (hue + 40) % 360,
      0.54,
      scheme.brightness == Brightness.dark ? 0.2 : 0.84,
    ).toColor(),
  ];
}

String _initials(String text) {
  final List<String> words = text
      .split(RegExp(r'\s+'))
      .where((String item) => item.trim().isNotEmpty)
      .take(2)
      .toList();
  if (words.isEmpty) {
    return 'OT';
  }
  return words.map((String item) => item.characters.first.toUpperCase()).join();
}

String _formatClock(Duration duration) {
  if (duration.inMilliseconds <= 0) {
    return '0:00';
  }
  final int minutes = duration.inMinutes.remainder(60);
  final int seconds = duration.inSeconds.remainder(60);
  final int hours = duration.inHours;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${duration.inMinutes}:${seconds.toString().padLeft(2, '0')}';
}

class _WindowsLocalImportPanel extends StatelessWidget {
  const _WindowsLocalImportPanel({required this.controller});

  final MusixController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.supportsLocalFileImport) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _PersonalizationHintCard(
          message:
              'Import a music folder or individual audio files to build your offline library on Windows.',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton.icon(
              onPressed: controller.scanning
                  ? null
                  : () => controller.importFolder(),
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Import folder'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF8A2A),
                foregroundColor: const Color(0xFF1A0A04),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: controller.scanning
                  ? null
                  : () => controller.importFiles(),
              icon: const Icon(Icons.audio_file_outlined, size: 18),
              label: const Text('Add files'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFFC8A9),
                side: const BorderSide(color: Color(0x66FF8A2A)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

IconData _repeatIcon(PlaylistMode mode) {
  return switch (mode) {
    PlaylistMode.none => Icons.repeat_rounded,
    PlaylistMode.loop => Icons.repeat_rounded,
    PlaylistMode.single => Icons.repeat_one_rounded,
  };
}
