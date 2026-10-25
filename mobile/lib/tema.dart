/// I tre temi dell'app, gli stessi del PC: Prisma, Ghiaccio, Notte e oro.
///
/// I colori passano dal `ColorScheme` di Flutter invece che da costanti
/// globali: così cambiare tema ridipinge tutto da solo, senza che ogni
/// schermata debba sapere quale tema è attivo. È lo stesso motivo per cui sul
/// PC l'intestazione prende lo sfondo da `--bar` e non da un colore fisso.
///
/// Dal 25/10/2026 sostituiscono Scuro, Chiaro e Notte e oro (vedi
/// `Impostazioni.fromJson` per chi aveva già scelto uno dei vecchi).
library;

import 'package:flutter/material.dart';

enum TemaId { prisma, ghiaccio, oro }

const nomiTema = {
  TemaId.prisma: 'Prisma',
  TemaId.ghiaccio: 'Ghiaccio',
  TemaId.oro: 'Notte e oro',
};

/// La forma dei pulsanti pieni, una sola: la usa il tema e la usa la
/// sfumatura, che deve sapere dove fermarsi.
const formaPulsante = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(14)),
);

/// Lo sfondo dei pulsanti pieni: la sfumatura fra i due neon.
///
/// Sta dietro al pulsante, non al posto del suo colore: da spento il pulsante
/// torna al colore piatto di `disabled`, e si capisce che non si può toccare.
/// Copre però l'increspatura del tocco, che Flutter disegna sotto: la velatura
/// chiara da premuto la sostituisce, o il pulsante sembrerebbe non aver
/// sentito il dito.
///
/// La [forma] va ripetuta qui perché Flutter non ritaglia: ritaglierebbe da
/// solo se `clipBehavior` fosse nullo, ma `FilledButton` e `IconButton` lo
/// fissano a `Clip.none`, e la sfumatura usciva dagli angoli arrotondati.
ButtonLayerBuilder sfondoNeon(
  Gradient sfumatura, {
  ShapeBorder forma = formaPulsante,
}) =>
    (_, stati, figlio) => stati.contains(WidgetState.disabled)
        ? figlio!
        : DecoratedBox(
            decoration: ShapeDecoration(shape: forma, gradient: sfumatura),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: ShapeDecoration(
                shape: forma,
                color: stati.contains(WidgetState.pressed)
                    ? const Color(0x24FFFFFF)
                    : const Color(0x00FFFFFF),
              ),
              child: figlio,
            ),
          );

/// Per i pulsanti pieni che hanno un colore loro, cioè quelli che
/// distruggono qualcosa: la sfumatura del tema lo copriva, e «Elimina» si
/// vestiva come «Salva». Un `null` in `copyWith` non basta: vuol dire «non
/// detto», e il tema la rimetteva.
Widget senzaNeon(BuildContext _, Set<WidgetState> _, Widget? figlio) => figlio!;

/// La forma dei pulsanti fluttuanti, quella di Material 3: la sfumatura che
/// ci sta sotto deve combaciare.
const formaFluttuante = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);

/// I pulsanti fluttuanti («+» del database, «Nuova categoria») non hanno un
/// `backgroundBuilder`: la sfumatura sta in un riquadro sotto, e il pulsante
/// sopra è trasparente. Senza ombra (`floatingActionButtonTheme`): Flutter la
/// disegnerebbe sopra la sfumatura, come una macchia.
Widget sottoNeon(BuildContext context, Widget pulsante) => DecoratedBox(
      decoration: ShapeDecoration(
          shape: formaFluttuante, gradient: context.cristallo.sfumatura),
      child: pulsante,
    );

/// Corrispondenze coi nomi usati nel codice e con le variabili del PC:
///   fondo    -> surface                 (--s0)
///   rialzo   -> surfaceContainerLow     (--s1, barre in alto e in basso)
///   pannello -> surfaceContainerHighest (--s2, schede e campi)
///   accento  -> primary                 (--neon-2, il colore dei testi accesi)
///   testo    -> onSurface               (--t1)
///   tenue    -> onSurfaceVariant        (--t3)
///   bordo    -> outlineVariant          (--brd)
///   verde    -> tertiary                (--ok, i codici 2FA)
///
/// I valori sono **gli stessi delle variabili CSS del PC**, non colori
/// somiglianti: `index.html` è l'originale. Il resto di ciò che serve al
/// vetro e allo sfondo (i tre neon, gli aloni dell'aurora, il colore dei
/// punti) sta in [Cristallo].
///
/// I `tenue` sono il colore di ogni etichetta e di ogni spiegazione, cioè di
/// quasi tutto il testo che non sia un titolo. 4,5:1 è un pavimento, non un
/// obiettivo: qui valgono 6,6 (Prisma), 6,3 (Ghiaccio) e 7,3 (Notte e oro)
/// sul pannello. I rapporti si leggono calcolati a schermo in
/// `design/anteprima.html`.
ThemeData temaDati(TemaId id) {
  switch (id) {
    case TemaId.ghiaccio:
      return _costruisci(
        brillantezza: Brightness.light,
        fondo: const Color(0xFFE4E8F5),
        rialzo: const Color(0xFFEEF1FA),
        pannello: const Color(0xFFF6F7FD),
        bordo: const Color(0x24283482),
        bordoForte: const Color(0x42283482),
        testo: const Color(0xFF0B0F2E),
        tenue: const Color(0xFF515985),
        verde: const Color(0xFF03684E),
        errore: const Color(0xFFB01F41),
        cristallo: const Cristallo(
          neon1: Color(0xFF5440E6),
          neon2: Color(0xFF006489),
          neon3: Color(0xFFCF37AE),
          suNeon: Color(0xFFFFFFFF),
          abisso: Color(0xFFF6F8FE),
          alone1: Color(0x527D69FF),
          alone2: Color(0x3D00B9F0),
          alone3: Color(0x2EFF69D7),
          punto: Color(0xFF343E8C),
          vignetta: Color(0x5996A0CD),
        ),
      );
    case TemaId.prisma:
      return _costruisci(
        brillantezza: Brightness.dark,
        fondo: const Color(0xFF04050E),
        rialzo: const Color(0xFF090B1E),
        pannello: const Color(0xFF0D1027),
        bordo: const Color(0x21AAB2FF),
        bordoForte: const Color(0x3DAAB2FF),
        testo: const Color(0xFFF3F4FF),
        tenue: const Color(0xFF8F96C6),
        verde: const Color(0xFF46E9B2),
        errore: const Color(0xFFFF7C95),
        cristallo: const Cristallo(
          neon1: Color(0xFF8C7CFF),
          neon2: Color(0xFF3CE2FF),
          neon3: Color(0xFFFF5AD9),
          suNeon: Color(0xFF060418),
          abisso: Color(0xFF0B0D24),
          alone1: Color(0x57705CFF),
          alone2: Color(0x3328CDFF),
          alone3: Color(0x21FF50CD),
          punto: Color(0xFFC4CEFF),
          vignetta: Color(0x80000000),
        ),
      );
    case TemaId.oro:
      return _costruisci(
        brillantezza: Brightness.dark,
        fondo: const Color(0xFF03050C),
        rialzo: const Color(0xFF080B1A),
        pannello: const Color(0xFF0C1024),
        bordo: const Color(0x1FFFD78C),
        bordoForte: const Color(0x38FFD78C),
        testo: const Color(0xFFFFF8EA),
        tenue: const Color(0xFFABA08B),
        verde: const Color(0xFF5BE39A),
        errore: const Color(0xFFFF8A8A),
        cristallo: const Cristallo(
          neon1: Color(0xFFE9A93A),
          neon2: Color(0xFFFFD978),
          // Il terzo neon è blu: d'oro su oro il prisma non si vedrebbe girare.
          neon3: Color(0xFF6F8CFF),
          suNeon: Color(0xFF1B1306),
          abisso: Color(0xFF0D1022),
          alone1: Color(0x38E9A93A),
          alone2: Color(0x473C5ADC),
          alone3: Color(0x1AFFBE5A),
          punto: Color(0xFFFFE2AA),
          vignetta: Color(0x8C000000),
        ),
      );
  }
}

/// Quello che il `ColorScheme` non sa dire: i tre neon, i colori dello
/// sfondo (vedi `sfondo.dart`) e il bordo più marcato.
///
/// Sta dentro il tema come estensione, e non in costanti a parte, per lo
/// stesso motivo dei colori normali: cambiato il tema, cambia da solo.
@immutable
class Cristallo extends ThemeExtension<Cristallo> {
  const Cristallo({
    required this.neon1,
    required this.neon2,
    required this.neon3,
    required this.suNeon,
    required this.abisso,
    required this.alone1,
    required this.alone2,
    required this.alone3,
    required this.punto,
    required this.vignetta,
    this.bordoForte = const Color(0x00000000),
  });

  /// I primi due fanno le sfumature (pulsanti, interruttori, il bordo a
  /// prisma); il terzo compare solo dentro il prisma.
  final Color neon1, neon2, neon3;

  /// Il testo sopra una sfumatura di neon.
  final Color suNeon;

  /// Il fondo sfumato dello sfondo, in alto (`--abisso-2`).
  final Color abisso;

  /// I tre aloni dell'aurora, già con la loro trasparenza.
  final Color alone1, alone2, alone3;

  /// Il colore dei punti della costellazione, senza trasparenza: quella la
  /// decide la profondità di ogni punto.
  final Color punto;

  final Color vignetta;
  final Color bordoForte;

  /// La sfumatura dei pulsanti: dal primo neon al secondo, in diagonale.
  LinearGradient get sfumatura => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [neon1, neon2],
      );

  /// Il bordo a prisma: i tre neon tutto intorno, e si richiude sul primo.
  SweepGradient get prisma => SweepGradient(
        colors: [neon1, neon2, neon3, neon1],
        stops: const [0, .38, .7, 1],
      );

  @override
  Cristallo copyWith({Color? bordoForte}) => Cristallo(
        neon1: neon1,
        neon2: neon2,
        neon3: neon3,
        suNeon: suNeon,
        abisso: abisso,
        alone1: alone1,
        alone2: alone2,
        alone3: alone3,
        punto: punto,
        vignetta: vignetta,
        bordoForte: bordoForte ?? this.bordoForte,
      );

  /// Serve al cambio di tema: `MaterialApp` passa da un tema all'altro in
  /// dissolvenza, e senza `lerp` lo sfondo salterebbe di colpo mentre il
  /// resto sfuma.
  @override
  Cristallo lerp(Cristallo? altro, double t) {
    if (altro == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Cristallo(
      neon1: l(neon1, altro.neon1),
      neon2: l(neon2, altro.neon2),
      neon3: l(neon3, altro.neon3),
      suNeon: l(suNeon, altro.suNeon),
      abisso: l(abisso, altro.abisso),
      alone1: l(alone1, altro.alone1),
      alone2: l(alone2, altro.alone2),
      alone3: l(alone3, altro.alone3),
      punto: l(punto, altro.punto),
      vignetta: l(vignetta, altro.vignetta),
      bordoForte: l(bordoForte, altro.bordoForte),
    );
  }
}

ThemeData _costruisci({
  required Brightness brillantezza,
  required Color fondo,
  required Color rialzo,
  required Color pannello,
  required Color bordo,
  required Color bordoForte,
  required Color testo,
  required Color tenue,
  required Color verde,
  required Color errore,
  required Cristallo cristallo,
}) {
  final accento = cristallo.neon2;
  final suAccento = cristallo.suNeon;
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
    // L'errore era un rosso unico per tutti i temi (#E36868): sul fondo
    // chiaro valeva 3,3:1, cioè un errore che si legge solo sapendo che c'è.
    error: errore,
    onError: brillantezza == Brightness.dark ? fondo : Colors.white,
    surface: fondo,
    onSurface: testo,
    surfaceContainerLow: rialzo,
    surfaceContainerHighest: pannello,
    onSurfaceVariant: tenue,
    outlineVariant: bordo,
    outline: bordoForte,
    // Material 3 tinge le superfici rialzate col primario: su un vetro scuro
    // diventava una velatura ciano che nessuno ha scelto.
    surfaceTint: Colors.transparent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brillantezza,
    colorScheme: schema,
    scaffoldBackgroundColor: fondo,
    extensions: [cristallo.copyWith(bordoForte: bordoForte)],
    // Inter, lo stesso file del PC e dell'estensione. Prima era il font di
    // sistema, cioe' Roboto qui e Segoe di la': le due app si somigliavano
    // nei colori e si tradivano nella forma delle lettere.
    fontFamily: 'Inter',
    // Le icone dell'app sono `IconaVM` e prendono il colore da qui: cosi'
    // nessuna schermata deve passarlo a mano, come sul PC dove arriva da
    // `currentColor`.
    iconTheme: IconThemeData(color: tenue),
    appBarTheme: AppBarTheme(
      backgroundColor: rialzo,
      foregroundColor: testo,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: bordo)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: rialzo,
      surfaceTintColor: Colors.transparent,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      shape: formaFluttuante,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: pannello,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
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
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: bordoForte),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: bordoForte),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accento, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accento,
        foregroundColor: suAccento,
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: formaPulsante,
        // fontFamily ripetuto di proposito: uno stile di componente SOSTITUISCE
        // quello del tema invece di fondersi, e senza famiglia il testo
        // tornava a Roboto. Su Android era solo il font sbagliato; nel browser
        // Roboto non c'è (non si scarica niente da Google) e il testo del
        // pulsante spariva del tutto.
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ).copyWith(backgroundBuilder: sfondoNeon(cristallo.sfumatura)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    // I segmenti degli sfondi (Impostazioni → Aspetto). Stessa trappola del
    // fontFamily qui sopra.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        foregroundColor: tenue,
        selectedForegroundColor: suAccento,
        selectedBackgroundColor: cristallo.neon1,
        side: BorderSide(color: bordoForte),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w500,
          fontSize: 12.5,
        ),
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

  /// I link prendono il colore d'accento, come sul PC.
  Color get cLink => _s.primary;

  /// I neon e i colori dello sfondo (vedi [Cristallo]).
  Cristallo get cristallo => Theme.of(this).extension<Cristallo>()!;
}

// Nota (04/08/2026): qui c'era `coloreCategoria()`, che dava a ogni scheda un
// colore diverso ricavato dalla categoria o dal tag. L'idea era di far
// riconoscere le voci a colpo d'occhio; l'effetto vero era un elenco
// arlecchino in cui la M di Microsoft era arancione e il tema non si vedeva
// più. Rimosso su indicazione di Luca: le schede seguono i colori del tema,
// come sul PC.
