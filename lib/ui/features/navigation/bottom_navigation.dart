part of '../../musix_ui.dart';

class _MusixBottomNav extends StatelessWidget {
  const _MusixBottomNav({
    required this.destination,
    required this.onDestinationChanged,
  });

  final AppDestination destination;
  final ValueChanged<AppDestination> onDestinationChanged;

  @override
  Widget build(BuildContext context) {
    // Match the provided design: 4 tabs.
    final List<_BottomItem> items = <_BottomItem>[
      const _BottomItem(AppDestination.home, 'Home', Icons.home_rounded),
      const _BottomItem(AppDestination.search, 'Search', Icons.search_rounded),
      const _BottomItem(
        AppDestination.library,
        'Library',
        Icons.library_music_rounded,
      ),
      const _BottomItem(
        AppDestination.settings,
        'Profile',
        Icons.person_rounded,
      ),
    ];

    return Container(
      height: 85,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[Color(0xFF241007), Color(0xFF180904)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: items.map((_BottomItem item) {
          final bool selected = destination == item.destination;
          return Expanded(
            child: _MusixBottomNavItem(
              icon: item.icon,
              label: item.label,
              selected: selected,
              onTap: () => onDestinationChanged(item.destination),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _MobileBottomChrome extends StatelessWidget {
  const _MobileBottomChrome({
    required this.controller,
    required this.onOpenPlayer,
    required this.child,
  });

  final MusixController controller;
  final VoidCallback onOpenPlayer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (controller.miniPlayerSong != null)
            RepaintBoundary(
              child: _MiniPlayer(
                controller: controller,
                onOpenPlayer: onOpenPlayer,
              ),
            ),
          child,
        ],
      ),
    );
  }
}

class _BottomItem {
  const _BottomItem(this.destination, this.label, this.icon);
  final AppDestination destination;
  final String label;
  final IconData icon;
}

class _MusixBottomNavItem extends StatelessWidget {
  const _MusixBottomNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const Color active = Color(0xFFE06A2D);
    const Color inactive = Color(0xFFD4C0B3);

    return _ApplePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 54,
              height: 42,
              decoration: BoxDecoration(
                color: selected
                    ? active.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: selected ? active : inactive, size: 24),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: selected ? active : inactive,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                height: 1.0,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
