part of '../../../musix_ui.dart';

class _DesktopWindowTitleBar extends StatefulWidget {
  const _DesktopWindowTitleBar();

  @override
  State<_DesktopWindowTitleBar> createState() => _DesktopWindowTitleBarState();
}

class _DesktopWindowTitleBarState extends State<_DesktopWindowTitleBar>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_syncMaximizedState());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximizedState() async {
    final bool maximized = await windowManager.isMaximized();
    if (!mounted) {
      return;
    }
    setState(() => _isMaximized = maximized);
  }

  Future<void> _toggleMaximize() async {
    if (_isMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await _syncMaximizedState();
  }

  @override
  void onWindowMaximize() {
    if (mounted) {
      setState(() => _isMaximized = true);
    }
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) {
      setState(() => _isMaximized = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              onDoubleTap: _toggleMaximize,
              child: DragToMoveArea(
                child: Container(
                  height: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF130806).withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF3A1C11)),
                  ),
                  child: Row(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.asset(
                          'assets/icons/Musix - Windows.png',
                          width: 20,
                          height: 20,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Musix',
                        style: _musixHeadingTextStyle(
                          color: _kTextPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _DesktopTitleBarActionButton(
            icon: Icons.minimize_rounded,
            onTap: () => unawaited(windowManager.minimize()),
            iconOffset: const Offset(0, -5),
          ),
          const SizedBox(width: 10),
          _DesktopTitleBarActionButton(
            icon: _isMaximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            onTap: _toggleMaximize,
          ),
          const SizedBox(width: 10),
          _DesktopTitleBarActionButton(
            icon: Icons.close_rounded,
            onTap: () => windowManager.close(),
            hoverColor: const Color.fromARGB(255, 121, 27, 0),
          ),
        ],
      ),
    );
  }
}

class _DesktopTitleBarActionButton extends StatefulWidget {
  const _DesktopTitleBarActionButton({
    required this.icon,
    required this.onTap,
    this.hoverColor = const Color(0xFF3A1B10),
    this.iconOffset = Offset.zero,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color hoverColor;
  final Offset iconOffset;

  @override
  State<_DesktopTitleBarActionButton> createState() =>
      _DesktopTitleBarActionButtonState();
}

class _DesktopTitleBarActionButtonState
    extends State<_DesktopTitleBarActionButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 52,
          height: 44,
          decoration: BoxDecoration(
            color: _hovering ? widget.hoverColor : const Color(0xFF2B130C),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _hovering
                  ? const Color(0xFF6A341D)
                  : const Color(0xFF4A2416),
            ),
          ),
          child: Center(
            child: Transform.translate(
              offset: widget.iconOffset,
              child: Icon(
                widget.icon,
                color: _hovering
                    ? const Color(0xFFD7D0CA)
                    : const Color(0xFFAAA39D),
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}