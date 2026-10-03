import 'package:flutter/material.dart';

const _seed = Color(0xFF0F766E); // teal-700

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: brightness == Brightness.light ? const Color(0xFFF6F7F9) : scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: brightness == Brightness.light ? Colors.white : scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: brightness == Brightness.light ? Colors.white : scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
      dataRowMinHeight: 44,
      dataRowMaxHeight: 60,
    ),
    chipTheme: base.chipTheme.copyWith(side: BorderSide.none),
  );
}

/// Semantic colours used for money states, alerts and amounts.
class Palette {
  static const positive = Color(0xFF15803D);
  static const negative = Color(0xFFB91C1C);
  static const warning = Color(0xFFB45309);
  static const info = Color(0xFF1D4ED8);
  static const muted = Color(0xFF6B7280);
}
