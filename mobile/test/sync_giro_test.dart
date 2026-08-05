/// Come si racconta un giro di sync in una riga sola.
///
/// Sembra poco e invece è la parte che l'utente **legge**: il sync automatico
/// è quasi silenzioso di proposito, quindi quella riga è quasi tutto quello
/// che dice di sé. Se sbaglia — dice «già allineati» quando è arrivata una
/// voce, o tace quando c'è un conflitto da decidere — il sync sembra rotto
/// anche quando ha funzionato.
///
/// Il resto di `GestoreSync` (il rinvio, la guardia contro il rimbalzo) qui
/// non si può provare: scrivere il vault passa dal ponte Kotlin, che in
/// `flutter test` non c'è. Gli stessi comportamenti sono provati sul gemello
/// Python, in `tests/test_sync_app.py`.
///
///     ..\costruisci.ps1 -Test
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/impostazioni.dart';
import 'package:vaultmind/sessione.dart';
import 'package:vaultmind/sync_gestore.dart';
import 'package:vaultmind/sync_protocollo.dart';
import 'package:vaultmind/sync_rete.dart';
import 'package:vaultmind/vault.dart';

void main() {
  /// Il difetto del 05/08/2026, e il motivo per cui era rimasto nascosto.
  ///
  /// Il telefono preparava il proprio vault cifrato solo quando era LUI a
  /// chiamare. Quando rispondeva — cioè da quando il PC ha imparato a
  /// chiamare per primo — mandava una stringa vuota, e di là compariva «il
  /// vault ricevuto non è leggibile». Nessun test poteva vederlo: quelli di
  /// `sync_rete` usano un contesto finto con un blob costante, che è valido
  /// in tutte e due i ruoli. Serviva il `GestoreSync` vero, nel ruolo di
  /// server.
  group('il vault da mandare', () {
    final chiave = Uint8List.fromList(List<int>.generate(32, (i) => i * 7 % 251));
    final salt = Uint8List.fromList(List<int>.filled(16, 3));

    Sessione sessioneConUnaVoce() => Sessione(
          Vault([
            Credenziale(
              id: 1,
              title: 'Banca',
              tags: const [],
              critical: false,
              fields: const [Campo('password', 'segreta')],
            ),
          ], salt: salt),
          chiave,
        );

    test('lo manda anche quando è lui a RISPONDERE, non solo a chiamare',
        () async {
      final sessione = sessioneConUnaVoce();
      // Il PC dev'essere già fra i fidati, altrimenti verrebbe respinto prima
      // di arrivare allo scambio dei vault — e il difetto resterebbe coperto.
      final finto = ContestoSync(
        idDispositivo: idDispositivo(),
        nome: 'PC',
        chiaveVault: chiave,
        leggiVaultCifrato: () async => await cifraVault(Vault(const [], salt: salt), chiave),
        riceviVault: (_, _) async => {},
      );
      await salvaImpostazioni(impostazioni.value.copia(
        idDispositivo: 'telefono-di-prova',
        nomeDispositivo: 'Telefono',
        syncAcceso: true,
        fidati: {finto.idDispositivo: 'PC'},
      ));

      final g = GestoreSync(sessione, porta: 0);
      expect(await g.avvia(), isTrue, reason: 'l\'ascoltatore non si è aperto');
      addTearDown(() async {
        await g.ferma();
        g.dispose();
      });

      String? arrivato;
      final ctxRicevente = ContestoSync(
        idDispositivo: finto.idDispositivo,
        nome: 'PC',
        chiaveVault: chiave,
        leggiVaultCifrato: finto.leggiVaultCifrato,
        riceviVault: (b, _) async {
          arrivato = b;
          return {};
        },
      );

      await sincronizza(ctxRicevente, '127.0.0.1', porta: g.portaVera);

      expect(arrivato, isNotNull, reason: 'il telefono non ha mandato niente');
      expect(arrivato, isNotEmpty,
          reason: 'ha mandato una stringa vuota: è esattamente il difetto');
      // E dev'essere un vault vero, non una stringa qualsiasi: si riapre.
      final riletto = await apriVaultConChiave(arrivato!, chiave);
      expect(riletto.credenziali.map((c) => c.title), ['Banca']);
    });
  });

  group('EsitoGiro', () {
    test('un giro a vuoto non ha niente da dire', () {
      const giro = EsitoGiro(trovati: 1, abbinati: 1, esiti: [EsitoSync(con: 'PC')]);
      expect(giro.qualcosaECambiato, isFalse);
      expect(giro.riassunto, isNull,
          reason: 'il sync automatico deve tacere quando non è successo niente');
    });

    test('quando arriva qualcosa lo dice, e dice da chi', () {
      const giro = EsitoGiro(
          trovati: 1, abbinati: 1, esiti: [EsitoSync(con: 'PC', aggiunte: 2)]);
      expect(giro.qualcosaECambiato, isTrue);
      expect(giro.riassunto, contains('PC'));
      expect(giro.riassunto, contains('2 in arrivo'));
    });

    test('i conflitti si contano su tutti i dispositivi', () {
      const giro = EsitoGiro(trovati: 2, abbinati: 2, esiti: [
        EsitoSync(con: 'PC', conflitti: 1),
        EsitoSync(con: 'Tablet', conflitti: 2),
      ]);
      expect(giro.conflitti, 3);
    });

    test('di errori se ne mostra uno solo', () {
      // Tre dispositivi che non rispondono sono lo stesso problema ripetuto:
      // elencarli tutti riempirebbe lo schermo senza aggiungere niente.
      const giro = EsitoGiro(trovati: 2, abbinati: 2, esiti: [
        EsitoSync(con: 'PC', errore: 'Non raggiungibile.'),
        EsitoSync(con: 'Tablet', errore: 'Nemmeno lui.'),
      ]);
      expect(giro.errore, 'Non raggiungibile.');
      expect(giro.riassunto, 'Non raggiungibile.');
    });

    test('l\'errore di uno non nasconde quello che ha portato l\'altro', () {
      const giro = EsitoGiro(trovati: 2, abbinati: 2, esiti: [
        EsitoSync(con: 'PC', aggiunte: 1),
        EsitoSync(con: 'Tablet', errore: 'Non raggiungibile.'),
      ]);
      expect(giro.qualcosaECambiato, isTrue,
          reason: 'una voce arrivata è arrivata, anche se un altro non risponde');
    });

    test('nessuno in linea non è un errore', () {
      // Il caso normale: il telefono è a casa e il PC è spento. Deve restare
      // distinguibile da «ho provato e non ci sono riuscito».
      const giro = EsitoGiro(trovati: 0, abbinati: 0);
      expect(giro.errore, isNull);
      expect(giro.riassunto, isNull);
      expect(giro.abbinati, 0);
    });
  });
}
