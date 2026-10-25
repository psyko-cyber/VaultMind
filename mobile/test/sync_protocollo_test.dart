/// I messaggi del sync, provati sugli **stessi byte** della suite Python.
///
/// `tests/vettore/sync.json` fissa chiave, nonce e testo: il messaggio cifrato
/// che esce qui deve essere identico a quello di `sync_protocol.py`, e il QR
/// del PC deve leggersi uguale. Se divergessero, il primo collegamento
/// fallirebbe sempre — e senza questo file lo si scoprirebbe col telefono in
/// mano.
///
///     ..\costruisci.ps1 -Test
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/sync_protocollo.dart';

void main() {
  late Map<String, dynamic> v;
  late List<int> chiave;

  setUpAll(() {
    final f = File('${Directory.current.parent.path}/tests/vettore/sync.json');
    expect(f.existsSync(), isTrue, reason: 'vettore del sync non trovato');
    v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    chiave = daEsa(v['chiave_hex'] as String);
  });

  group('vettore condiviso con Python', () {
    test('il JSON compatto è quello di Python', () {
      expect(jsonEncode(v['dati']), v['chiaro']);
    });

    test('cifrare dà esattamente m', () async {
      final nonce = daEsa(v['nonce_hex'] as String);
      expect(await cifra(chiave, v['dati'] as Map<String, dynamic>, nonce: nonce), v['m']);
    });

    test('decifrare m ridà i dati', () async {
      expect(await decifra(chiave, v['m'] as String), v['dati']);
    });

    test('la stessa AAD', () {
      expect(utf8.decode(aadSync), v['aad']);
    });

    test('il QR del PC', () {
      final qr = v['qr'] as Map<String, dynamic>;
      final letto = leggiQr(qr['uri'] as String);
      expect(letto.versione, qr['v']);
      expect(letto.idPc, qr['pc']);
      expect(letto.nome, qr['nome']);
      expect(esa(letto.chiave), qr['chiave_hex']);
    });

    test('i QR che non sono del PC si rifiutano, dicendo cosa c\'era', () {
      for (final uri in (v['qr_non_validi'] as List).cast<String>()) {
        expect(() => leggiQr(uri), throwsFormatException, reason: uri);
      }
      expect(
          () => leggiQr('https://example.com'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'messaggio', contains('example.com'))));
    });
  });

  group('proprietà', () {
    final k = List<int>.generate(32, (i) => i);

    test('un\'altra chiave non legge', () async {
      final m = await cifra(k, {'t': 'ciao'});
      expect(() => decifra(List<int>.generate(32, (i) => i + 1), m),
          throwsA(isA<MessaggioRifiutato>()));
    });

    test('un byte cambiato non passa', () async {
      final grezzo = base64.decode(await cifra(k, {'t': 'ciao'}));
      for (final i in [0, 12, grezzo.length - 1]) {
        final rotto = [...grezzo];
        rotto[i] ^= 1;
        expect(() => decifra(k, base64.encode(rotto)), throwsA(isA<MessaggioRifiutato>()),
            reason: 'posizione $i');
      }
    });

    test('spazzatura dalla rete non passa', () async {
      for (final t in ['', 'non-base64!!', base64.encode(utf8.encode('corto'))]) {
        expect(() => decifra(k, t), throwsA(isA<MessaggioRifiutato>()), reason: t);
      }
    });

    test('il nonce cambia ogni volta', () async {
      final a = base64.decode(await cifra(k, {'t': 'ciao'}));
      final b = base64.decode(await cifra(k, {'t': 'ciao'}));
      expect(a.sublist(0, 12), isNot(b.sublist(0, 12)));
    });

    test('identificativi e gettoni', () {
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(idDispositivo()), isTrue);
      expect(nuovaMetaSessione().length, 16);
      expect(nuovoGettone(), isNot(nuovoGettone()));
    });
  });
}
