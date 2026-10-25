/// Il sync del telefono, col [GestoreSync] **vero** e una porta vera.
///
/// Due gruppi:
///
///  - «chi chiama»: un PC finto scritto qui, per i casi che il PC vero non
///    produce mai — chi non ha la chiave, chi la sbaglia, chi bussa e chiude,
///    chi manda spazzatura. Ognuno è un modo di farsi scrivere nel vault
///    senza averne il diritto, o di rovinarlo a metà.
///  - «col PC vero»: il PC in Python (`tests/ponte_sync.py`), comandato da
///    qui. È l'unico posto dove le due lingue si parlano sul filo prima del
///    telefono in mano: il vettore `sync.json` dice che cifrano gli stessi
///    byte, non che si capiscono. Senza il venv del PC si dichiara saltato.
///
/// Il vault del telefono è in memoria (`Sessione(scrivi: …)`): niente file,
/// e nessun vault vero toccato.
///
///     ..\costruisci.ps1 -Test
// Il PC in Python apre e cifra il suo vault con Argon2, e `flutter test` fa
// girare altri file in parallelo: i 30 secondi predefiniti non bastano.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/impostazioni.dart';
import 'package:vaultmind/sessione.dart';
import 'package:vaultmind/sync_gestore.dart';
import 'package:vaultmind/sync_protocollo.dart';
import 'package:vaultmind/sync_rete.dart';
import 'package:vaultmind/vault.dart';

final _chiaveVault = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));

/// Il vault del telefono in memoria; ogni scrittura finisce in [scritti].
Sessione _sessione(List<Credenziale> voci, List<String> scritti) => Sessione(
      Vault(voci, salt: Uint8List.fromList(List<int>.filled(16, 9))),
      _chiaveVault,
      scrivi: (c) async => scritti.add(c),
    );

Credenziale _voce(int id, String titolo, String password) => Credenziale(
      id: id,
      title: titolo,
      tags: const [],
      critical: false,
      fields: [Campo('password', password)],
      uid: uidNuovo(),
      mod: oraOra(),
    );

String _password(Credenziale c) => c.fields.firstWhere((f) => f.label == 'password').value;

Future<GestoreSync> _gestore(Sessione s) async {
  impostazioni.value = Impostazioni(
      idDispositivo: '7e7e7e7e7e7e7e7e', nomeDispositivo: 'Telefono di prova');
  final g = GestoreSync(s, porta: 0); // una porta libera qualunque
  expect(await g.avvia(), isTrue, reason: 'la porta non si è aperta');
  return g;
}

// ------------------------------------------------------------ PC finto

const _idPc = '0123456789abcdef';
final _chiavePc = List<int>.generate(32, (i) => i);
String _qr(List<int> chiave, {String pc = _idPc}) =>
    'vaultmind://abbina?v=1&pc=$pc&k=${esa(chiave)}&n=PC%20finto';

/// La parte del PC, scritta a mano per poter sbagliare apposta.
class _PcFinto {
  final Canale c;
  final List<int> chiave;
  String s = '';

  _PcFinto(this.c, this.chiave);

  static Future<_PcFinto> apri(GestoreSync g, [List<int>? chiave]) async =>
      _PcFinto(await collegati('127.0.0.1', g.portaVera), chiave ?? _chiavePc);

  /// Il primo messaggio. Restituisce lo `stato` del telefono decifrato, o il
  /// rifiuto in chiaro (`{"no": …}`).
  Future<Map<String, dynamic>> ciao({String pc = _idPc, int v = 1}) async {
    c.scrivi({
      'v': v,
      'pc': pc,
      'm': await cifra(chiave, {'t': 'ciao', 'nome': 'PC finto', 's': 'abcdefabcdefabcd'}),
    });
    final r = await c.leggi();
    if (r.containsKey('no')) return r;
    final d = await decifra(chiave, r['m'] as String);
    s = d['s'] as String;
    return d;
  }

  Future<void> manda(Map<String, dynamic> d) async =>
      c.scrivi({'m': await cifra(chiave, {...d, 's': s})});

  Future<Map<String, dynamic>> ricevi() async =>
      decifra(chiave, (await c.leggi())['m'] as String);
}

// ------------------------------------------------------------- PC vero

final _radice = Directory.current.parent.path;
final _python = '$_radice/VaultMind_Windows/.venv/Scripts/python.exe';

/// `tests/ponte_sync.py` in un processo: una riga JSON per comando.
class _Ponte {
  final Process p;
  final StreamIterator<String> _righe;
  final _errori = StringBuffer();

  _Ponte(this.p)
      : _righe = StreamIterator(
            p.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
    p.stderr.transform(utf8.decoder).listen(_errori.write);
  }

  static Future<_Ponte> avvia(int portaTelefono) async => _Ponte(await Process.start(
        _python,
        ['$_radice/tests/ponte_sync.py', '$portaTelefono'],
        environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      ));

  Future<Map<String, dynamic>> leggi() async {
    final c = await _righe.moveNext().timeout(const Duration(seconds: 60),
        onTimeout: () => throw StateError('il PC non risponde.\n$_errori'));
    if (!c) throw StateError('il PC è uscito.\n$_errori');
    return jsonDecode(_righe.current) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> fai(String cosa, [Map<String, dynamic> altro = const {}]) {
    p.stdin.writeln(jsonEncode({'fai': cosa, ...altro}));
    return leggi();
  }

  Future<void> chiudi() async {
    p.stdin.writeln(jsonEncode({'fai': 'fine'}));
    await p.stdin.flush();
    await p.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      p.kill();
      return -1;
    });
  }
}

void main() {
  group('chi chiama', () {
    late List<String> scritti;
    late Sessione s;
    late GestoreSync g;

    setUp(() async {
      scritti = [];
      s = _sessione([_voce(1, 'Nota dal telefono', 'segreta')], scritti);
      g = await _gestore(s);
    });

    tearDown(() async {
      await g.ferma();
      g.dispose();
    });

    test('un PC mai collegato non riceve niente', () async {
      final pc = await _PcFinto.apri(g);
      expect(await pc.ciao(), {'no': 'pc'});
      expect(scritti, isEmpty);
    });

    test('una versione che non conosce si rifiuta, in chiaro', () async {
      await g.collega(_qr(_chiavePc));
      final pc = await _PcFinto.apri(g);
      expect(await pc.ciao(v: 2), {'no': 'versione'});
      expect(g.pcCollegati, isEmpty);
    });

    test('chi ha l\'id del PC ma non la chiave del QR non si collega', () async {
      await g.collega(_qr(_chiavePc));
      final pc = await _PcFinto.apri(g, List<int>.generate(32, (i) => 7));
      expect(await pc.ciao(), {'no': 'chiave'});
      expect(g.pcCollegati, isEmpty);
      expect(g.inAttesaDelPc, isTrue, reason: 'il PC vero può ancora arrivare');
    });

    test('bussare e chiudere non ferma l\'ascolto, e col QR ci si collega', () async {
      await g.collega(_qr(_chiavePc));
      // Il PC che cerca il telefono fa così con ogni indirizzo di casa.
      for (var i = 0; i < 3; i++) {
        await (await collegati('127.0.0.1', g.portaVera)).chiudi();
      }

      final pc = await _PcFinto.apri(g);
      final stato = await pc.ciao();
      expect(stato['t'], 'stato');
      expect(stato['id'], '7e7e7e7e7e7e7e7e');
      expect(stato['nome'], 'Telefono di prova');
      expect(stato['s'], startsWith('abcdefabcdefabcd'));
      expect((stato['s'] as String).length, 32);
      await pc.manda({'t': 'fine'});

      expect(g.pcCollegati.keys, [_idPc]);
      expect(g.pcCollegati[_idPc]!.nome, 'PC finto');
      expect(g.collegatoOra, 'PC finto');
      expect(g.inAttesaDelPc, isFalse);
      // La chiave sta nel vault, cifrata con lui: nessun file in più.
      final riletto = await apriVaultConChiave(scritti.last, _chiaveVault);
      expect((riletto.extraRadice[radiceSync] as Map)[_idPc]['chiave'], esa(_chiavePc));
    });

    test('un risultato fuso su una versione vecchia non si adotta', () async {
      await g.collega(_qr(_chiavePc));
      final pc = await _PcFinto.apri(g);
      await pc.ciao();
      await pc.manda({'t': 'dammi'});
      final v = await pc.ricevi();
      expect(v['t'], 'vault');
      expect((v['voci'] as List).single['title'], 'Nota dal telefono');

      await pc.manda({
        't': 'prendi',
        'base': 'un-gettone-di-prima',
        'voci': const [],
        'lapidi': const [],
        'categorie': const [],
      });
      expect((await pc.ricevi())['t'], 'cambiato');
      expect(s.vault.credenziali.single.title, 'Nota dal telefono');
    });

    test('voci illeggibili dal PC: il vault resta com\'era', () async {
      await g.collega(_qr(_chiavePc));
      final pc = await _PcFinto.apri(g);
      await pc.ciao();
      await pc.manda({'t': 'dammi'});
      final v = await pc.ricevi();
      final prima = scritti.length;

      await pc.manda({
        't': 'prendi',
        'base': v['token'],
        'voci': ['non una voce'],
        'lapidi': const [],
        'categorie': const [],
      });
      await expectLater(pc.c.leggi(), throwsA(isA<RifiutoSync>()));
      expect(s.vault.credenziali.single.title, 'Nota dal telefono');
      expect(scritti.length, prima, reason: 'niente scritto a metà');

      // E l'ascolto c'è ancora.
      final altro = await _PcFinto.apri(g);
      expect((await altro.ciao())['t'], 'stato');
    });

    test('un messaggio con la sessione di un altro scambio si rifiuta', () async {
      await g.collega(_qr(_chiavePc));
      final pc = await _PcFinto.apri(g);
      await pc.ciao();
      pc.s = 'abcdefabcdefabcd0000000000000000'; // registrato da un giro vecchio
      await pc.manda({'t': 'dammi'});
      await expectLater(pc.c.leggi(), throwsA(isA<RifiutoSync>()));
    });
  });

  group('col PC vero', () {
    final manca = !File(_python).existsSync();
    late List<String> scritti;
    late Sessione s;
    late GestoreSync g;
    late _Ponte pc;

    Credenziale? suTelefono(String titolo) =>
        s.vault.credenziali.where((c) => c.title == titolo).firstOrNull;

    setUpAll(() async {
      if (manca) return;
      scritti = [];
      s = _sessione([_voce(1, 'Nota dal telefono', 'segreta')], scritti);
      g = await _gestore(s);
      impostazioni.value = impostazioni.value.copia(pinnate: [1]);
      pc = await _Ponte.avvia(g.portaVera);
      final uri = (await pc.leggi())['uri'] as String;
      await g.collega(uri);
    });

    tearDownAll(() async {
      if (manca) return;
      await pc.chiudi();
      await g.ferma();
      g.dispose();
    });

    test('il primo giro unisce i due vault', () async {
      final r = await pc.fai('giro');
      final tel = (r['telefoni'] as List).single as Map;
      expect(tel['esito'], 'sincronizzato');
      expect(tel['nome'], 'Telefono di prova');
      const tutti = ['Banca dal PC', 'Nota dal telefono', 'Posta dal PC'];
      expect(r['titoli'], tutti);
      expect(s.vault.credenziali.map((c) => c.title).toList()..sort(), tutti);
      expect(_password(suTelefono('Banca dal PC')!), 'dal-pc');
      expect(suTelefono('Banca dal PC')!.critical, isTrue);

      expect(g.pcCollegati.length, 1);
      expect(g.ultimi.values.single.aggiunte, 2);
      // Il pin segue la voce anche se il PC le ha dato un altro id.
      expect(impostazioni.value.pinnate, [suTelefono('Nota dal telefono')!.id]);
    });

    test('il giro dopo, senza novità, non manda il vault', () async {
      final prima = scritti.length;
      final r = await pc.fai('giro');
      expect((r['telefoni'] as List).single['esito'], 'allineato');
      expect(scritti.length, prima, reason: 'niente da scrivere sul telefono');
    });

    test('una modifica sul PC arriva al telefono', () async {
      await pc.fai('modifica', {'titolo': 'Banca dal PC', 'password': 'cambiata-sul-pc'});
      await pc.fai('aggiungi', {'titolo': 'Nuova dal PC'});
      await pc.fai('giro');
      expect(_password(suTelefono('Banca dal PC')!), 'cambiata-sul-pc');
      expect(suTelefono('Nuova dal PC'), isNotNull);
      expect(g.arrivi, greaterThanOrEqualTo(2));
    });

    test('una cancellazione sul PC arriva al telefono', () async {
      await pc.fai('cancella', {'titolo': 'Nuova dal PC'});
      await pc.fai('giro');
      expect(suTelefono('Nuova dal PC'), isNull);
    });

    test('una cancellazione sul telefono arriva al PC', () async {
      await s.eliminaVoce(suTelefono('Posta dal PC')!.id);
      final r = await pc.fai('giro');
      expect(r['titoli'], ['Banca dal PC', 'Nota dal telefono']);
      expect((await pc.fai('voce', {'titolo': 'Posta dal PC'}))['voce'], isNull);
    });

    test('una modifica sul telefono arriva al PC', () async {
      final b = suTelefono('Banca dal PC')!;
      await s.modificaVoce(b.id,
          titolo: b.title,
          campi: const [Campo('password', 'cambiata-sul-telefono')],
          tags: b.tags,
          critica: b.critical,
          categoria: b.categoria);
      await pc.fai('giro');
      final v = (await pc.fai('voce', {'titolo': 'Banca dal PC'}))['voce'] as Map;
      expect((v['fields'] as List).single['value'], 'cambiata-sul-telefono');
    });

    test('il vault scritto sul telefono si riapre, con le voci e il PC', () async {
      final v = await apriVaultConChiave(scritti.last, _chiaveVault);
      expect(v.credenziali.map((c) => c.title).toList()..sort(),
          ['Banca dal PC', 'Nota dal telefono']);
      expect((v.extraRadice[radiceSync] as Map).length, 1);
      expect(v.lapidi.length, 2, reason: 'le due voci cancellate');
    });
  }, skip: !File(_python).existsSync() ? 'manca il venv del PC ($_python)' : false);
}
