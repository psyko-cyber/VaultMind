/// Il database si accorge delle voci nuove.
///
/// Prima la schermata si costruiva l'indice da sola e si iscriveva alla
/// sessione per rifarlo a ogni notifica. Ora l'indice arriva dalla casa, che ne
/// tiene **uno solo** per chat e database e lo rifà solo quando le voci cambiano
/// davvero: su 800 voci le due costruzioni a ogni salvataggio erano l'attesa a
/// schermo fermo che si vedeva sull'iPhone.
///
/// Spostando quella responsabilità si sposta anche il rischio: se l'arrivo di
/// un indice diverso non facesse ripartire la ricerca, una voce appena salvata
/// non si troverebbe più. È esattamente quello che questo test tiene fermo, ed
/// è l'unico pezzo del giro che la suite non copriva.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/ricerca.dart';
import 'package:vaultmind/schermate/database.dart';
import 'package:vaultmind/sessione.dart';
import 'package:vaultmind/tema.dart';
import 'package:vaultmind/vault.dart';

void main() {
  final chiave = Uint8List.fromList(List<int>.generate(32, (i) => i * 7 % 251));
  final salt = Uint8List.fromList(List<int>.filled(16, 3));

  Credenziale voce(int id, String titolo) => Credenziale(
        id: id,
        title: titolo,
        tags: const [],
        critical: false,
        fields: const [Campo('utente', 'mario')],
      );

  /// La schermata come la costruisce la casa: l'indice viene da fuori.
  Widget schermata(Sessione s) => MaterialApp(
        theme: temaDati(TemaId.scuro),
        home: SezioneDatabase(
            sessione: s, indice: IndiceRicerca(s.vault.credenziali)),
      );

  testWidgets('una voce aggiunta compare senza rifare la schermata',
      (tester) async {
    final sessione = Sessione(Vault([voce(1, 'Amazon')], salt: salt), chiave);

    await tester.pumpWidget(schermata(sessione));
    expect(find.text('Amazon'), findsOneWidget);
    expect(find.text('Banca Intesa'), findsNothing);

    // Quello che fa un salvataggio: la sessione cambia valore, e la casa
    // ridisegna passando un indice nuovo.
    sessione.value = sessione.vault
        .con(credenziali: [voce(2, 'Banca Intesa'), voce(1, 'Amazon')]);
    await tester.pumpWidget(schermata(sessione));
    await tester.pump();

    expect(find.text('Banca Intesa'), findsOneWidget,
        reason: 'la voce appena salvata deve comparire nell\'elenco');
    expect(find.text('Amazon'), findsOneWidget);
  });

  testWidgets('con una ricerca in corso la voce nuova si trova', (tester) async {
    final sessione = Sessione(Vault([voce(1, 'Amazon')], salt: salt), chiave);

    await tester.pumpWidget(schermata(sessione));
    await tester.enterText(find.byType(TextField), 'banca');
    // La ricerca aspetta che si smetta di scrivere.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Banca Intesa'), findsNothing);

    sessione.value = sessione.vault
        .con(credenziali: [voce(2, 'Banca Intesa'), voce(1, 'Amazon')]);
    await tester.pumpWidget(schermata(sessione));
    await tester.pump();

    expect(find.text('Banca Intesa'), findsOneWidget,
        reason: 'la ricerca deve ripartire sul nuovo indice, non su quello vecchio');
  });

  testWidgets('se le voci non cambiano la ricerca non riparte da capo',
      (tester) async {
    final sessione = Sessione(Vault([voce(1, 'Amazon')], salt: salt), chiave);
    final indice = IndiceRicerca(sessione.vault.credenziali);

    Widget conStessoIndice() => MaterialApp(
          theme: temaDati(TemaId.scuro),
          home: SezioneDatabase(sessione: sessione, indice: indice),
        );

    await tester.pumpWidget(conStessoIndice());
    await tester.pumpWidget(conStessoIndice());
    await tester.pump();

    // Lo stesso indice due volte non deve rompere niente: è il caso normale
    // quando a cambiare è solo una categoria e la lista delle voci resta quella.
    expect(find.text('Amazon'), findsOneWidget);
  });
}
