/// La regola che decide **come** rispondere: una voce, più voci fra cui
/// scegliere, oppure nessuna.
///
/// È il porto di `interpret()` da `search.py`, e regge la chat del telefono.
/// Il punto che difende: quando due voci corrispondono allo stesso modo, l'app
/// **chiede** invece di indovinare — è il principio del progetto applicato
/// all'interfaccia, non un dettaglio di comodità.
///
///     ..\costruisci.ps1 -Test
///
/// Limite di tempo alzato: apre il vettore vero, quindi passa da Argon2 coi
/// parametri di produzione. Vedi la nota in `vault_test.dart`.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/ricerca.dart';
import 'package:vaultmind/vault.dart';

void main() {
  final dirVettore = Directory('${Directory.current.parent.path}/tests/vettore');

  late IndiceRicerca indice;

  setUpAll(() async {
    final atteso = jsonDecode(
        File('${dirVettore.path}/atteso.json').readAsStringSync()) as Map<String, dynamic>;
    final v = await apriVault(
      File('${dirVettore.path}/vault-esempio.json').readAsStringSync(),
      atteso['master_password'] as String,
    );
    indice = IndiceRicerca(v.credenziali);
  });

  RispostaRicerca chiedi(String q) => interpreta(indice.cerca(q, quanti: 8));

  test('un nome che identifica una voce sola: risposta secca', () {
    final r = chiedi('banca esempio');
    expect(r.esito, Esito.una);
    expect(r.voci.single.voce.title, 'Banca Esempio');
  });

  test('il titolo-dominio si trova col solo nome del servizio', () {
    // `amazon.it` indicizzato come token unico non combacerebbe "amazon", e su
    // un vault Bitwarden i titoli SONO domini: è la correzione già fatta sul PC.
    final r = chiedi('amazon');
    expect(r.esito, Esito.una);
    expect(r.voci.single.voce.title, 'amazon.it');
  });

  test('niente di pertinente: si dice, non si mostra il vault a caso', () {
    final r = chiedi('trattore cingolato');
    expect(r.esito, Esito.nessuna);
    expect(r.voci, isEmpty);
  });

  test('più voci ugualmente pertinenti: si chiede quale', () {
    // "utente" è un'etichetta presente in tre voci e non distingue niente:
    // nessuna è più specifica, quindi la domanda è legittima.
    final r = chiedi('utente');
    expect(r.esito, Esito.ambigua);
    expect(r.voci.length, greaterThan(1));
  });

  test('un termine discriminante risolve l\'ambiguità da solo', () {
    // Stessa richiesta di prima, più una parola che punta a una voce sola:
    // da ambigua deve diventare una risposta secca.
    final r = chiedi('utente banca');
    expect(r.esito, Esito.una);
    expect(r.voci.single.voce.title, 'Banca Esempio');
  });

  test('il gruppo ambiguo non supera il massimo', () {
    final r = interpreta(indice.cerca('utente', quanti: 8), massimoGruppo: 2);
    expect(r.voci.length, lessThanOrEqualTo(2));
  });

  test('su un vault vuoto non si risponde mai "eccola"', () {
    final vuoto = IndiceRicerca(const []);
    expect(interpreta(vuoto.cerca('qualsiasi cosa')).esito, Esito.nessuna);
  });
}
