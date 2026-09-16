/// Ogni carattere scritto nell'interfaccia deve stare nei font inclusi.
///
/// I font sono ritagliati sull'alfabeto latino (`design/prepara_font.py`). Su
/// Android un carattere che manca lo disegna il font di sistema, e nessuno se
/// ne accorge. Nella versione per browser (iPhone) i font di riserva non si
/// scaricano, di proposito — sarebbero una connessione a Google — e il
/// carattere esce come un quadratino. Trovato il 16/09/2026 con una «→».
///
/// L'elenco dei caratteri ammessi si legge da `prepara_font.py`, non si copia
/// qui: se un giorno il ritaglio cambia, il test cambia con lui.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('le stringhe dell\'interfaccia usano solo caratteri dei font inclusi', () {
    final script = File('${Directory.current.parent.path}/design/prepara_font.py')
        .readAsStringSync();
    final blocco = RegExp(r'REPERTORIO = \(([^)]*)\)').firstMatch(script)!.group(1)!;
    final ammessi = <int>{};
    for (final m in RegExp(r'U\+([0-9A-Fa-f]+)(?:-([0-9A-Fa-f]+))?').allMatches(blocco)) {
      final da = int.parse(m.group(1)!, radix: 16);
      final a = int.parse(m.group(2) ?? m.group(1)!, radix: 16);
      for (var c = da; c <= a; c++) {
        ammessi.add(c);
      }
    }
    expect(ammessi, contains(0x00E8), reason: 'il repertorio non è stato letto');

    final stringa = RegExp(r"'(?:[^'\\]|\\.)*'");
    final fuori = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final righe = f.readAsLinesSync();
      for (var n = 0; n < righe.length; n++) {
        if (righe[n].trimLeft().startsWith('//')) continue;
        for (final s in stringa.allMatches(righe[n])) {
          for (final r in s.group(0)!.runes) {
            if (!ammessi.contains(r)) {
              fuori.add('${f.path}:${n + 1} U+${r.toRadixString(16).toUpperCase()} '
                  '«${String.fromCharCode(r)}»');
            }
          }
        }
      }
    }
    expect(fuori, isEmpty,
        reason: 'caratteri che nel browser diventano quadratini: usa un '
            'equivalente latino («›» invece di «→») o allarga il ritaglio');
  });
}
