/// L'import CSV del telefono legge gli export come il PC.
///
/// I file sono quelli di `tests/vettore/import/` (dati finti, uno per
/// gestore) e `atteso.json` l'ha scritto `import_csv.py`: se qui qualcosa non
/// torna, uno dei due parser è cambiato senza l'altro. Vedi
/// `tests/test_import_csv.py`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/import_csv.dart';
import 'package:vaultmind/sessione.dart';
import 'package:vaultmind/vault.dart';

void main() {
  final dir = Directory('${Directory.current.parent.path}/tests/vettore/import');
  final atteso = jsonDecode(File('${dir.path}/atteso.json').readAsStringSync())
      as Map<String, dynamic>;

  test('ci sono i casi di prova', () {
    expect(atteso.length, greaterThanOrEqualTo(7));
  });

  for (final nome in atteso.keys) {
    test('$nome come il PC', () {
      // Byte per byte, come il server riceve il file: gli a capo dentro le
      // virgolette e il BOM fanno parte della prova.
      final testo = utf8.decode(File('${dir.path}/$nome').readAsBytesSync());
      final r = leggiCsv(testo);
      final pc = atteso[nome] as Map<String, dynamic>;
      expect(r.origine, pc['source']);
      expect(r.voci.map((v) => v.toJson()).toList(), pc['entries']);
    });
  }

  test('separatore tab e colonne in più o in meno', () {
    final r = leggiCsv('title\tpassword\nA\tx\textra\nB\n');
    // B resta, senza campi, come in `parse_csv`: la scarta la schermata,
    // come sul PC la scarta l'endpoint.
    expect(r.voci.map((v) => v.toJson()).toList(), [
      {'title': 'A', 'fields': [{'label': 'Password', 'value': 'x'}], 'tags': []},
      {'title': 'B', 'fields': [], 'tags': []},
    ]);
  });

  test('file vuoto o solo BOM', () {
    expect(leggiCsv('').voci, isEmpty);
    expect(leggiCsv('﻿\n  \n').voci, isEmpty);
  });

  test('aggiungiVoci scrive una volta sola, nell\'ordine del PC', () async {
    final chiave = Uint8List.fromList(List<int>.generate(32, (i) => i));
    var scritture = 0;
    final esistente = Credenziale(
        id: 4, title: 'Vecchia', tags: const [], critical: false,
        fields: const [Campo('Utente', 'x')]);
    final s = Sessione(
        Vault([esistente], salt: Uint8List(16)), chiave,
        scrivi: (_) async => scritture++);

    final voci = leggiCsv('name,username,password,folder\n'
            'Uno,a,p1,Casa\nDue,b,p2,\n,,,\n')
        .voci;
    final n = await s.aggiungiVoci(voci.map((v) => (
          titolo: v.titolo,
          campi: [for (final (l, x) in v.campi) Campo(l, x)],
          tags: v.tags,
        )));

    expect(n, 2);
    expect(scritture, 1);
    final c = s.vault.credenziali;
    expect(c.map((v) => v.title), ['Due', 'Uno', 'Vecchia']);
    expect(c.map((v) => v.id), [6, 5, 4]);
    expect(c[1].tags, ['casa']);
    // uid casuali e diversi: due telefoni che importano lo stesso file non
    // devono produrre voci che il sync scambia per la stessa.
    expect(c[0].uid, isNot(c[1].uid));
    expect(c[0].mod, greaterThan(0));
  });
}
