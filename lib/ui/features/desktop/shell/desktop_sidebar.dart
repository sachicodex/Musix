part of '../../../musix_ui.dart';

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.controller,
    required this.destination,
    required this.destinations,
    required this.compact,
    required this.onDestinationChanged,
  });

  final MusixController controller;
  final AppDestination destination;
  final List<AppDestination> destinations;
  final bool compact;
  final ValueChanged<AppDestination> onDestinationChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: compact ? 92 : 232,
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 18,
        18,
        compact ? 14 : 18,
        18,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF130806).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: const Color(0xFF3A1C11).withValues(alpha: 0.92),
        ),
      ),
      child: Column(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: compact ? 54 : double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 0 : 16,
              vertical: compact ? 14 : 16,
            ),

            child: compact
                ? const Icon(
                    Icons.graphic_eq_rounded,
                    color: Color(0xFFFF9A46),
                    size: 24,
                  )
                : const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[],
                  ),
          ),
          for (int index = 0; index < destinations.length; index++) ...<Widget>[
            _DesktopSidebarButton(
              item: destinations[index],
              selected: destination == destinations[index],
              compact: compact,
              onTap: () => onDestinationChanged(destinations[index]),
            ),
            const SizedBox(height: 10),
          ],
          const Spacer(),
          if (!compact) _DesktopSidebarStatus(controller: controller),
        ],
      ),
    );
  }
}

class _DesktopSidebarButton extends StatefulWidget {
  const _DesktopSidebarButton({
    required this.item,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final AppDestination item;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_DesktopSidebarButton> createState() => _DesktopSidebarButtonState();
}

class _DesktopSidebarButtonState extends State<_DesktopSidebarButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool highlighted = widget.selected || _hovering;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: widget.selected
              ? const Color(0xFF3A1B0F)
              : highlighted
              ? const Color(0xFF1D0D09)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: widget.selected
                ? const Color(0xFF8A4A22)
                : const Color(0xFF2B140D),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: widget.onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 0 : 14,
              vertical: 12,
            ),
            child: widget.compact
                ? Icon(
                    widget.selected
                        ? widget.item.selectedIcon
                        : widget.item.unselectedIcon,
                    color: widget.selected
                        ? const Color(0xFFFF9A46)
                        : _kTextSecondary,
                  )
                : Row(
                    children: <Widget>[
                      Icon(
                        widget.selected
                            ? widget.item.selectedIcon
                            : widget.item.unselectedIcon,
                        color: widget.selected
                            ? const Color(0xFFFF9A46)
                            : _kTextSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.item.label,
                          style: _musixBodyTextStyle(
                            color: widget.selected
                                ? _kTextPrimary
                                : _kTextSecondary.withValues(alpha: 0.92),
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w600,
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

class _DesktopSidebarStatus extends StatelessWidget {
  const _DesktopSidebarStatus({required this.controller});

  final MusixController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C0E0A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF342018)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            controller.isOfflineViewActive
                ? Icons.cloud_off_rounded
                : controller.scanning
                ? Icons.sync_rounded
                : Icons.library_music_rounded,
            size: 18,
            color: const Color(0xFFFF9A46),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              controller.isOfflineViewActive
                  ? 'Offline mode'
                  : controller.scanning
                  ? 'Scanning library'
                  : 'Library ready',
              style: _musixBodyTextStyle(
                color: _kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}