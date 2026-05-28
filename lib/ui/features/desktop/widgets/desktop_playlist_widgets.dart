part of '../../../musix_ui.dart';

class _DesktopPlaylistBox extends StatelessWidget {
  const _DesktopPlaylistBox({
    required this.controller,
    required this.title,
    required this.seed,
    required this.songs,
    this.playlist,
    this.subtitle,
  });

  final MusixController controller;
  final String title;
  final String seed;
  final List<LibrarySong> songs;
  final UserPlaylist? playlist;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final LibrarySong? leadSong = songs.isEmpty ? null : songs.first;
    final Widget artwork = ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: 104,
        height: 104,
        child: leadSong != null
            ? _Artwork(
                seed: seed,
                title: title,
                size: 104,
                imageUrl: leadSong.artworkUrl,
              )
            : Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[Color(0xFF6C2D08), Color(0xFF1B0D05)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Icon(
                  Icons.queue_music_rounded,
                  color: Color(0xFFFFD1AD),
                  size: 38,
                ),
              ),
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: () {
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
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF23100C),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFF342018)),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth >= 300;

            if (wide) {
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 150),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    artwork,

                    const SizedBox(width: 18),
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
                                color: const Color(0xFFFFE2D2),
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                height: 0.98,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              subtitle ??
                                  '${playlist?.displaySongCount ?? songs.length} songs',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _musixBodyTextStyle(
                                color: const Color(0xFFD3A689),
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFF8C5835),
                      size: 26,
                    ),
                  ],
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                artwork,
                const SizedBox(height: 16),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _musixBodyTextStyle(
                    color: const Color(0xFFFFE2D2),
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 0.98,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle ??
                      '${playlist?.displaySongCount ?? songs.length} songs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _musixBodyTextStyle(
                    color: const Color(0xFFD3A689),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DesktopLibraryPlaylistEntry {
  const _DesktopLibraryPlaylistEntry({
    required this.title,
    required this.seed,
    required this.songs,
    this.playlist,
    this.subtitle,
  });

  final String title;
  final String seed;
  final List<LibrarySong> songs;
  final UserPlaylist? playlist;
  final String? subtitle;
}

class _DesktopSettingsActionRow extends StatelessWidget {
  const _DesktopSettingsActionRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFFFFE6D5),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFFC89373)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Align(alignment: Alignment.centerRight, child: trailing),
        ),
      ],
    );

    if (onTap == null) {
      return content;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: content,
      ),
    );
  }
}
