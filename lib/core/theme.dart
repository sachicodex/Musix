import 'package:flutter/material.dart';

import 'colors.dart';

const String musixHeadingFontFamily = 'SfProDisplay';
const String musixBodyFontFamily = 'GeneralSans';

ThemeData buildMusixTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: MusixColors.accent,
    brightness: Brightness.dark,
  );

  final ThemeData base = ThemeData(
    useMaterial3: true,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    colorScheme: scheme.copyWith(
      primary: MusixColors.accent,
      secondary: MusixColors.accentStrong,
      surface: MusixColors.shellBackground,
      onSurface: MusixColors.textPrimary,
    ),
    scaffoldBackgroundColor: MusixColors.shellBackground,
    fontFamily: musixBodyFontFamily,
    dividerColor: MusixColors.surfaceEdge,
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: MusixColors.sheetBackground,
      modalBackgroundColor: MusixColors.sheetBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: MusixColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: MusixColors.surfaceOutlineStrong),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: musixHeadingFontFamily,
        color: MusixColors.textPrimary,
        fontSize: 26,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: const TextStyle(
        fontFamily: musixBodyFontFamily,
        color: MusixColors.textSecondary,
        fontSize: 17,
        fontWeight: FontWeight.w500,
        height: 1.45,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: MusixColors.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: MusixColors.surfaceEdge),
      ),
      contentTextStyle: const TextStyle(
        fontFamily: musixBodyFontFamily,
        color: MusixColors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: MusixColors.accent,
      selectionColor: Color(0x66FF8A2A),
      selectionHandleColor: MusixColors.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            backgroundColor: MusixColors.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ).copyWith(
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom().copyWith(
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            foregroundColor: MusixColors.accent,
            side: const BorderSide(color: MusixColors.surfaceEdge),
          ).copyWith(
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
          ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom().copyWith(
        overlayColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: MusixColors.textFieldFill,
      labelStyle: const TextStyle(color: MusixColors.textSecondary),
      hintStyle: const TextStyle(color: MusixColors.textMuted),
      prefixIconColor: MusixColors.textSecondary,
      suffixIconColor: MusixColors.textSecondary,
      border: _inputBorder(MusixColors.surfaceEdge),
      enabledBorder: _inputBorder(MusixColors.surfaceEdge),
      focusedBorder: _inputBorder(
        MusixColors.textMuted.withValues(alpha: 0.42),
      ),
      errorBorder: _inputBorder(MusixColors.errorStrong),
      focusedErrorBorder: _inputBorder(MusixColors.errorStrong),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
  );

  final TextTheme body = base.textTheme.apply(
    fontFamily: musixBodyFontFamily,
    bodyColor: MusixColors.textPrimary,
    displayColor: MusixColors.textPrimary,
  );
  final TextTheme display = body.apply(fontFamily: musixHeadingFontFamily);

  return base.copyWith(
    textTheme: body.copyWith(
      displayLarge: display.displayLarge,
      displayMedium: display.displayMedium,
      displaySmall: display.displaySmall,
      headlineLarge: display.headlineLarge,
      headlineMedium: display.headlineMedium,
      headlineSmall: display.headlineSmall,
      titleLarge: display.titleLarge,
      titleMedium: display.titleMedium,
      titleSmall: display.titleSmall,
    ),
  );
}

ButtonStyle musixDialogPrimaryButtonStyle({Color? backgroundColor}) {
  return FilledButton.styleFrom(
    backgroundColor: backgroundColor ?? MusixColors.accent,
    foregroundColor: Colors.white,
    disabledBackgroundColor: MusixColors.accentStrong.withValues(alpha: 0.34),
    disabledForegroundColor: Colors.white.withValues(alpha: 0.65),
    minimumSize: const Size(118, 48),
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ).copyWith(
    overlayColor: WidgetStateProperty.all(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
  );
}

ButtonStyle musixDialogSecondaryButtonStyle() {
  return TextButton.styleFrom(
    foregroundColor: MusixColors.textSecondary,
    minimumSize: const Size(96, 48),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ).copyWith(
    overlayColor: WidgetStateProperty.all(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
  );
}

BoxDecoration musixPageDecoration() {
  return const BoxDecoration(
    gradient: LinearGradient(
      colors: <Color>[
        MusixColors.pageTop,
        MusixColors.pageMiddle,
        MusixColors.pageBottom,
      ],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    ),
  );
}

BoxDecoration musixPanelDecoration({
  double radius = 24,
  Color color = MusixColors.surfaceRaised,
  Color borderColor = MusixColors.surfaceOutlineStrong,
  List<BoxShadow>? boxShadow,
}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: borderColor),
    boxShadow: boxShadow,
  );
}

InputDecoration musixInputDecoration({
  String? label,
  String? hintText,
  IconData? icon,
  Widget? prefixIcon,
  Widget? suffixIcon,
  double borderRadius = 16,
  EdgeInsetsGeometry? contentPadding,
  bool? isDense,
  FloatingLabelBehavior? floatingLabelBehavior,
  BoxConstraints? prefixIconConstraints,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hintText,
    prefixIcon: prefixIcon ?? (icon != null ? Icon(icon) : null),
    suffixIcon: suffixIcon,
    isDense: isDense,
    contentPadding: contentPadding,
    floatingLabelBehavior: floatingLabelBehavior,
    prefixIconConstraints: prefixIconConstraints,
  ).copyWith(
    border: _inputBorder(MusixColors.surfaceEdge, radius: borderRadius),
    enabledBorder: _inputBorder(MusixColors.surfaceEdge, radius: borderRadius),
    focusedBorder: _inputBorder(
      MusixColors.textMuted.withValues(alpha: 0.42),
      radius: borderRadius,
    ),
    errorBorder: _inputBorder(MusixColors.errorStrong, radius: borderRadius),
    focusedErrorBorder: _inputBorder(
      MusixColors.errorStrong,
      radius: borderRadius,
    ),
  );
}

OutlineInputBorder _inputBorder(
  Color color, {
  double width = 1,
  double radius = 16,
}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(radius),
    borderSide: BorderSide(color: color, width: width),
  );
}
