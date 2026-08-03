/// I punteggi in Dart devono combaciare con quelli del PC.
///
/// Non basta che l'ordine sia lo stesso: se i numeri divergono, prima o poi
/// divergerà anche l'ordine, su una query che nessuno ha provato. I valori
/// attesi qui sotto sono stati stampati da `search.py` sullo STESSO vettore
/// di prova (`app.search.SearchIndex.query`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/ricerca.dart';
import 'package:vaultmind/vault.dart';

void main() {
  // query -> (titolo atteso al primo posto, punteggio calcolato dal PC)
  const attesiDalPc = <String, (String, double)>{
    'amazon': ('amazon.it', 0.951),
    'banca': ('Banca Esempio', 0.714),
    'posta 2fa': ('Posta con 2FA', 1.182),
    'accentata': ('Vocé àccentata 🔐', 1.051),
  };

  test('stessi vincitori e stessi punteggi del PC', () async {
    final dir = Directory('${Directory.current.parent.path}/tests/vettore');
    final atteso = jsonDecode(File('${dir.path}/atteso.json').readAsStringSync())
        as Map<String, dynamic>;
    final vault = await apriVault(
      File('${dir.path}/vault-esempio.json').readAsStringSync(),
      atteso['master_password'] as String,
    );
    final indice = IndiceRicerca(vault.credenziali);

    attesiDalPc.forEach((query, atteso) {
      final r = indice.cerca(query);
      expect(r, isNotEmpty, reason: 'query "$query" non ha dato risultati');
      expect(r.first.voce.title, atteso.$1, reason: 'vincitore diverso per "$query"');
      expect(r.first.punteggio, closeTo(atteso.$2, 0.002),
          reason: 'punteggio diverso per "$query": la matematica ha smesso di combaciare');
    });
  });
}
