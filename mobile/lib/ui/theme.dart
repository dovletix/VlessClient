import 'package:flutter/material.dart';

/// The palette of the PowerShell edition's web UI and of the Windows window (Ui/Theme.cs). Dark is the default.
class Palette {
  const Palette({
    required this.bg,
    required this.panel,
    required this.text,
    required this.muted,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.ok,
    required this.okSoft,
    required this.bad,
    required this.badSoft,
    required this.warn,
    required this.warnSoft,
    required this.chip,
    required this.track,
    required this.hover,
    required this.onAccent,
  });

  final Color bg, panel, text, muted, line, accent, accentSoft, ok, okSoft, bad, badSoft, warn, warnSoft, chip, track, hover, onAccent;

  static const dark = Palette(
    bg: Color(0xFF111418),
    panel: Color(0xFF1A1E24),
    text: Color(0xFFE7EAEE),
    muted: Color(0xFF8D97A5),
    line: Color(0xFF2A3039),
    accent: Color(0xFF6B9BFF),
    accentSoft: Color(0xFF1D2B47),
    ok: Color(0xFF4ADE80),
    okSoft: Color(0xFF153223),
    bad: Color(0xFFF87171),
    badSoft: Color(0xFF3A1D1F),
    warn: Color(0xFFFBBF24),
    warnSoft: Color(0xFF3A2C10),
    chip: Color(0xFF252B33),
    track: Color(0xFF4A525E),
    hover: Color(0xFF1F242C),
    onAccent: Color(0xFFFFFFFF),
  );

  static const light = Palette(
    bg: Color(0xFFF3F4F6),
    panel: Color(0xFFFFFFFF),
    text: Color(0xFF171A1F),
    muted: Color(0xFF68717D),
    line: Color(0xFFE2E5EA),
    accent: Color(0xFF2563EB),
    accentSoft: Color(0xFFE6EEFD),
    ok: Color(0xFF15803D),
    okSoft: Color(0xFFE3F4E8),
    bad: Color(0xFFC93434),
    badSoft: Color(0xFFFDE8E8),
    warn: Color(0xFFB45309),
    warnSoft: Color(0xFFFDF0D9),
    chip: Color(0xFFEEF0F4),
    track: Color(0xFFB6BCC6),
    hover: Color(0xFFF5F8FE),
    onAccent: Color(0xFFFFFFFF),
  );

  static Palette of(BuildContext context) => Theme.of(context).extension<PaletteExt>()!.p;

  ThemeData theme(bool isDark) {
    final scheme = ColorScheme(
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      error: bad,
      onError: onAccent,
      surface: panel,
      onSurface: text,
    );
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: line));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: line,
      extensions: [PaletteExt(this)],
      appBarTheme: AppBarTheme(backgroundColor: bg, foregroundColor: text, elevation: 0, scrolledUnderElevation: 0, centerTitle: false),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: accentSoft,
        surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? accent : muted)),
        labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: s.contains(WidgetState.selected) ? accent : muted)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: accent, width: 1.5)),
        hintStyle: TextStyle(color: muted),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(onAccent),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : track),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : muted)),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: onAccent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: text,
            side: BorderSide(color: line),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent)),
      chipTheme: ChipThemeData(
        backgroundColor: chip,
        selectedColor: accentSoft,
        checkmarkColor: accent,
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        labelStyle: TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w600),
        iconTheme: IconThemeData(color: muted, size: 16),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : Colors.transparent),
        side: BorderSide(color: muted, width: 1.5),
      ),
      snackBarTheme: SnackBarThemeData(backgroundColor: chip, contentTextStyle: TextStyle(color: text), behavior: SnackBarBehavior.floating),
      dialogTheme: DialogThemeData(backgroundColor: panel, surfaceTintColor: Colors.transparent),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: panel, surfaceTintColor: Colors.transparent),
      popupMenuTheme: PopupMenuThemeData(color: panel, surfaceTintColor: Colors.transparent),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    );
  }
}

class PaletteExt extends ThemeExtension<PaletteExt> {
  const PaletteExt(this.p);
  final Palette p;

  @override
  PaletteExt copyWith({Palette? p}) => PaletteExt(p ?? this.p);

  @override
  PaletteExt lerp(covariant ThemeExtension<PaletteExt>? other, double t) => t < 0.5 || other is! PaletteExt ? this : other;
}
