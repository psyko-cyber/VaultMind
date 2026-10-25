/// Il sync nel browser: non c'e', e lo dice.
///
/// Un'app web non apre una porta verso la rete di casa: il PC non avrebbe
/// nessuno a cui bussare. Stessa interfaccia di `sync_rete_io.dart`, cosi'
/// `GestoreSync` compila senza sapere dove gira; le schermate che portano qui
/// nel browser sono nascoste.
///
/// Fra un iPhone e un PC restano i backup: si salvano da una parte e si
/// importano dall'altra.
library;

import 'sync_rete_comune.dart';

export 'sync_rete_comune.dart';

class Ascoltatore {
  final Servizio servi;
  final int porta;

  Ascoltatore(this.servi, {this.porta = portaSync});

  int get portaVera => porta;

  Future<bool> avvia() async => false;

  Future<void> ferma() async {}
}

Future<List<String>> indirizziLocali() async => const [];

Future<Canale> collegati(String indirizzo, int porta) async =>
    throw const RifiutoSync('Nel browser il sync non c\'è: passa il vault con un backup.');
