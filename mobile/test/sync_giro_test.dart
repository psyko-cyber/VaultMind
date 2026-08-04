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

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/sync_gestore.dart';

void main() {
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
