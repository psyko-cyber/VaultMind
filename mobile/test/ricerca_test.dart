/// La ricerca portata dal PC deve comportarsi come quella del PC.
///
/// I casi qui sotto vengono da uso reale: "Netflix 798" sul telefono non
/// trovava niente perché il filtro cercava l'intera frase dentro un solo
/// pezzo, e il titolo è "Netflix (798)" — con le parentesi in mezzo.
// `flutter test` esegue i file in parallelo e Argon2 (time 3, 64 MB) non
// lascia molta CPU agli altri: il limite di 30 secondi qui non c'entra niente
// col codice in prova, scade e basta. Stessa difesa di vault_test.dart.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/ricerca.dart';
import 'package:vaultmind/vault.dart';

Credenziale _voce(String titolo, {List<String> tag = const [], List<Campo> campi = const []}) =>
    Credenziale(id: titolo.hashCode, title: titolo, tags: tag, critical: false, fields: campi);

void main() {
  final voci = [
    _voce('Netflix (798)', tag: ['social']),
    _voce('Netflix (787)', tag: ['finanza']),
    _voce('Netflix (781)', tag: ['netflix']),
    _voce('amazon.it', tag: ['shopping']),
    _voce('amazon.it (papa)'),
    _voce('Amazon AWS'),
    _voce('Banca Intesa Sanpaolo', tag: ['banca']),
    _voce('Gmail personale'),
    _voce('YouTube Premium'),
    _voce('Wifi ufficio', campi: [const Campo('chiave', 'segretissima')]),
  ];
  final indice = IndiceRicerca(voci);

  List<String> titoli(String q) => indice.cerca(q).map((r) => r.voce.title).toList();

  test('più parole insieme: il caso "Netflix 798" che non funzionava', () {
    final t = titoli('Netflix 798');
    expect(t, isNotEmpty, reason: 'non trovava niente: era il bug segnalato');
    expect(t.first, 'Netflix (798)', reason: 'la voce esatta deve venire per prima');
  });

  test('parole in ordine sparso, come le scrive un utente', () {
    expect(titoli('798 netflix').first, 'Netflix (798)');
    expect(titoli('intesa banca').first, 'Banca Intesa Sanpaolo');
  });

  test('frase discorsiva: le parole di riempimento si ignorano', () {
    expect(titoli('dammi la password di netflix'), isNotEmpty);
    expect(titoli('dammi la password di netflix').first, contains('Netflix'));
    expect(titoli('qual è la mia banca').first, 'Banca Intesa Sanpaolo');
  });

  test('titoli-dominio: "amazon" trova anche amazon.it', () {
    final t = titoli('amazon');
    expect(t.where((x) => x.toLowerCase().contains('amazon')).length, greaterThanOrEqualTo(3));
  });

  test('gli alias di marca funzionano come sul PC', () {
    // youtube è della famiglia google
    expect(titoli('google'), isNotEmpty);
    // ...ma "google" non deve tirare su le voci gmail
    expect(titoli('google').contains('Gmail personale'), isFalse,
        reason: 'alias volutamente senza gmail, come in search.py');
  });

  test('cercare senza senso non restituisce mezzo vault', () {
    expect(titoli('zxqwvbnm'), isEmpty);
  });

  test('i valori segreti non sono cercabili', () {
    // "segretissima" è il valore di un campo "chiave": non deve essere
    // indicizzato, altrimenti le password diventerebbero cercabili.
    expect(titoli('segretissima'), isEmpty);
  });

  test('il vettore di prova vero si cerca', () async {
    final dir = Directory('${Directory.current.parent.path}/tests/vettore');
    final atteso = jsonDecode(File('${dir.path}/atteso.json').readAsStringSync())
        as Map<String, dynamic>;
    final v = await apriVault(
      File('${dir.path}/vault-esempio.json').readAsStringSync(),
      atteso['master_password'] as String,
    );
    final idx = IndiceRicerca(v.credenziali);
    expect(idx.cerca('amazon').first.voce.title, 'amazon.it');
    expect(idx.cerca('banca').first.voce.title, 'Banca Esempio');
    // accenti: cercare senza deve trovare comunque
    expect(idx.cerca('accentata'), isNotEmpty);
  });
}
