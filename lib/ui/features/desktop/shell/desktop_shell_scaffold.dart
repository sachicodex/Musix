part of '../../../musix_ui.dart';

class _DesktopShellScaffold extends StatelessWidget {
  const _DesktopShellScaffold({
    required this.controller,
    required this.destination,
    required this.destinations,
    required this.pageIndex,
    required this.children,
    required this.onDestinationChanged,
    required this.onOpenPlayer,
  });

  final MusixController controller;
  final AppDestination destination;
  final List<AppDestination> destinations;
  final int pageIndex;
  final List<Widget> children;
  final ValueChanged<AppDestination> onDestinationChanged;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showPlayerRail =
            controller.nowPlayingState.value.song != null;
        final bool compactSidebar = constraints.maxWidth < 1100;
        final bool windowsDesktop =
            !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
        final double playerRailWidth = constraints.maxWidth >= 1500 ? 360 : 320;

        return Scaffold(
          backgroundColor: const Color(0xFF0B0403),
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[_kPageTop, _kPageMiddle, _kPageBottom],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
                child: Column(
                  children: <Widget>[
                    if (windowsDesktop) ...<Widget>[
                      const _DesktopWindowTitleBar(),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _DesktopSidebar(
                            controller: controller,
                            destination: destination,
                            destinations: destinations,
                            compact: compactSidebar,
                            onDestinationChanged: onDestinationChanged,
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF140805,
                                ).withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(32),
                                border: Border.all(
                                  color: const Color(
                                    0xFF3A1C11,
                                  ).withValues(alpha: 0.9),
                                ),
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.14),
                                    blurRadius: 24,
                                    offset: const Offset(0, 16),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(32),
                                child: IndexedStack(
                                  index: pageIndex,
                                  children: children,
                                ),
                              ),
                            ),
                          ),
                          if (showPlayerRail) ...<Widget>[
                            const SizedBox(width: 18),
                            SizedBox(
                              width: playerRailWidth,
                              child: _DesktopNowPlayingRail(
                                controller: controller,
                                onOpenPlayer: onOpenPlayer,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}