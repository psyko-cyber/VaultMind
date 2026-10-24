/// Il controllo degli aggiornamenti: confronto fra versioni, lettura della
/// risposta di GitHub, impronte.
///
/// Il vettore `tests/vettore/versioni.json` è la stessa cosa che esegue la
/// suite Python (`tests/test_aggiornamenti.py`): senza, le due
/// implementazioni del confronto possono divergere in silenzio, e il risultato
/// è un'app che si aggiorna sul PC e non sul telefono — o un telefono che
/// propone per sempre di installare la versione che ha già.
///
/// Niente rete, qui dentro: un test che chiama GitHub fallisce in treno.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/aggiornamenti.dart';
import 'package:vaultmind/impostazioni.dart';
import 'package:vaultmind/versione.dart';

String _release(
        {String tag = '7.0',
        List<String> allegati = const ['VaultMind.apk', 'SHA256SUMS.txt']}) =>
    jsonEncode({
      'tag_name': tag,
      'html_url': 'https://github.com/psyko-cyber/VaultMind/releases/tag/$tag',
      'body': '## Novita\n**Aggiornamenti dentro l\'app**\n\n\n- e altro',
      'assets': [
        for (final n in allegati)
          {'name': n, 'browser_download_url': 'https://esempio/$n'}
      ],
    });

void main() {
  group('confronto fra versioni (vettore condiviso con Python)', () {
    late List<dynamic> casi;

    setUpAll(() {
      final f =
          File('${Directory.current.parent.path}/tests/vettore/versioni.json');
      expect(f.existsSync(), isTrue, reason: 'vettore delle versioni non trovato');
      casi = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)['casi']
          as List;
      expect(casi.length, greaterThan(10), reason: 'il vettore si è svuotato');
    });

    test('ogni caso del vettore, come in Python', () {
      for (final c in casi.cast<Map<String, dynamic>>()) {
        expect(piuRecente('${c['a']}', '${c['b']}'), c['piuRecente'],
            reason: '${c['nome']} — ${c['perche'] ?? ''}');
      }
    });
  });

  group('la risposta di GitHub', () {
    test('una release vera', () {
      final n = leggiRelease(_release())!;
      expect(n.versione, '7.0');
      expect(n.download, 'https://esempio/VaultMind.apk');
      expect(n.somme, 'https://esempio/SHA256SUMS.txt');
      expect(n.scaricabile, isTrue);
    });

    test('il v del tag sparisce', () {
      expect(leggiRelease(_release(tag: 'v7.1'))!.versione, '7.1');
    });

    test('senza SHA256SUMS non si installa da dentro l\'app', () {
      // Resta il pulsante che apre la pagina: meglio una strada a mano che un
      // APK installato senza aver verificato niente.
      final n = leggiRelease(_release(allegati: const ['VaultMind.apk']))!;
      expect(n.scaricabile, isFalse);
    });

    test('il setup di Windows non è l\'APK', () {
      final n = leggiRelease(_release(
          allegati: const ['VaultMind-Setup.exe', 'SHA256SUMS.txt']))!;
      expect(n.download, isNull);
      expect(n.scaricabile, isFalse);
    });

    test('risposte che non sono release', () {
      for (final corpo in <String>[
        '<html>Accedi alla rete</html>',
        '',
        '[]',
        'null',
        '{"tag_name": "ultima"}',
        '{"tag_name": ""}',
        '{"tag_name": "7.0; rm -rf"}',
      ]) {
        expect(leggiRelease(corpo), isNull, reason: corpo);
      }
    });

    test('allegati malformati non fanno cadere niente', () {
      final n = leggiRelease(jsonEncode({
        'tag_name': '7.0',
        'assets': [
          'non un oggetto',
          {'name': 'VaultMind.apk'},
          {'name': 'VaultMind.apk', 'browser_download_url': 42},
        ],
      }))!;
      expect(n.download, isNull);
    });

    test('la novità sopravvive a un giro nelle preferenze', () {
      final n = leggiRelease(_release())!;
      final tornata = Novita.daJson(n.toJson())!;
      expect(tornata.versione, n.versione);
      expect(tornata.download, n.download);
      expect(tornata.somme, n.somme);
      expect(Novita.daJson(const {}), isNull);
      expect(Novita.daJson(null), isNull);
    });
  });

  group('note e impronte', () {
    test('le note diventano testo semplice', () {
      final note = notePulite(leggiRelease(_release())!.note);
      expect(note.contains('#'), isFalse);
      expect(note.contains('**'), isFalse);
      expect(note.contains('\n\n\n'), isFalse);
      expect(note.startsWith('Novita'), isTrue);
    });

    test('le note lunghe si tagliano', () {
      final note =
          notePulite(List.generate(50, (i) => '$i').join('\n'), righe: 5);
      expect(note.split('\n').length, 6);
      expect(note.split('\n').last, '…');
    });

    test('i formati di SHA256SUMS.txt', () {
      final atteso = 'a' * 64;
      for (final riga in [
        '$atteso *VaultMind.apk',
        '$atteso  VaultMind.apk',
        'b${'a' * 63} *altro.apk\n$atteso *VaultMind.apk',
      ]) {
        expect(shaAtteso(riga, 'VaultMind.apk'), atteso, reason: riga);
      }
      expect(shaAtteso('${'A' * 64} *x.apk', 'x.apk'), 'a' * 64,
          reason: 'maiuscole normalizzate');
    });

    test('impronta assente o riga rotta', () {
      for (final sums in [
        '',
        'non un\'impronta  VaultMind.apk',
        '${'a' * 63} *VaultMind.apk',
        '${'a' * 64} *altro.apk',
      ]) {
        expect(shaAtteso(sums, 'VaultMind.apk'), isNull, reason: sums);
      }
    });
  });

  group('«più tardi»', () {
    test('vale per quella versione e per 20 ore', () {
      final adesso = DateTime.now().millisecondsSinceEpoch;
      const nuova = Novita(versione: '99.0', pagina: 'https://esempio');
      impostazioni.value = Impostazioni();
      expect(rinviata(nuova), isFalse);

      impostazioni.value = Impostazioni(
          aggRinviata: '99.0', aggRinviataQuando: adesso);
      expect(rinviata(nuova), isTrue);
      expect(rinviata(const Novita(versione: '99.1', pagina: 'https://esempio')),
          isFalse,
          reason: 'una versione ancora più nuova si propone');

      impostazioni.value = Impostazioni(
          aggRinviata: '99.0',
          aggRinviataQuando: adesso - (rinvioOre + 1) * 3600 * 1000);
      expect(rinviata(nuova), isFalse, reason: 'scaduto il rinvio si ripropone');
      impostazioni.value = Impostazioni();
    });

    test('lo stato degli aggiornamenti sopravvive al file delle preferenze', () {
      final i = Impostazioni(
        aggAttivi: false,
        aggControllo: 1700000000000,
        aggTrovata: const {'versione': '9.9', 'pagina': 'https://esempio'},
        aggRinviata: '9.9',
        aggRinviataQuando: 1700000000001,
      );
      final tornate = Impostazioni.fromJson(jsonDecode(jsonEncode(i.toJson())));
      expect(tornate.aggAttivi, isFalse);
      expect(tornate.aggControllo, 1700000000000);
      expect(Novita.daJson(tornate.aggTrovata)!.versione, '9.9');
      expect(tornate.aggRinviata, '9.9');
      expect(tornate.aggRinviataQuando, 1700000000001);
      // Il predefinito è acceso: chi non ha mai visto questa impostazione
      // riceve il controllo, non il silenzio.
      expect(Impostazioni.fromJson(const {}).aggAttivi, isTrue);
      expect(Impostazioni.fromJson(const {}).aggTrovata, isEmpty);
    });
  });

  test('la versione dell\'app è un numero, e non dice v', () {
    expect(RegExp(r'^\d+(\.\d+)*$').hasMatch(versioneApp), isTrue);
    expect(piuRecente(versioneApp, versioneApp), isFalse);
  });

  test('pubspec.yaml e versione.dart dicono lo stesso numero', () {
    // `versionName` dell'APK viene da pubspec; il numero che l'app confronta
    // col tag della release viene da `versione.dart`. Se divergono, il
    // telefono scarica un aggiornamento e si ritrova con quello che aveva.
    // Lo controlla anche `tests/test_versione.py` (e rilascio.ps1), ma questo
    // test gira dentro `costruisci.ps1`, cioè prima di ogni APK.
    final m = RegExp(r'^version:\s*([0-9.]+)\+(\d+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(m, isNotNull, reason: 'version: non trovata in pubspec.yaml');
    List<int> tre(String v) =>
        [...v.split('.').map(int.parse), 0, 0].take(3).toList();
    expect(tre(m!.group(1)!), tre(versioneApp));
    // Il versionCode deve seguire la versione (6.9 -> 69) e solo crescere:
    // Android rifiuta un APK con un numero più basso di quello installato.
    final v = tre(versioneApp);
    expect(int.parse(m.group(2)!), greaterThanOrEqualTo(v[0] * 10 + v[1]));
  });
}
