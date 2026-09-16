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
///   verde    -> tertiary           (i codici 2FA)
///
/// I valori sono **gli stessi delle variabili CSS del PC**, non colori
/// somiglianti: `--s0`, `--s2`, `--brd`, `--acc`, `--ok` in `index.html`. Il
/// tema scuro aveva un accento blu che sul PC non esiste — lì è ciano — e le
/// due app sembravano due prodotti diversi.
///
/// I `tenue` sono il colore di ogni etichetta e di ogni spiegazione, cioè di
/// quasi tutto il testo che non sia un titolo. Il chiaro è passato da
/// `#5B6B8A` a `#4F5D75` (da 4,81 a 5,97:1). I due scuri **erano già a
/// posto**: valevano `#8FA0C0`, cioè 7,45:1. Per qualche ora hanno avuto il
/// valore calcolato per il web, che li portava a 5,67 — ancora sopra la
/// soglia AA ma visibilmente più spento, e sul telefono si è visto subito.
/// La lezione sta nel numero: 4,5 è un pavimento, non un obiettivo.
/// I rapporti si leggono calcolati a schermo in `design/anteprima.html`.
ThemeData temaDati(TemaId id) {
  switch (id) {
    case TemaId.chiaro:
      return _costruisci(
        brillantezza: Brightness.light,
        fondo: const Color(0xFFF4F7FC),
        pannello: const Color(0xFFFFFFFF),
        bordo: const Color(0xFFD9E2F0),
        accento: const Color(0xFF0369A1),
        verde: const Color(0xFF047857),
        testo: const Color(0xFF0F1729),
        tenue: const Color(0xFF4F5D75),
        suAccento: Colors.white,
      );
    case TemaId.scuro:
      return _costruisci(
        brillantezza: Brightness.dark,
        fondo: const Color(0xFF080B14),
        pannello: const Color(0xFF121A2B),
        bordo: const Color(0xFF1F2A40),
        accento: const Color(0xFF38BDF8),
        verde: const Color(0xFF34D399),
        testo: const Color(0xFFE8ECF6),
        tenue: const Color(0xFF8FA0C0),
        suAccento: const Color(0xFF04121C),
      );
    case TemaId.notteOro:
      return _costruisci(
        brillantezza: Brightness.dark,
        fondo: const Color(0xFF050912),
        pannello: const Color(0xFF0E1730),
        bordo: const Color(0xFF1E2C4C),
        accento: const Color(0xFFE3B341),
        verde: const Color(0xFF4ADE80),
        testo: const Color(0xFFE8ECF6),
        tenue: const Color(0xFF8FA0C0),
        suAccento: const Color(0xFF1A1206),
      );
  }
}

ThemeData _costruisci({
  required Brightness brillantezza,
  required Color fondo,
  required Color pannello,
  required Color bordo,
  required Color accento,
  required Color verde,
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
    // Il verde dei codici 2FA vive in `tertiary`, che non usiamo per altro:
    // così viaggia dentro il tema e cambia da solo, invece di essere scelto a
    // mano guardando la luminosità come si faceva prima.
    tertiary: verde,
    onTertiary: suAccento,
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
    // Inter, lo stesso file del PC e dell'estensione. Prima era il font di
    // sistema, cioe' Roboto qui e Segoe di la': le due app si somigliavano
    // nei colori e si tradivano nella forma delle lettere.
    fontFamily: 'Inter',
    // Le icone dell'app sono `IconaVM` e prendono il colore da qui: cosi'
    // nessuna schermata deve passarlo a mano, come sul PC dove arriva da
    // `currentColor`.
    iconTheme: IconThemeData(color: tenue),
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
        // fontFamily ripetuto di proposito: uno stile di componente SOSTITUISCE
        // quello del tema invece di fondersi, e senza famiglia il testo
        // tornava a Roboto. Su Android era solo il font sbagliato; nel browser
        // Roboto non c'è (non si scarica niente da Google) e il testo del
        // pulsante spariva del tutto.
        textStyle: const TextStyle(
            fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: pannello,
      contentTextStyle: TextStyle(fontFamily: 'Inter', color: testo),
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
  bool get temaChiaro => Theme.of(this).brightness == Brightness.light;

  /// Verde dei codici 2FA: arriva dal tema (vedi `tertiary`).
  Color get cVerde => _s.tertiary;

  /// I link prendono il colore d'accento, come sul PC — dove `--cyan` e
  /// `--accent` sono lo stesso valore in tutti e tre i temi, oro compreso.
  Color get cLink => _s.primary;
}

// Nota (04/08/2026): qui c'era `coloreCategoria()`, che dava a ogni scheda un
// colore diverso ricavato dalla categoria o dal tag. L'idea era di far
// riconoscere le voci a colpo d'occhio; l'effetto vero era un elenco
// arlecchino in cui la M di Microsoft era arancione e il tema non si vedeva
// più. Rimosso su indicazione di Luca: le schede seguono i colori del tema,
// come sul PC.
