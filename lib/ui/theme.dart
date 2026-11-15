// The look of the app: colours, shapes and type, built once.
library;

import 'package:flutter/material.dart';

/// The brand violet, the same in light and dark.
const brand = Color(0xFF7C3AED);

final ThemeData lightTheme = _build(Brightness.light);
final ThemeData darkTheme = _build(Brightness.dark);

const _accents = [
  Color(0xFF7C3AED),
  Color(0xFFE11D48),
  Color(0xFFEA580C),
  Color(0xFF059669),
  Color(0xFF0891B2),
  Color(0xFF2563EB),
  Color(0xFFC026D3),
  Color(0xFFCA8A04),
];

/// A stable colour for the nth thing in a list, so lists aren't one flat tone.
Color accent(int n) => _accents[n.abs() % _accents.length];

ThemeData _build(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final seeded = ColorScheme.fromSeed(seedColor: brand, brightness: brightness, dynamicSchemeVariant: DynamicSchemeVariant.fidelity);
  final cs = dark
      ? seeded.copyWith(
          surface: const Color(0xFF111015),
          surfaceContainerLowest: const Color(0xFF0C0B10),
          surfaceContainerLow: const Color(0xFF17151C),
          surfaceContainer: const Color(0xFF1C1A22),
          surfaceContainerHigh: const Color(0xFF26232D),
          surfaceContainerHighest: const Color(0xFF312E39),
        )
      : seeded.copyWith(
          surface: const Color(0xFFFCFBFF),
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xFFF7F4FC),
          surfaceContainer: const Color(0xFFF3F0F9),
          surfaceContainerHigh: const Color(0xFFECE8F4),
          surfaceContainerHighest: const Color(0xFFE5E0EE),
        );
  final base = ThemeData(colorScheme: cs, useMaterial3: true);
  final text = base.textTheme;
  final field = OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none);
  return base.copyWith(
    scaffoldBackgroundColor: cs.surface,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodySmall: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2, color: cs.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: cs.surfaceContainer,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerHigh,
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(borderSide: BorderSide(color: cs.primary, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      helperMaxLines: 3,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: cs.primary.withValues(alpha: 0.16),
      iconTheme: WidgetStateProperty.resolveWith((st) => IconThemeData(color: st.contains(WidgetState.selected) ? cs.primary : cs.onSurfaceVariant)),
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w500)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: cs.surface,
      indicatorColor: cs.primary.withValues(alpha: 0.16),
      selectedIconTheme: IconThemeData(color: cs.primary),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: cs.surfaceContainerHigh,
      selectedColor: cs.primary,
      showCheckmark: false,
      labelStyle: text.labelLarge?.copyWith(color: WidgetStateColor.resolveWith((st) => st.contains(WidgetState.selected) ? cs.onPrimary : cs.onSurface)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 46),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: cs.surfaceContainerLow, surfaceTintColor: Colors.transparent, showDragHandle: true),
    dialogTheme: DialogThemeData(backgroundColor: cs.surfaceContainerLow, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(
      color: cs.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: cs.onSurfaceVariant,
      subtitleTextStyle: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant.withValues(alpha: 0.45), space: 1, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(linearTrackColor: cs.surfaceContainerHighest),
    sliderTheme: const SliderThemeData(trackHeight: 4),
  );
}
