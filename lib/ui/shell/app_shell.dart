part of '../musix_ui.dart';

final GlobalKey<ScaffoldMessengerState> _musixScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
int _musixSnackBarRequestSerial = 0;

class MusixApp extends StatelessWidget {
  const MusixApp({super.key, required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _musixScaffoldMessengerKey,
      title: 'Musix',
      themeMode: ThemeMode.dark,
      builder: (BuildContext context, Widget? child) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            context.read<MusixController>().registerUserActivity(
              reason: 'pointer-down',
              throttle: true,
            );
          },
          onPointerMove: (_) {
            context.read<MusixController>().registerUserActivity(
              reason: 'pointer-move',
              throttle: true,
            );
          },
          onPointerSignal: (_) {
            context.read<MusixController>().registerUserActivity(
              reason: 'pointer-signal',
              throttle: true,
            );
          },
          child: Focus(
            canRequestFocus: false,
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is KeyDownEvent) {
                context.read<MusixController>().registerUserActivity(
                  reason: 'key-down',
                  throttle: true,
                );
              }
              if (event.logicalKey != LogicalKeyboardKey.space ||
                  event is! KeyDownEvent) {
                return KeyEventResult.ignored;
              }
              if (_focusedWidgetAcceptsTextInput()) {
                return KeyEventResult.ignored;
              }
              unawaited(context.read<MusixController>().togglePlayback());
              return KeyEventResult.handled;
            },
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
      ),
      theme: buildMusixTheme(),
      darkTheme: buildMusixTheme(),
      home: home,
    );
  }
}

class MusixAuthenticatedHome extends StatefulWidget {
  const MusixAuthenticatedHome({super.key});

  @override
  State<MusixAuthenticatedHome> createState() => _MusixAuthenticatedHomeState();
}

class _MusixAuthenticatedHomeState extends State<MusixAuthenticatedHome> {
  MusixController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final String? message = context
          .read<AuthService>()
          .takePendingSuccessMessage();
      if (message == null) {
        return;
      }
      _showMusixStatusSnackBar(
        context,
        message,
        backgroundColor: MusixColors.success,
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MusixController nextController = context.read<MusixController>();
    if (!identical(_controller, nextController)) {
      _controller?.removeListener(_handleControllerMessages);
      _controller = nextController;
      _controller?.addListener(_handleControllerMessages);
      _handleControllerMessages();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerMessages);
    super.dispose();
  }

  void _handleControllerMessages() {
    if (!mounted) {
      return;
    }
    final String? connectivityMessage = _controller?.takeConnectivityMessage();
    final String? cloudSyncMessage = connectivityMessage == null
        ? _controller?.takeCloudSyncMessage()
        : null;
    if (connectivityMessage == null && cloudSyncMessage == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (connectivityMessage != null) {
        _showMusixSnackBar(context, connectivityMessage);
        return;
      }
      _showMusixStatusSnackBar(
        context,
        cloudSyncMessage!,
        backgroundColor: MusixColors.error,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final MusixController controller = context.read<MusixController>();
    return _MusixStartupGate(controller: controller);
  }
}

class _MusixStartupGate extends StatefulWidget {
  const _MusixStartupGate({required this.controller});

  final MusixController controller;

  @override
  State<_MusixStartupGate> createState() => _MusixStartupGateState();
}

class _MusixStartupGateState extends State<_MusixStartupGate> {
  static const Duration _targetStartupDuration = Duration(seconds: 5);
  static const Duration _splashFadeOutDuration = Duration(milliseconds: 650);
  static const bool _debugInfiniteStartup = false;

  int _bootAttempt = 0;
  Object? _bootError;
  bool _ready = false;
  bool _splashVisible = true;
  Duration _measuredBootDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _beginBoot();
  }

  @override
  void didUpdateWidget(covariant _MusixStartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _beginBoot();
    }
  }

  Future<void> _beginBoot() async {
    final int attempt = ++_bootAttempt;
    AppLogger.info('StartupUI', 'Splash boot attempt $attempt started');
    setState(() {
      _bootError = null;
      _ready = false;
      _splashVisible = true;
      _measuredBootDuration = Duration.zero;
    });

    try {
      final Stopwatch stopwatch = Stopwatch()..start();
      await widget.controller.initialize();
      stopwatch.stop();
      final Duration bootDuration = stopwatch.elapsed;
      AppLogger.info(
        'StartupUI',
        'Splash boot attempt $attempt finished in ${bootDuration.inMilliseconds}ms',
      );
      final Duration holdDuration = _remainingStartupHold(bootDuration);
      if (holdDuration > Duration.zero) {
        await Future<void>.delayed(holdDuration);
      }
      if (!mounted || attempt != _bootAttempt) {
        return;
      }
      setState(() {
        _measuredBootDuration = bootDuration;
        _ready = !_debugInfiniteStartup;
      });
      if (!_debugInfiniteStartup) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || attempt != _bootAttempt) {
            return;
          }
          setState(() => _splashVisible = false);
        });
      }
    } catch (error) {
      AppLogger.error('StartupUI', 'Splash boot failed: $error');
      if (!mounted || attempt != _bootAttempt) {
        return;
      }
      setState(() {
        _bootError = error;
        _measuredBootDuration = Duration.zero;
      });
    }
  }

  Duration _remainingStartupHold(Duration bootDuration) {
    if (bootDuration >= _targetStartupDuration) {
      return Duration.zero;
    }
    return _targetStartupDuration - bootDuration;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (_ready) const MusixShell(key: ValueKey<String>('shell')),
        IgnorePointer(
          ignoring: !_splashVisible,
          child: AnimatedOpacity(
            opacity: _splashVisible ? 1.0 : 0.0,
            duration: _splashFadeOutDuration,
            curve: Curves.easeInOutCubic,
            child: _MusixStartupScreen(
              key: ValueKey<String>('startup-$_bootAttempt'),
              bootAttempt: _bootAttempt,
              controller: widget.controller,
              error: _bootError,
              measuredBootDuration: _measuredBootDuration,
              targetStartupDuration: _targetStartupDuration,
              onRetry: _beginBoot,
            ),
          ),
        ),
      ],
    );
  }
}

class _MusixStartupScreen extends StatefulWidget {
  const _MusixStartupScreen({
    super.key,
    required this.bootAttempt,
    required this.controller,
    required this.onRetry,
    required this.measuredBootDuration,
    required this.targetStartupDuration,
    this.error,
  });

  final int bootAttempt;
  final MusixController controller;
  final Object? error;
  final Duration measuredBootDuration;
  final Duration targetStartupDuration;
  final VoidCallback onRetry;

  @override
  State<_MusixStartupScreen> createState() => _MusixStartupScreenState();
}

class _MusixStartupScreenState extends State<_MusixStartupScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final AnimationController _timeline = AnimationController(
    vsync: this,
    duration: widget.targetStartupDuration,
  );
  late final Animation<double> _progressValue = CurvedAnimation(
    parent: _timeline,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _intro.forward();
    _timeline.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotionPreference();
  }

  @override
  void didUpdateWidget(covariant _MusixStartupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetStartupDuration != widget.targetStartupDuration) {
      _timeline.duration = widget.targetStartupDuration;
    }
    if (oldWidget.bootAttempt != widget.bootAttempt) {
      _timeline
        ..stop()
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _timeline.dispose();
    super.dispose();
  }

  void _syncMotionPreference() {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ??
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    if (reduceMotion) {
      _intro
        ..stop()
        ..value = 1.0;
      return;
    }
    if (!_intro.isCompleted && !_intro.isAnimating) {
      _intro.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Listenable animation = Listenable.merge(<Listenable>[
      _intro,
      _timeline,
    ]);
    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      body: AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, Widget? child) {
          final double wordOpacity = Curves.easeOutCubic.transform(
            (_displayedProgress * 1.1).clamp(0.0, 1.0),
          );
          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.0, -0.2),
                radius: 1.05,
                colors: <Color>[Color(0xFF161616), Color(0xFF080808)],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0xFF121212), Color(0xFF050505)],
                    ),
                  ),
                ),
                SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Opacity(
                        opacity: Curves.easeOutCubic.transform(_intro.value),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const _MusixSplashLogoBadge(),
                            const SizedBox(height: 16),
                            Opacity(
                              opacity: wordOpacity,
                              child: Text(
                                'MUSIX',
                                style: _musixHeadingTextStyle(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  fontSize: 30,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            _MusixSplashProgressBar(
                              width: 128,
                              height: 3,
                              progress: _progressValue,
                              baseColor: const Color(0xFF1E1E1E),
                              fillColor: _kAccent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.error != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(
                      minimum: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                      child: FilledButton.icon(
                        onPressed: widget.onRetry,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1E0D07),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: const BorderSide(color: Color(0xFF6D3928)),
                          ),
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(
                          'Try again',
                          style: _musixBodyTextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  double get _displayedProgress {
    if (widget.error != null) {
      return _timeline.value.clamp(0.0, 1.0);
    }
    if (!widget.controller.initialized && _timeline.isCompleted) {
      return 0.94;
    }
    return _timeline.value.clamp(0.0, 1.0);
  }
}

class _MusixSplashLogoBadge extends StatelessWidget {
  const _MusixSplashLogoBadge();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      height: 100,
      child: Center(
        child: Image.asset(
          'assets/icons/Musix - Full.png',
          width: 100,
          height: 100,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class _MusixSplashProgressBar extends StatelessWidget {
  const _MusixSplashProgressBar({
    required this.width,
    required this.height,
    required this.progress,
    required this.baseColor,
    required this.fillColor,
  });

  final double width;
  final double height;
  final Animation<double> progress;
  final Color baseColor;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: AnimatedBuilder(
          animation: progress,
          builder: (BuildContext context, _) {
            final double value = (0.08 + (0.92 * progress.value)).clamp(
              0.0,
              1.0,
            );
            return LinearProgressIndicator(
              value: value,
              minHeight: height,
              color: fillColor,
              backgroundColor: baseColor,
            );
          },
        ),
      ),
    );
  }
}

bool _focusedWidgetAcceptsTextInput() {
  for (
    FocusNode? node = FocusManager.instance.primaryFocus;
    node != null;
    node = node.parent
  ) {
    final BuildContext? focusedContext = node.context;
    if (focusedContext == null) {
      continue;
    }
    if (focusedContext.widget is EditableText ||
        focusedContext.findAncestorWidgetOfExactType<EditableText>() != null) {
      return true;
    }
  }
  return false;
}

bool _isBareBackspace(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return false;
  }
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  return event.logicalKey == LogicalKeyboardKey.backspace &&
      !keyboard.isControlPressed &&
      !keyboard.isMetaPressed &&
      !keyboard.isAltPressed;
}

class _ShortcutBinding {
  const _ShortcutBinding(this.activator, this.onInvoke);

  final ShortcutActivator activator;
  final VoidCallback onInvoke;
}

bool _handleShortcutBindings(
  KeyEvent event,
  Iterable<_ShortcutBinding> bindings, {
  bool disableWhenTextFieldFocused = true,
}) {
  if (disableWhenTextFieldFocused && _focusedWidgetAcceptsTextInput()) {
    return false;
  }
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  for (final _ShortcutBinding binding in bindings) {
    if (binding.activator.accepts(event, keyboard)) {
      binding.onInvoke();
      return true;
    }
  }
  return false;
}

bool _routeIsCurrent(BuildContext context) {
  final ModalRoute<dynamic>? route = ModalRoute.of(context);
  return route == null || route.isCurrent;
}

TextStyle _musixBodyTextStyle({
  Color? color,
  double? fontSize,
  FontWeight? fontWeight,
  FontStyle? fontStyle,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: musixBodyFontFamily,
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    letterSpacing: letterSpacing,
    height: height,
  );
}

TextStyle _musixHeadingTextStyle({
  Color? color,
  double? fontSize,
  FontWeight? fontWeight,
  FontStyle? fontStyle,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: musixHeadingFontFamily,
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    letterSpacing: letterSpacing,
    height: height,
  );
}

@immutable
class _ShellChromeState {
  const _ShellChromeState({
    required this.scanning,
    required this.hasMiniPlayer,
    required this.hasNowPlaying,
  });

  final bool scanning;
  final bool hasMiniPlayer;
  final bool hasNowPlaying;

  @override
  bool operator ==(Object other) {
    return other is _ShellChromeState &&
        scanning == other.scanning &&
        hasMiniPlayer == other.hasMiniPlayer &&
        hasNowPlaying == other.hasNowPlaying;
  }

  @override
  int get hashCode => Object.hash(scanning, hasMiniPlayer, hasNowPlaying);
}

class MusixShell extends StatefulWidget {
  const MusixShell({super.key});

  @override
  State<MusixShell> createState() => _MusixShellState();
}

class _MusixShellState extends State<MusixShell> {
  static const List<AppDestination> _mainDestinations = <AppDestination>[
    AppDestination.home,
    AppDestination.search,
    AppDestination.library,
    AppDestination.settings,
  ];

  AppDestination _destination = AppDestination.home;
  LibraryFilter _libraryFilter = LibraryFilter.all;
  late final PageController _pageController;
  late final KeyEventCallback _shortcutHandler;
  final Set<AppDestination> _activatedDestinations = <AppDestination>{
    AppDestination.home,
  };
  bool _deferredCloudLoadStarted = false;
  int _searchFocusRequestSerial = 0;
  double _shellSwipeDx = 0;
  int get _destinationPageIndex => _mainDestinations.indexOf(_destination);

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _destinationPageIndex);
    _shortcutHandler = _handleShortcutKeyEvent;
    HardwareKeyboard.instance.addHandler(_shortcutHandler);
    context.read<MusixController>().addListener(_maybeStartDeferredCloudLoad);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        context.read<MusixController>().ensureNotificationPermissionIfNeeded(),
      );
      _maybeStartDeferredCloudLoad();
    });
  }

  void _preactivateDestination(AppDestination destination) {
    if (_activatedDestinations.contains(destination) || !mounted) {
      return;
    }
    setState(() {
      _activatedDestinations.add(destination);
    });
  }

  void _onShellSwipeStart(DragStartDetails details) {
    _shellSwipeDx = 0;
  }

  void _onShellSwipeUpdate(DragUpdateDetails details) {
    _shellSwipeDx += details.delta.dx;
  }

  void _onShellSwipeEnd(DragEndDetails details) {
    const double minDistance = 64;
    const double minVelocity = 280;
    final double velocity = details.primaryVelocity ?? 0;

    final bool swipeLeft =
        _shellSwipeDx < -minDistance || velocity < -minVelocity;
    final bool swipeRight =
        _shellSwipeDx > minDistance || velocity > minVelocity;

    if (swipeLeft) {
      _goToAdjacentDestination(1);
    } else if (swipeRight) {
      _goToAdjacentDestination(-1);
    }
    _shellSwipeDx = 0;
  }

  void _goToAdjacentDestination(int delta) {
    final int nextIndex = _destinationPageIndex + delta;
    if (nextIndex < 0 || nextIndex >= _mainDestinations.length) {
      return;
    }
    _setDestination(_mainDestinations[nextIndex]);
  }

  @override
  void dispose() {
    context.read<MusixController>().removeListener(
      _maybeStartDeferredCloudLoad,
    );
    HardwareKeyboard.instance.removeHandler(_shortcutHandler);
    _pageController.dispose();
    super.dispose();
  }

  void _maybeStartDeferredCloudLoad() {
    if (!mounted || _deferredCloudLoadStarted) {
      return;
    }
    final MusixController controller = context.read<MusixController>();
    if (!controller.homeRefreshResolvedOnce) {
      return;
    }
    _deferredCloudLoadStarted = true;
    unawaited(controller.loadUserDataFromCloud(force: true));
  }

  @override
  Widget build(BuildContext context) {
    return Selector<MusixController, _ShellChromeState>(
      selector: (_, MusixController controller) => _ShellChromeState(
        scanning: controller.scanning,
        hasMiniPlayer: controller.miniPlayerSong != null,
        hasNowPlaying: controller.nowPlayingState.value.song != null,
      ),
      builder: (BuildContext context, _ShellChromeState chrome, Widget? _) {
        final MusixController controller = context.read<MusixController>();
        final bool desktop = _isDesktopPlatform();
        final bool wide = MediaQuery.sizeOf(context).width >= 960;
        final List<Widget> pages = _mainDestinations
            .map(
              (AppDestination destination) => KeyedSubtree(
                key: ValueKey<AppDestination>(destination),
                child: _activatedDestinations.contains(destination)
                    ? _buildPageForDestination(context, controller, destination)
                    : const SizedBox.shrink(),
              ),
            )
            .toList(growable: false);

        if (desktop) {
          return _DesktopShellScaffold(
            controller: controller,
            destination: _destination,
            destinations: _mainDestinations,
            pageIndex: _destinationPageIndex,
            onDestinationChanged: _setDestination,
            onOpenPlayer: () {
              if (!chrome.hasNowPlaying) {
                return;
              }
              unawaited(_openPlayer(context, controller));
            },
            children: pages,
          );
        }

        final Widget content = Column(
          children: <Widget>[
            if (chrome.scanning)
              const LinearProgressIndicator(
                minHeight: 3,
                color: _kAccent,
                backgroundColor: Color(0xFF3A170C),
              ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: _onShellSwipeStart,
                onHorizontalDragUpdate: _onShellSwipeUpdate,
                onHorizontalDragEnd: _onShellSwipeEnd,
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (int index) {
                    final AppDestination destination = _mainDestinations[index];
                    _clearSearchIfNeeded(destination);
                    _markDestinationActivated(destination);
                    if (_destination != destination && mounted) {
                      setState(() => _destination = destination);
                    }
                  },
                  children: pages,
                ),
              ),
            ),
            if (wide && chrome.hasMiniPlayer)
              _MiniPlayer(
                controller: controller,
                onOpenPlayer: () => _openPlayer(context, controller),
              ),
          ],
        );

        return Scaffold(
          extendBody: true,
          backgroundColor: const Color(0xFF120503),
          body: Row(
            children: <Widget>[
              if (wide)
                NavigationRail(
                  selectedIndex: _destinationPageIndex,
                  extended: MediaQuery.sizeOf(context).width >= 1240,
                  onDestinationSelected: (int index) {
                    _setDestination(_mainDestinations[index]);
                  },
                  destinations: _mainDestinations
                      .map(
                        (AppDestination item) => NavigationRailDestination(
                          icon: Icon(item.unselectedIcon),
                          selectedIcon: Icon(item.selectedIcon),
                          label: Text(item.label),
                        ),
                      )
                      .toList(),
                ),
              Expanded(child: content),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : _MobileBottomChrome(
                  controller: controller,
                  onOpenPlayer: () => _openPlayer(context, controller),
                  child: _MusixBottomNav(
                    destination: _destination,
                    onDestinationChanged: (AppDestination value) {
                      _setDestination(value);
                    },
                  ),
                ),
        );
      },
    );
  }

  void _setDestination(AppDestination destination) {
    if (_destination == destination) {
      return;
    }
    _clearSearchIfNeeded(destination);
    final int pageIndex = _mainDestinations.indexOf(destination);
    if (pageIndex < 0) {
      return;
    }
    setState(() {
      _destination = destination;
      _activatedDestinations.add(destination);
    });
    if (_pageController.hasClients) {
      unawaited(
        _pageController.animateToPage(
          pageIndex,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _markDestinationActivated(AppDestination destination) {
    _preactivateDestination(destination);
  }

  void _clearSearchIfNeeded(AppDestination nextDestination) {
    if (_destination == AppDestination.search &&
        nextDestination != AppDestination.search) {
      context.read<MusixController>().clearSearchState();
    }
  }

  Widget _buildPageForDestination(
    BuildContext context,
    MusixController controller,
    AppDestination destination,
  ) {
    return switch (destination) {
      AppDestination.home => _HomeScreen(
        key: const ValueKey<String>('home'),
        controller: controller,
        onOpenSearch: () => _setDestination(AppDestination.search),
      ),
      AppDestination.library => _LibraryScreen(
        key: const ValueKey<String>('library'),
        controller: controller,
        isActive: _destination == AppDestination.library,
        filter: _libraryFilter,
        onFilterChanged: (LibraryFilter value) {
          setState(() => _libraryFilter = value);
        },
      ),
      AppDestination.search => _SearchScreen(
        key: const ValueKey<String>('search'),
        controller: controller,
        isActive: _destination == AppDestination.search,
        focusRequestSerial: _searchFocusRequestSerial,
      ),
      AppDestination.settings => _ProfileScreen(
        key: const ValueKey<String>('profile'),
        controller: controller,
      ),
    };
  }

  Future<void> _openPlayer(
    BuildContext context,
    MusixController controller,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            _PlayerScreen(controller: controller),
      ),
    );
  }

  bool _handleShortcutKeyEvent(KeyEvent event) {
    if (!_isDesktopPlatform() ||
        !mounted ||
        !_routeIsCurrent(context) ||
        _focusedWidgetAcceptsTextInput()) {
      return false;
    }
    final MusixController controller = context.read<MusixController>();
    return _handleShortcutBindings(event, <_ShortcutBinding>[
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit1,
          control: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[0]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit2,
          control: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[1]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit3,
          control: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[2]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit4,
          control: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[3]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit1,
          meta: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[0]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit2,
          meta: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[1]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit3,
          meta: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[2]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.digit4,
          meta: true,
          includeRepeats: false,
        ),
        () => _setDestination(_mainDestinations[3]),
      ),
      _ShortcutBinding(
        const SingleActivator(
          LogicalKeyboardKey.arrowUp,
          includeRepeats: false,
        ),
        () {
          if (controller.nowPlayingState.value.song == null) {
            return;
          }
          unawaited(_openPlayer(context, controller));
        },
      ),
      _ShortcutBinding(
        const SingleActivator(LogicalKeyboardKey.keyS, includeRepeats: false),
        _openSearchReady,
      ),
      _ShortcutBinding(
        const SingleActivator(LogicalKeyboardKey.keyL, includeRepeats: false),
        () => unawaited(_likeCurrentSong(controller)),
      ),
      _ShortcutBinding(
        const SingleActivator(LogicalKeyboardKey.keyD, includeRepeats: false),
        () => unawaited(_dislikeCurrentSong(controller)),
      ),
    ]);
  }

  void _openSearchReady() {
    setState(() {
      _searchFocusRequestSerial += 1;
    });
    _setDestination(AppDestination.search);
  }

  Future<void> _likeCurrentSong(MusixController controller) async {
    final String? songId = controller.nowPlayingState.value.song?.id;
    if (songId == null) {
      return;
    }
    await controller.likeSong(songId);
  }

  Future<void> _dislikeCurrentSong(MusixController controller) async {
    final String? songId = controller.nowPlayingState.value.song?.id;
    if (songId == null) {
      return;
    }
    await controller.dislikeSong(songId);
  }
}

const Color _kPageTop = MusixColors.pageTop;
const Color _kPageMiddle = MusixColors.pageMiddle;
const Color _kPageBottom = MusixColors.pageBottom;
const Color _kSurface = MusixColors.surface;
const Color _kSurfaceEdge = MusixColors.surfaceEdge;
const Color _kAccent = MusixColors.accent;
const Color _kTextPrimary = MusixColors.textPrimary;
const Color _kTextSecondary = MusixColors.textSecondary;
const Color _kSongCardSurface = MusixColors.songCardSurface;
const Color _kSongCardTitle = MusixColors.songCardTitle;
const Color _kSongCardSubtitle = MusixColors.songCardSubtitle;
const Color _kSongCardMeta = MusixColors.songCardMeta;
const Color _kSongCardBorder = MusixColors.songCardBorder;
const double _kScreenHorizontalPadding = 24;
const double _kScreenTopPadding = 10;
const double _kScreenBottomPadding = 28;
const double _kMobileBottomNavHeight = 85;
const double _kMiniPlayerReservedHeight = 96;

EdgeInsets _rootScreenContentPadding(
  BuildContext context, {
  required bool hasMiniPlayer,
}) {
  final bool wide = MediaQuery.sizeOf(context).width >= 960;
  final double bottomInset = wide
      ? _kScreenBottomPadding
      : _kScreenBottomPadding +
            _kMobileBottomNavHeight +
            (hasMiniPlayer ? _kMiniPlayerReservedHeight : 0);
  return EdgeInsets.fromLTRB(
    _kScreenHorizontalPadding,
    _kScreenTopPadding,
    _kScreenHorizontalPadding,
    bottomInset,
  );
}

BoxDecoration _musixPageDecoration() {
  return musixPageDecoration();
}

ScaffoldMessengerState? _musixRootMessenger([
  ScaffoldMessengerState? fallback,
]) {
  return _musixScaffoldMessengerKey.currentState ?? fallback;
}

Future<T?> _runWithRootMessenger<T>(
  FutureOr<T> Function(ScaffoldMessengerState messenger) action, {
  ScaffoldMessengerState? fallback,
}) {
  final Completer<T?> completer = Completer<T?>();

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final ScaffoldMessengerState? messenger = _musixRootMessenger(fallback);
    if (messenger == null) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      return;
    }
    try {
      final T result = await action(messenger);
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    } catch (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  });

  return completer.future;
}

void _showMusixSnackBar(BuildContext context, String message) {
  _showMusixStatusSnackBar(
    context,
    message,
    backgroundColor: _kSurface,
    textStyle: _musixBodyTextStyle(
      color: _kTextPrimary,
      fontWeight: FontWeight.w600,
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: _kSurfaceEdge),
    ),
    behavior: SnackBarBehavior.floating,
  );
}

void _showMusixStatusSnackBar(
  BuildContext context,
  String message, {
  required Color backgroundColor,
  TextStyle? textStyle,
  ShapeBorder? shape,
  SnackBarBehavior? behavior,
}) {
  final int requestSerial = ++_musixSnackBarRequestSerial;
  final ScaffoldMessengerState fallback = ScaffoldMessenger.of(context);
  unawaited(
    _runWithRootMessenger<void>(
      (ScaffoldMessengerState messenger) async {
        if (requestSerial != _musixSnackBarRequestSerial) {
          return;
        }
        messenger.removeCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            backgroundColor: backgroundColor,
            behavior: behavior,
            shape: shape,
            content: Text(
              message,
              style: textStyle,
            ),
          ),
        );
      },
      fallback: fallback,
    ),
  );
}

class _MusixLoader extends StatelessWidget {
  const _MusixLoader({
    required this.color,
    this.size = 18,
    this.strokeWidth = 2.2,
  });

  final Color color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: strokeWidth,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }
}

Future<bool> _showMusixUndoSnackBarWithMessenger(
  ScaffoldMessengerState messenger,
  String message, {
  String actionLabel = 'Undo',
  Duration duration = const Duration(seconds: 5),
}) async {
  final SnackBarClosedReason? reason =
      await _runWithRootMessenger<SnackBarClosedReason>(
        (ScaffoldMessengerState resolvedMessenger) async {
          resolvedMessenger.removeCurrentSnackBar();
          final ScaffoldFeatureController<
            SnackBar,
            SnackBarClosedReason
          > controller = resolvedMessenger.showSnackBar(
            SnackBar(
              persist: false,
              duration: duration,
              backgroundColor: _kSurface,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: _kSurfaceEdge),
              ),
              content: Text(
                message,
                style: _musixBodyTextStyle(
                  color: _kTextPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              action: SnackBarAction(
                label: actionLabel,
                textColor: _kAccent,
                onPressed: () {},
              ),
            ),
          );
          return controller.closed;
        },
        fallback: messenger,
      );
  return reason == SnackBarClosedReason.action;
}

class _NetworkUnavailablePanel extends StatelessWidget {
  const _NetworkUnavailablePanel({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.icon = Icons.wifi_off_rounded,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF35130A), Color(0xFF160806)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0x55FF9E63)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.34),
            blurRadius: 30,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -18,
            top: -16,
            child: Container(
              width: 118,
              height: 118,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF8A2A).withValues(alpha: 0.10),
              ),
            ),
          ),
          Positioned(
            left: -12,
            bottom: -20,
            child: Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFF8A2A).withValues(alpha: 0.18),
                  border: Border.all(color: const Color(0x55FFC39B)),
                ),
                child: Icon(icon, color: const Color(0xFFFFB784), size: 28),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: _musixBodyTextStyle(
                  color: _kTextPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                style: _musixBodyTextStyle(
                  color: _kTextSecondary.withValues(alpha: 0.92),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  if (actionLabel != null && onAction != null)
                    FilledButton.icon(
                      onPressed: onAction,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF8A2A),
                        foregroundColor: const Color(0xFF2D1308),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      icon: const Icon(Icons.wifi_find_rounded),
                      label: Text(
                        actionLabel!,
                        style: _musixBodyTextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
