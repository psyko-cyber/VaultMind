/// La giuntura che nessun altro test copre: **il client Dart contro il server
/// Python**, sul filo davvero.
///
/// I vettori garantiscono che le due lingue calcolino gli stessi byte; i test
/// di rete garantiscono che ciascuna parli con sé stessa. Nessuno dei due dice
/// che il telefono e il PC si capiscano — ed è esattamente lì che un nome di
/// campo diverso non si vedrebbe finché non hai i due dispositivi in mano.
///
/// Il server non si avvia da qui: serve l'interprete del venv, e farlo partire
/// da Dart legherebbe la suite mobile all'installazione Python. Se non c'è, il
/// test **si dichiara saltato** invece di passare fingendo.
///
/// Per eseguirlo davvero, in due terminali dalla radice del progetto:
///
///     VaultMind_Windows\.venv\Scripts\python.exe tests\ponte_sync.py
///     mobile\costruisci.ps1 -Test
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/sync_rete.dart';

const int _porta = 8799;

void main() {
  test('il client Dart parla col server Python', () async {
    // C'è qualcuno in ascolto? Altrimenti non è un fallimento, è un test che
    // non si può eseguire adesso.
    try {
      final prova = await Socket.connect('127.0.0.1', _porta,
          timeout: const Duration(seconds: 2));
      prova.destroy();
    } catch (_) {
      markTestSkipped('server Python non in ascolto sulla porta $_porta');
      return;
    }

    final ricevuti = <List<String>>[];
    final fidati = <String, String>{};
    final ctx = ContestoSync(
      idDispositivo: 'bb' * 8,
      nome: 'Telefono di prova',
      chiaveVault: List<int>.generate(32, (i) => i), // la stessa del server
      fidati: fidati,
      leggiVaultCifrato: () => 'vault-scritto-dal-dart',
      riceviVault: (b, i) async {
        ricevuti.add([b, i]);
        return {'ricevuto': true};
      },
      abbina: (id, n) => fidati[id] = n,
    );

    final esito =
        await sincronizza(ctx, '127.0.0.1', porta: _porta, codice: '123456');

    expect(esito['ok'], isTrue);
    expect(esito['con'], 'PC di prova');
    expect(ricevuti, [
      ['vault-scritto-dal-python', 'aa' * 8]
    ]);
  });
}
