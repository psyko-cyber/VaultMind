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
import 'dart:typed_data';

import 'sync_rete_comune.dart';

export 'sync_rete_comune.dart';

/// Un socket che parla a righe di JSON. Scritto a mano invece di usare
/// `StreamQueue`: una dipendenza in meno, e serve comunque il tetto sulla
/// dimensione, che i lettori pronti non hanno.
///
/// ## Chi bussa senza chiave (pentest del 10/11/2026, M2)
///
/// La porta è aperta sulla rete di casa, e chiunque ci arrivi può scrivere
/// prima di aver dimostrato qualcosa. Fino alla 7.2 poteva far tenere al
/// telefono 64 MB per collegamento, e ogni pezzo arrivato rifaceva una stringa
/// con tutto quello ricevuto fin lì: pochi collegamenti bastavano a far
/// chiudere l'app da Android. Adesso:
///
///   - si lavora sui **byte**, cercando l'a-capo solo nel pezzo appena
///     arrivato: una riga lunga costa una copia, non una per pezzo;
///   - finché nessuno chiama [fidati] il tetto è [maxPrimaRiga], non 64 MB;
///   - chi lo supera, o manda righe che nessuno ha chiesto, viene **chiuso**
///     (prima si smetteva solo di rispondergli, e lui continuava a scrivere).
class _CanaleSocket implements Canale {
  /// Il protocollo è una domanda e una risposta: di righe in attesa non ce
  /// n'è mai più di una. Chi ne accumula sta solo riempiendo la memoria.
  static const _maxRigheInAttesa = 16;

  final Socket _s;
  final _righe = <String>[];
  final _attese = <Completer<String>>[];
  final _pezzi = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? _ascolto;
  int _tetto;
  Object? _errore;
  var _chiuso = false;

  _CanaleSocket(this._s, {bool fidato = false})
      : _tetto = fidato ? maxMessaggio : maxPrimaRiga {
    _ascolto = _s.listen(
      _arrivano,
      onError: _fallisci,
      onDone: () => _fallisci(const RifiutoSync('Collegamento interrotto.')),
      cancelOnError: true,
    );
  }

  void _arrivano(List<int> dati) {
    final byte = dati is Uint8List ? dati : Uint8List.fromList(dati);
    var da = 0;
    while (da < byte.length) {
      final a = byte.indexOf(10, da); // '\n'
      final fine = a < 0 ? byte.length : a;
      if (_pezzi.length + (fine - da) > _tetto) {
        _tronca();
        return;
      }
      if (fine > da) _pezzi.add(Uint8List.sublistView(byte, da, fine));
      if (a < 0) return; // riga incompleta: il resto arriva dopo
      // `allowMalformed`: byte che non sono UTF-8 diventano una riga che non
      // è JSON, e la rifiuta `leggi`. Un'eccezione qui fermerebbe l'ascolto.
      final riga = utf8.decode(_pezzi.takeBytes(), allowMalformed: true);
      if (_attese.isNotEmpty) {
        _attese.removeAt(0).complete(riga);
      } else {
        if (_righe.length >= _maxRigheInAttesa) {
          _tronca();
          return;
        }
        _righe.add(riga);
      }
      da = a + 1;
    }
  }

  /// Fuori dai limiti: non basta smettere di ascoltare, va chiuso.
  void _tronca() {
    _fallisci(const RifiutoSync('Messaggio troppo grande.'));
    _pezzi.clear();
    _righe.clear();
    _ascolto?.cancel();
    _s.destroy();
  }

  @override
  void fidati() => _tetto = maxMessaggio;

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
  var _aperti = 0;

  Ascoltatore(this.servi, {this.porta = portaSync});

  int get portaVera => _server?.port ?? porta;

  Future<bool> avvia() async {
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, porta);
      _server = s;
      s.listen((sock) {
        // Oltre il tetto si chiude senza leggere: chi apre cento collegamenti
        // non deve costare cento buffer. Il PC vero riprova al giro dopo.
        if (_aperti >= maxCollegamenti) {
          sock.destroy();
          return;
        }
        _aperti++;
        // Rete di sicurezza: qualunque cosa succeda su UN collegamento non può
        // portarsi via l'ascolto di tutti gli altri.
        servi(_CanaleSocket(sock))
            .catchError((_) {})
            .whenComplete(() => _aperti--);
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

/// Il lato che chiama, usato **solo dai test** per fare la parte del PC. Chi
/// chiama ha scelto lui con chi parlare: il tetto è subito quello pieno.
Future<Canale> collegati(String indirizzo, int porta) async =>
    _CanaleSocket(
        await Socket.connect(indirizzo, porta,
            timeout: const Duration(seconds: 3)),
        fidato: true);
