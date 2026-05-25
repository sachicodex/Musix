part of '../../../musix_ui.dart';

class _DesktopPageScrollView extends StatelessWidget {
  const _DesktopPageScrollView({required this.child, this.controller});

  final Widget child;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          if (notification is UserScrollNotification ||
              notification is ScrollUpdateNotification) {
            context.read<MusixController>().registerScrollActivity();
          }
          return false;
        },
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          children: <Widget>[child],
        ),
      ),
    );
  }
}

class _DesktopPanel extends StatelessWidget {
  const _DesktopPanel({
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFF1C0E0A).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF342018)),
      ),
      child: child,
    );
  }
}

class _DesktopPanelTitle extends StatelessWidget {
  const _DesktopPanelTitle({this.eyebrow, this.title, this.centered = false});

  final String? eyebrow;
  final String? title;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: centered
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: <Widget>[
              if (eyebrow != null)
                Text(
                  eyebrow!,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: _musixBodyTextStyle(
                    color: _kAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                  ),
                ),
              if (eyebrow != null && title != null) const SizedBox(height: 4),
              if (title != null)
                Text(
                  title!,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: _musixHeadingTextStyle(
                    color: _kTextPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.05,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
