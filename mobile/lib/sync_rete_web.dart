/// Il sync nel browser: non c'e', e lo dice.
///
/// Un'app web non apre socket verso la rete di casa: niente scoperta in
/// broadcast, niente ascoltatore, niente connessione al PC. Stessa interfaccia
/// di `sync_rete_io.dart`, cosi' `GestoreSync` e le schermate compilano senza
/// sapere dove girano; le schermate che portano qui nel browser sono nascoste.
///
/// Fra un iPhone e un PC restano i backup: si salvano da una parte e si
/// importano dall'altra, con la stessa master password.
library;

import 'sync_rete_comune.dart';

export 'sync_rete_comune.dart';

const _nelBrowser = 'Nel browser il sync non c\'è: passa il vault con un backup.';

Future<List<Trovato>> cercaDispositivi(
  ContestoSync ctx, {
  Duration attesa = const Duration(milliseconds: 1500),
  int porta = portaScoperta,
}) async =>
    const [];

class Annunciatore {
  final ContestoSync ctx;
  final int porta, portaDelSync;

  Annunciatore(this.ctx, {this.porta = portaScoperta, this.portaDelSync = portaSync});

  Future<bool> avvia() async => false;

  Map<String, dynamic>? rispondiA(List<int> dati) => null;

  void ferma() {}
}

class Ascoltatore {
  final ContestoSync ctx;
  final int porta;
  Map<String, dynamic>? ultimo;

  Ascoltatore(this.ctx, {this.porta = portaSync});

  int get portaVera => porta;

  Future<bool> avvia() async => false;

  Future<void> ferma() async {}
}

Future<Map<String, dynamic>> sincronizza(
  ContestoSync ctx,
  String indirizzo, {
  int porta = portaSync,
  String codice = '',
  Duration attesaConnessione = attesaMax,
}) async =>
    throw const RifiutoSync(_nelBrowser);
