/// Il trasporto del sync, provato con socket veri su 127.0.0.1.
///
/// Non sono finti: fanno partire un ascoltatore e ci collegano un client. Quel
/// che si verifica è quello che succederà fra il telefono e il PC, meno il cavo.
///
/// I casi che contano sono quelli in cui il collegamento **deve fallire**: un
/// dispositivo mai abbinato, un codice sbagliato, un vault con un'altra master
/// password. Se uno solo di questi passasse, basterebbe stare sulla stessa
/// WiFi per farsi mandare il vault.
///
///     ..\costruisci.ps1 -Test
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/sync_protocollo.dart';
import 'package:vaultmind/sync_rete.dart';

final chiave = List<int>.generate(32, (i) => i);
final altraChiave = List<int>.generate(32, (i) => i + 1);

class Finto {
  late final ContestoSync ctx;
  final ricevuti = <List<String>>[];
  final fidati = <String, String>{};

  Finto(String nome,
      {List<int>? chiaveVault, String? codice, String blob = 'vault', Map<String, String>? gia}) {
    if (gia != null) fidati.addAll(gia);
    ctx = ContestoSync(
      idDispositivo: idDispositivo(),
      nome: nome,
      chiaveVault: chiaveVault ?? chiave,
      fidati: fidati,
      saltVault: List.filled(16, 1),
      leggiVaultCifrato: () => blob,
      riceviVault: (b, i) async {
        ricevuti.add([b, i]);
        return {'ricevuto': true};
      },
      codiceAttivo: () => codice,
      abbina: (id, n) => fidati[id] = n,
    );
  }
}

void main() {
  final daFermare = <Ascoltatore>[];

  tearDown(() async {
    for (final a in daFermare) {
      await a.ferma();
    }
    daFermare.clear();
  });

  Future<Ascoltatore> avvia(ContestoSync ctx) async {
    final a = Ascoltatore(ctx, porta: 0);
    expect(await a.avvia(), isTrue, reason: 'l\'ascoltatore non si è aperto');
    daFermare.add(a);
    return a;
  }

  group('stretta di mano', () {
    test('abbinamento col codice giusto, e i due vault si incrociano', () async {
      final srv = Finto('PC', codice: '123456', blob: 'vault-del-pc');
      final cli = Finto('Telefono', blob: 'vault-del-telefono');
      final a = await avvia(srv.ctx);

      final esito = await sincronizza(cli.ctx, '127.0.0.1',
          porta: a.portaVera, codice: '123456');

      expect(esito['ok'], isTrue);
      expect(esito['con'], 'PC');
      expect(cli.ricevuti, [
        ['vault-del-pc', srv.ctx.idDispositivo]
      ]);
      // il server riceve nel suo giro: si aspetta che finisca
      for (var i = 0; i < 50 && srv.ricevuti.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(srv.ricevuti, [
        ['vault-del-telefono', cli.ctx.idDispositivo]
      ]);
      // e da adesso si conoscono, senza codice
      expect(srv.fidati.containsKey(cli.ctx.idDispositivo), isTrue);
    });

    test('il codice sbagliato non passa', () async {
      final srv = Finto('PC', codice: '123456');
      final cli = Finto('Telefono');
      final a = await avvia(srv.ctx);
      await expectLater(
        sincronizza(cli.ctx, '127.0.0.1', porta: a.portaVera, codice: '000000'),
        throwsA(isA<RifiutoSync>()),
      );
      expect(srv.fidati, isEmpty);
    });

    test('un dispositivo mai abbinato viene respinto', () async {
      // Senza codice attivo, chi non è nell'elenco non entra — anche se
      // conosce la master password. È il senso stesso dell'elenco.
      final srv = Finto('PC');
      final cli = Finto('Telefono');
      final a = await avvia(srv.ctx);
      await expectLater(
        sincronizza(cli.ctx, '127.0.0.1', porta: a.portaVera),
        throwsA(isA<RifiutoSync>()),
      );
    });

    test('un dispositivo già abbinato non richiede il codice', () async {
      final cli = Finto('Telefono');
      final srv = Finto('PC', gia: {cli.ctx.idDispositivo: 'Telefono'});
      final a = await avvia(srv.ctx);
      final esito = await sincronizza(cli.ctx, '127.0.0.1', porta: a.portaVera);
      expect(esito['ok'], isTrue);
    });

    test('chi non ha la chiave non ottiene il vault', () async {
      // La prova che conta: uno sulla stessa WiFi, con l'elenco a suo favore,
      // ma senza la chiave del vault. Non deve ricevere niente.
      final cli = Finto('Intruso', chiaveVault: altraChiave);
      final srv = Finto('PC',
          gia: {cli.ctx.idDispositivo: 'Intruso'}, blob: 'SEGRETO');
      final a = await avvia(srv.ctx);
      await expectLater(
        sincronizza(cli.ctx, '127.0.0.1', porta: a.portaVera),
        throwsA(isA<RifiutoSync>()),
      );
      expect(cli.ricevuti, isEmpty);
    });

    test('una versione diversa si ferma subito', () async {
      final srv = Finto('PC', codice: '123456');
      final a = await avvia(srv.ctx);
      final s = await Socket.connect('127.0.0.1', a.portaVera);
      s.write('${jsonEncode({
            'vm': 99,
            'tipo': 'ciao',
            'id': 'x',
            'sfida': '00' * 16
          })}\n');
      final riga = await s.cast<List<int>>().transform(utf8.decoder).first;
      final r = jsonDecode(riga.split('\n').first) as Map<String, dynamic>;
      expect(r['tipo'], 'no');
      expect(r['perche'], 'versione diversa');
      s.destroy();
    });

    test('spazzatura non fa cadere l\'ascoltatore', () async {
      final srv = Finto('PC', codice: '123456');
      final a = await avvia(srv.ctx);
      final s = await Socket.connect('127.0.0.1', a.portaVera);
      s.write('non sono json\n');
      await s.flush();
      s.destroy();
      // e subito dopo un collegamento buono deve funzionare lo stesso
      final cli = Finto('Telefono');
      final esito = await sincronizza(cli.ctx, '127.0.0.1',
          porta: a.portaVera, codice: '123456');
      expect(esito['ok'], isTrue);
    });
  });

  group('scoperta', () {
    List<int> sonda(List<int> k, {String n = 'aa', bool firmata = true}) {
      final nonceEsa = n * 16;
      final d = <String, dynamic>{'vm': versione, 'tipo': 'sonda', 'n': nonceEsa};
      if (firmata) {
        d['f'] = rispostaSfida(k, 'sonda', daEsa(nonceEsa));
      }
      return utf8.encode(jsonEncode(d));
    }

    test('risponde a chi ha lo stesso vault, e firma a sua volta', () {
      final f = Finto('PC');
      final r = Annunciatore(f.ctx).rispondiA(sonda(chiave));
      expect(r, isNotNull);
      expect(r!['id'], f.ctx.idDispositivo);
      expect(r['nome'], 'PC');
      expect(r['f'],
          rispostaSfida(chiave, 'eccomi:${f.ctx.idDispositivo}', daEsa('aa' * 16)));
    });

    test('non risponde a un estraneo', () {
      // Per chi sta sulla stessa WiFi ma non ha il vault, qui non c'è niente.
      final f = Finto('PC');
      expect(Annunciatore(f.ctx).rispondiA(sonda(altraChiave)), isNull);
      expect(Annunciatore(f.ctx).rispondiA(sonda(chiave, firmata: false)), isNull);
    });

    test('durante l\'abbinamento risponde anche a chi non firma', () {
      // Finestra voluta: il dispositivo nuovo il vault non ce l'ha, quindi non
      // può firmare. Riceve il salt, che non è segreto.
      final f = Finto('PC', codice: '123456');
      final r = Annunciatore(f.ctx).rispondiA(sonda(chiave, firmata: false));
      expect(r, isNotNull);
      expect(r!['abbinabile'], isTrue);
      expect(r['salt'], '01' * 16);
    });

    test('finito l\'abbinamento torna invisibile', () {
      final f = Finto('PC');
      expect(Annunciatore(f.ctx).rispondiA(sonda(chiave, firmata: false)), isNull);
    });

    test('il salt non esce fuori dall\'abbinamento', () {
      final f = Finto('PC');
      expect(Annunciatore(f.ctx).rispondiA(sonda(chiave))!.containsKey('salt'), isFalse);
    });

    test('messaggi malformati non ottengono risposta', () {
      final f = Finto('PC', codice: '123456');
      final ann = Annunciatore(f.ctx);
      for (final cattivo in [
        <int>[],
        utf8.encode('{'),
        utf8.encode('[]'),
        utf8.encode(jsonEncode({'tipo': 'altro'})),
        utf8.encode(jsonEncode({'vm': 99, 'tipo': 'sonda', 'n': 'aa'})),
        utf8.encode(jsonEncode({'vm': 1, 'tipo': 'sonda', 'n': 'zz'})),
      ]) {
        expect(ann.rispondiA(cattivo), isNull, reason: utf8.decode(cattivo, allowMalformed: true));
      }
    });
  });
}
