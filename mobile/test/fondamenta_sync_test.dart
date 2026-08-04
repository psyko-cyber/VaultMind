/// Identità delle voci, contatori e lapidi: quello su cui poggerà il sync.
///
/// Ogni test qui difende un modo concreto di **perdere dati** al primo
/// allineamento fra due dispositivi. Sono i tre incidenti classici del sync,
/// scritti prima di avere il sync — e devono comportarsi esattamente come la
/// classe `TestFondamentaSync` della suite Python, o le due piattaforme si
/// allineeranno su idee diverse di cosa è cambiato.
///
///     ..\costruisci.ps1 -Test
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/vault.dart';

Credenziale _voce(int id, {String titolo = 'Prova', String uid = ''}) =>
    Credenziale(
      id: id,
      title: titolo,
      tags: const [],
      critical: false,
      fields: const [Campo('utente', 'mario')],
      uid: uid,
    );

void main() {
  group('identità', () {
    test('una voce già esistente ricava l\'uid dal suo id', () {
      // Il punto cruciale: due dispositivi devono dare alla STESSA voce lo
      // stesso uid senza potersi parlare. Se fosse casuale, la voce 5 del PC e
      // la voce 5 del telefono diventerebbero due voci al primo sync.
      expect(_voce(5).uid, uidDerivato(5));
      expect(_voce(5).uid, '#5');
    });

    test('una voce nuova ha un uid casuale, e non si scontra', () {
      final a = _voce(801, uid: uidNuovo());
      final b = _voce(801, uid: uidNuovo());
      expect(a.id, b.id, reason: 'stesso id: è proprio il caso da reggere');
      expect(a.uid, isNot(b.uid));
      expect(a.uid.length, 32);
    });
  });

  group('contatori', () {
    test('modificare fa avanzare rev e conserva uid ed extra', () {
      final prima = Credenziale(
        id: 1,
        title: 'Prima',
        tags: const [],
        critical: false,
        fields: const [],
        uid: 'abc123',
        rev: 4,
        extra: const {'chissa': 42},
      );
      final dopo = prima.modificata(title: 'Dopo');

      expect(dopo.rev, 5);
      expect(dopo.uid, 'abc123', reason: 'l\'identità non cambia modificando');
      expect(dopo.extra['chissa'], 42);
      expect(dopo.mod, greaterThan(0));
      expect(dopo.title, 'Dopo');
    });

    test('anche spostare di categoria è una modifica', () {
      // Se non contasse, il sync non si accorgerebbe di un riordino intero:
      // 800 voci spostate e nessuna che risulta cambiata.
      final v = _voce(1);
      expect(v.conCategoria('Banche').rev, v.rev + 1);
    });
  });

  group('lapidi', () {
    test('cancellare lascia una lapide che batte la voce viva', () {
      // Se la lapide avesse lo stesso `rev` della copia ancora viva sull'altro
      // dispositivo, il merge non saprebbe chi è più avanti e la voce
      // resusciterebbe.
      final v = Vault([_voce(1), _voce(2)], salt: _salt());
      final dopo = v.senzaVoce(1);

      expect(dopo.credenziali.map((c) => c.id), [2]);
      expect(dopo.lapidi.length, 1);
      expect(dopo.lapidi.single.uid, uidDerivato(1));
      expect(dopo.lapidi.single.rev, greaterThan(_voce(1).rev));
      expect(dopo.lapidi.single.mod, greaterThan(0));
    });

    test('cancellare una voce che non c\'è non cambia niente', () {
      final v = Vault([_voce(1)], salt: _salt());
      expect(v.senzaVoce(99).lapidi, isEmpty);
    });

    test('cancellare due volte non lascia due lapidi per la stessa voce', () {
      final v = Vault([_voce(1), _voce(2)], salt: _salt());
      final dopo = v.senzaVoce(1).con(credenziali: [_voce(1), _voce(2)]).senzaVoce(1);
      expect(dopo.lapidi.where((l) => l.uid == uidDerivato(1)).length, 1);
    });
  });

  group('scrittura', () {
    test('i campi nuovi non si scrivono finché valgono il predefinito', () {
      // Protegge il vettore di prova: un vault vecchio riscritto deve restare
      // identico, altrimenti il contratto del formato cambia sotto i piedi.
      final j = _voce(1).toJson();
      expect(j.containsKey('uid'), isFalse);
      expect(j.containsKey('rev'), isFalse);
      expect(j.containsKey('mod'), isFalse);
    });

    test('una voce modificata li scrive tutti', () {
      final j = _voce(1, uid: uidNuovo()).modificata(title: 'X').toJson();
      expect(j['uid'], isNotNull);
      expect(j['rev'], 2);
      expect(j['mod'], greaterThan(0));
    });

    test('la lapide sopravvive al giro JSON', () {
      final l = const Lapide('abc', rev: 3, mod: 12345);
      final riletta = Lapide.fromJson(l.toJson());
      expect(riletta.uid, 'abc');
      expect(riletta.rev, 3);
      expect(riletta.mod, 12345);
    });
  });
}

/// Un salt qualsiasi: questi test non cifrano niente, ma `Vault` lo pretende
/// perché senza non si potrebbe riscrivere il file.
Uint8List _salt() => Uint8List.fromList(List<int>.filled(16, 7));
