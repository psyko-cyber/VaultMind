/// I tre temi dell'app, gli stessi del PC.
///
/// I colori passano dal `ColorScheme` di Flutter invece che da costanti
/// globali: così cambiare tema ridipinge tutto da solo, senza che ogni
/// schermata debba sapere quale tema è attivo. È lo stesso motivo per cui sul
/// PC l'intestazione prende lo sfondo da `--bar` e non da un colore fisso.
library;

import 'package:flutter/material.dart';

enum TemaId { scuro, chiaro, notteOro }

const nomiTema = {
  TemaId.scuro: 'Scuro',
  TemaId.chiaro: 'Chiaro',
  TemaId.notteOro: 'Notte e oro',
};

/// Corrispondenze coi nomi usati nel codice:
///   fondo    -> surface            pannello -> surfaceContainerHighest
///   accento  -> primary            testo    -> onSurface
///   tenue    -> onSurfaceVariant   bordo    -> outlineVariant
ThemeData temaDati(TemaId id) {
  switch (id) {
    case TemaId.chiaro:
      return _costruisci(
        brillantezza: Brightness.light,
        fondo: const Color(0xFFF4F7FC),
        pannello: const Color(0xFFFFFFFF),
        bordo: const Color(0xFFD9E2F0),
        accento: const Color(0xFF2B5CE6),
        testo: const Color(0xFF17203A),
        tenue: const Color(0xFF5B6B8A),
        suAccento: Colors.white,
      );
    case TemaId.scuro:
      return _costruisci(
        brillantezza: Brightness.dark,
        fondo: const Color(0xFF0A0E1A),
        pannello: const Color(0xFF121A2B),
        bordo: const Color(0xFF1F2A40),
        accento: const Color(0xFF5B8DEF),
        testo: const Color(0xFFE8ECF6),
        tenue: const Color(0xFF8FA0C0),
        suAccento: Colors.white,
      );
    case TemaId.notteOro:
      return _costruisci(
        brillantezza: Brightness.dark,
        fondo: const Color(0xFF070C1A),
        pannello: const Color(0xFF0E1730),
        bordo: const Color(0xFF1E2C4C),
        accento: const Color(0xFFE3B341),
        testo: const Color(0xFFE8ECF6),
        tenue: const Color(0xFF8FA0C0),
        suAccento: const Color(0xFF141414),
      );
  }
}

ThemeData _costruisci({
  required Brightness brillantezza,
  required Color fondo,
  required Color pannello,
  required Color bordo,
  required Color accento,
  required Color testo,
  required Color tenue,
  required Color suAccento,
}) {
  final schema = ColorScheme(
    brightness: brillantezza,
    primary: accento,
    onPrimary: suAccento,
    secondary: accento,
    onSecondary: suAccento,
    error: const Color(0xFFE36868),
    onError: Colors.white,
    surface: fondo,
    onSurface: testo,
    surfaceContainerHighest: pannello,
    onSurfaceVariant: tenue,
    outlineVariant: bordo,
    outline: bordo,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brillantezza,
    colorScheme: schema,
    scaffoldBackgroundColor: fondo,
    appBarTheme: AppBarTheme(
      backgroundColor: pannello,
      foregroundColor: testo,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: pannello,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: bordo),
      ),
    ),
    dialogTheme: DialogThemeData(backgroundColor: pannello),
    listTileTheme: ListTileThemeData(iconColor: tenue, textColor: testo),
    dividerTheme: DividerThemeData(color: bordo),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: pannello,
      hintStyle: TextStyle(color: tenue),
      labelStyle: TextStyle(color: tenue),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: bordo),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: bordo),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accento),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accento,
        foregroundColor: suAccento,
        padding: const EdgeInsets.symmetric(vertical: 15),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: pannello,
      contentTextStyle: TextStyle(color: testo),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Scorciatoie: `c(context).tenue` invece di
/// `Theme.of(context).colorScheme.onSurfaceVariant`, che nel mezzo di un
/// widget rende il codice illeggibile.
extension ColoriTema on BuildContext {
  ColorScheme get _s => Theme.of(this).colorScheme;
  Color get cFondo => _s.surface;
  Color get cPannello => _s.surfaceContainerHighest;
  Color get cBordo => _s.outlineVariant;
  Color get cAccento => _s.primary;
  Color get cSuAccento => _s.onPrimary;
  Color get cTesto => _s.onSurface;
  Color get cTenue => _s.onSurfaceVariant;
  Color get cErrore => _s.error;

  /// Verde dei codici 2FA e azzurro dei link: restano riconoscibili in tutti
  /// e tre i temi, ma nel tema chiaro vanno scuriti per essere leggibili.
  bool get temaChiaro => Theme.of(this).brightness == Brightness.light;
  Color get cVerde => temaChiaro ? const Color(0xFF1B8F5A) : const Color(0xFF4CC38A);
  Color get cLink => temaChiaro ? const Color(0xFF1B4FD1) : const Color(0xFF6EA8FF);
}
