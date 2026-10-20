import 'package:flutter/material.dart';

/// Chest's visual language.
///
/// The palette is deliberately narrow: a near-black obsidian field, a slate
/// surface for raised elements, and gold reserved for actions and the one thing
/// that matters on each screen. Nothing else gets colour, which keeps the eye on
/// vault state rather than on decoration.
class ChestTheme {
  const ChestTheme._();

  /// Deepest background, used for the scaffold.
  static const Color obsidian = Color(0xFF070A12);

  /// Raised surface: cards, sheets, list tiles.
  static const Color slate = Color(0xFF141B2B);

  /// Border and divider colour.
  static const Color hairline = Color(0xFF232C42);

  /// Primary accent, reserved for the most important action per screen.
  static const Color gold = Color(0xFFF0B94E);

  /// Dimmer gold for rules and inactive accents.
  static const Color goldDeep = Color(0xFFC68C28);

  /// Bright gold for text on dark, where the primary gold is too dim.
  static const Color goldPale = Color(0xFFFFE0A0);

  /// Secondary accent, used for informational states.
  static const Color cyan = Color(0xFF5ED6D6);

  /// Warning and destructive states.
  static const Color ember = Color(0xFFE4573D);

  /// Success and confirmed-secure states.
  static const Color moss = Color(0xFF4FBF8B);

  /// Primary body text.
  static const Color parchment = Color(0xFFE8ECF5);

  /// Secondary text: labels, metadata, hints.
  static const Color muted = Color(0xFF8A94AC);

  /// The app's dark theme.
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: gold,
      brightness: Brightness.dark,
    ).copyWith(
      primary: gold,
      onPrimary: obsidian,
      secondary: cyan,
      onSecondary: obsidian,
      surface: slate,
      onSurface: parchment,
      error: ember,
      onError: obsidian,
      outline: hairline,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: obsidian,
      canvasColor: obsidian,
      appBarTheme: const AppBarTheme(
        backgroundColor: obsidian,
        foregroundColor: parchment,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: parchment,
        ),
      ),
      cardTheme: CardThemeData(
        color: slate,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: hairline),
        ),
      ),
      dividerTheme: const DividerThemeData(color: hairline, thickness: 1, space: 1),
      listTileTheme: const ListTileThemeData(iconColor: muted, textColor: parchment),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF101726),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        hintStyle: const TextStyle(color: muted),
        border: _fieldBorder(hairline),
        enabledBorder: _fieldBorder(hairline),
        focusedBorder: _fieldBorder(gold),
        errorBorder: _fieldBorder(ember),
        focusedErrorBorder: _fieldBorder(ember),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: gold,
          foregroundColor: obsidian,
          minimumSize: const Size.fromHeight(54),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: parchment,
          minimumSize: const Size.fromHeight(54),
          side: const BorderSide(color: hairline),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: gold),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: slate,
        contentTextStyle: const TextStyle(color: parchment),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? gold : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? gold.withValues(alpha: 0.35)
              : hairline,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: gold),
      dialogTheme: DialogThemeData(
        backgroundColor: slate,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: hairline),
        ),
      ),
    );
  }

  static OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color),
      );

  /// Monospace style for technical values such as key grades and fingerprints.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.5,
    color: muted,
  );
}
