/// Il trasporto del sync, lato telefono (Android): **il telefono ascolta, il
/// PC chiama**. Gemello del lato che chiama: `VaultMind_Windows/app/sync_net.py`.
///
/// Non si importa direttamente: si passa da `sync_rete.dart`, che nel browser
/// sceglie `sync_rete_web.dart`.
///
/// ## Perché ascolta il telefono e non il PC
///
/// Fino al 25/10/2026 ascoltava il PC, e il firewall di Windows bloccava le
/// risposte finché qualcuno non diceva di sì a una finestra dell'UAC; in più
/// la ricerca andava in broadcast, che sul PC di Luca usciva dalla scheda di
/// VMware e non arrivava mai al telefono. Su Android un firewall per chi entra
/// non c'è, e un collegamento in uscita dal PC il firewall lo lascia passare:
/// i due problemi spariscono insieme. Il PC trova il telefono bussando alla
/// porta 8732 degli indirizzi di casa; chi bussa senza la chiave non ottiene
/// niente (vedi `sync_gestore.dart`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_rete_comune.dart';

export 'sync_rete_comune.dart';

/// Un socket che parla a righe di JSON. Scritto a mano invece di usare
/// `StreamQueue`: una dipendenza in meno, e serve comunque il tetto sulla
/// dimensione, che i lettori pronti non hanno.
class _CanaleSocket implements Canale {
  final Socket _s;
  final _righe = <String>[];
  final _attese = <Completer<String>>[];
  final _pezzi = StringBuffer();
  Object? _errore;
  var _chiuso = false;

  _CanaleSocket(this._s) {
    _s.cast<List<int>>().transform(utf8.decoder).listen(
      (t) {
        _pezzi.write(t);
        if (_pezzi.length > maxMessaggio) {
          _fallisci(const RifiutoSync('Messaggio troppo grande.'));
          return;
        }
        final testo = _pezzi.toString();
        if (!testo.contains('\n')) return;
        final parti = testo.split('\n');
        _pezzi
          ..clear()
          ..write(parti.removeLast()); // l'ultimo pezzo è incompleto
        for (final r in parti) {
          if (_attese.isNotEmpty) {
            _attese.removeAt(0).complete(r);
          } else {
            _righe.add(r);
          }
        }
      },
      onError: _fallisci,
      onDone: () => _fallisci(const RifiutoSync('Collegamento interrotto.')),
      cancelOnError: true,
    );
  }

  void _fallisci(Object e) {
    _chiuso = true;
    _errore = e;
    for (final c in _attese) {
      if (!c.isCompleted) c.completeError(e);
    }
    _attese.clear();
  }

  @override
  void scrivi(Map<String, dynamic> dato) => _s.write('${jsonEncode(dato)}\n');

  @override
  Future<Map<String, dynamic>> leggi({Duration attesa = attesaMax}) async {
    String riga;
    if (_righe.isNotEmpty) {
      riga = _righe.removeAt(0);
    } else {
      if (_chiuso) throw _errore ?? const RifiutoSync('Collegamento interrotto.');
      final c = Completer<String>();
      _attese.add(c);
      riga = await c.future.timeout(attesa,
          onTimeout: () => throw const RifiutoSync('Il PC non risponde.'));
    }
    try {
      final d = jsonDecode(riga);
      if (d is! Map<String, dynamic>) throw const RifiutoSync('Messaggio illeggibile.');
      return d;
    } on RifiutoSync {
      rethrow;
    } catch (_) {
      throw const RifiutoSync('Messaggio illeggibile.');
    }
  }

  @override
  Future<void> chiudi() async {
    try {
      await _s.flush();
    } catch (_) {}
    try {
      await _s.close();
    } catch (_) {}
    _s.destroy();
  }
}

/// La porta aperta verso il PC. Vive solo mentre il vault è sbloccato:
/// senza chiave non c'è niente da sincronizzare.
class Ascoltatore {
  final Servizio servi;
  final int porta;
  ServerSocket? _server;

  Ascoltatore(this.servi, {this.porta = portaSync});

  int get portaVera => _server?.port ?? porta;

  Future<bool> avvia() async {
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, porta);
      _server = s;
      s.listen((sock) {
        // Rete di sicurezza: qualunque cosa succeda su UN collegamento non può
        // portarsi via l'ascolto di tutti gli altri.
        servi(_CanaleSocket(sock)).catchError((_) {});
      }, onError: (_) {});
      return true;
    } catch (_) {
      return false; // porta occupata: la schermata lo dice
    }
  }

  Future<void> ferma() async {
    await _server?.close();
    _server = null;
  }
}

/// Gli indirizzi IPv4 di questo telefono sulla rete di casa, da mostrare nella
/// schermata Sincronizza: se il PC non lo trova, è il primo dato che serve.
Future<List<String>> indirizziLocali() async {
  try {
    final schede = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final s in schede)
        for (final a in s.addresses)
          if (!a.isLoopback && !a.address.startsWith('169.254.')) a.address
    ];
  } catch (_) {
    return const [];
  }
}

/// Il lato che chiama, usato **solo dai test** per fare la parte del PC.
Future<Canale> collegati(String indirizzo, int porta) async =>
    _CanaleSocket(await Socket.connect(indirizzo, porta,
        timeout: const Duration(seconds: 3)));
