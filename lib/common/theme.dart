import 'package:flutter/material.dart';

import '../domain/proximity.dart';

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3D5AFE),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Size.fromHeight is Size(double.infinity, h) — it forces every
        // button to demand the full width, which silently crushes anything
        // beside it. Full-width buttons here get their width from a stretch
        // Column or from being a ListView child, so a sane minimum is enough.
        minimumSize: const Size(64, 52),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        // Size.fromHeight is Size(double.infinity, h) — it forces every
        // button to demand the full width, which silently crushes anything
        // beside it. Full-width buttons here get their width from a stretch
        // Column or from being a ListView child, so a sane minimum is enough.
        minimumSize: const Size(64, 52),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

/// Colour language for presence, shared by both roles so "amber means this
/// person is about to drop" reads the same on the host dashboard and on the
/// attendee's own screen.
class ProximityStyle {
  const ProximityStyle(this.color, this.icon, this.label);

  final Color color;
  final IconData icon;
  final String label;

  static ProximityStyle of(ProximityState state, ColorScheme scheme) =>
      switch (state) {
        ProximityState.inRange =>
          ProximityStyle(scheme.primary, Icons.bluetooth_connected, 'In range'),
        ProximityState.warning => const ProximityStyle(
            Color(0xFFE08600), Icons.signal_wifi_statusbar_null, 'Weak signal'),
        ProximityState.lost => const ProximityStyle(
            Color(0xFFD32F2F), Icons.bluetooth_disabled, 'Out of range'),
      };
}
