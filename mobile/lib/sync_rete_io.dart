/// Il trasporto del sync sulla rete locale, lato telefono (Android).
///
/// Non si importa direttamente: si passa da `sync_rete.dart`, che nel browser
/// sceglie `sync_rete_web.dart`.
///
/// Gemello di `VaultMind_Windows/app/sync_net.py`: stesso protocollo sul filo,
/// stessi nomi dei campi, stesse ragioni. Se uno dei due cambiasse una parola
/// senza l'altro, il sync smetterebbe di funzionare fra PC e telefono pur
/// continuando a funzionare fra due PC — il modo peggiore di rompersi.
///
/// ## Chi risponde alle domande sulla rete
///
/// La scoperta è in UDP, ma **la sonda è firmata**: chi cerca dimostra di
/// conoscere la chiave del vault, e solo un dispositivo con la stessa chiave sa
/// verificarla e rispondere. Per chiunque altro sulla stessa WiFi — un bar, un
/// ufficio — VaultMind non esiste: non risponde, non si annuncia, non dice il
/// proprio nome.
///
/// L'unica eccezione dura 120 secondi ed è voluta: quando **tu** chiedi di
/// aggiungere un dispositivo nuovo, che il vault non ce l'ha ancora e quindi la
/// chiave non può averla.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_protocollo.dart';
import 'sync_rete_comune.dart';

export 'sync_rete_comune.dart';


// ------------------------------------------------------------ righe di JSON

/// Un socket che parla a righe di JSON. Scritto a mano invece di usare
/// `StreamQueue`: una dipendenza in meno, e serve comunque il tetto sulla
/// dimensione, che i lettori pronti non hanno.
class _Canale {
  final Socket _s;
  final _righe = <String>[];
  final _attese = <Completer<String>>[];
  final _pezzi = StringBuffer();
  Object? _errore;
  var _chiuso = false;

  _Canale(this._s) {
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

  void scrivi(Map<String, dynamic> dato) => _s.write('${jsonEncode(dato)}\n');

  Future<Map<String, dynamic>> leggi() async {
    String riga;
    if (_righe.isNotEmpty) {
      riga = _righe.removeAt(0);
    } else {
      if (_chiuso) throw _errore ?? const RifiutoSync('Collegamento interrotto.');
      final c = Completer<String>();
      _attese.add(c);
      riga = await c.future.timeout(attesaMax,
          onTimeout: () => throw const RifiutoSync('L\'altro dispositivo non risponde.'));
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

// ----------------------------------------------------------------- scoperta

String _firmaSonda(List<int> chiave, String nonceEsa) =>
    rispostaSfida(chiave, 'sonda', daEsa(nonceEsa));

String _firmaEccomi(List<int> chiave, String nonceEsa, String id) =>
    rispostaSfida(chiave, 'eccomi:$id', daEsa(nonceEsa));

String _esa(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();


/// Chiede «c'è qualcuno col mio stesso vault?» e raccoglie le risposte.
/// La domanda è firmata: chi non ha la chiave non sa nemmeno riconoscerla.
Future<List<Trovato>> cercaDispositivi(
  ContestoSync ctx, {
  Duration attesa = const Duration(milliseconds: 1500),
  int porta = portaScoperta,
}) async {
  final nonceEsa = _esa(nonce());
  final domanda = utf8.encode(jsonEncode({
    'vm': versione,
    'tipo': 'sonda',
    'n': nonceEsa,
    'f': _firmaSonda(ctx.chiaveVault, nonceEsa),
  }));

  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  s.broadcastEnabled = true;
  final trovati = <String, Trovato>{};
  final finito = Completer<void>();

  s.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = s.receive();
    if (d == null) return;
    Map<String, dynamic> r;
    try {
      final j = jsonDecode(utf8.decode(d.data));
      if (j is! Map<String, dynamic>) return;
      r = j;
    } catch (_) {
      return;
    }
    if (r['tipo'] != 'eccomi' || r['vm'] != versione) return;
    final id = '${r['id'] ?? ''}';
    if (id.isEmpty || id == ctx.idDispositivo) return;
    // La risposta è firmata a sua volta: chi non ha la chiave non può fingersi
    // un nostro dispositivo per farsi mandare il vault.
    final f = r['f'];
    if (f != null && f != _firmaEccomi(ctx.chiaveVault, nonceEsa, id)) return;
    trovati[id] = Trovato(
      id: id,
      nome: '${r['nome'] ?? ctx.fidati[id] ?? 'dispositivo'}',
      indirizzo: d.address.address,
      porta: (r['porta'] as num?)?.toInt() ?? portaSync,
      abbinabile: r['abbinabile'] == true,
      firmata: f != null,
      salt: '${r['salt'] ?? ''}',
    );
  });

  s.send(domanda, InternetAddress('255.255.255.255'), porta);
  Timer(attesa, () {
    if (!finito.isCompleted) finito.complete();
  });
  await finito.future;
  s.close();
  return trovati.values.toList();
}

/// Risponde alle sonde. Vive solo mentre il vault è aperto.
class Annunciatore {
  final ContestoSync ctx;
  final int porta, portaDelSync;
  RawDatagramSocket? _s;

  Annunciatore(this.ctx, {this.porta = portaScoperta, this.portaDelSync = portaSync});

  Future<bool> avvia() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, porta,
          reuseAddress: true);
      _s = s;
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        // Rete di sicurezza: qualunque cosa succeda su UN pacchetto non può
        // portarsi via l'ascolto di tutti gli altri.
        try {
          final r = rispondiA(d.data);
          if (r != null) s.send(utf8.encode(jsonEncode(r)), d.address, d.port);
        } catch (_) {}
      });
      return true;
    } catch (_) {
      return false; // porta occupata: resta il sync a mano
    }
  }

  /// La decisione di rispondere o no. Pubblica perché è la parte che riguarda
  /// la privacy, e va provata senza tirare in ballo la rete.
  Map<String, dynamic>? rispondiA(List<int> dati) {
    Map<String, dynamic> d;
    try {
      // Un pacchetto UDP arriva da chiunque, e `[]` è JSON validissimo che non
      // ha `.get()`: il controllo sul tipo non è pignoleria.
      final j = jsonDecode(utf8.decode(dati));
      if (j is! Map<String, dynamic>) return null;
      d = j;
    } catch (_) {
      return null;
    }
    if (d['tipo'] != 'sonda' || d['vm'] != versione) return null;
    final nonceEsa = '${d['n'] ?? ''}';
    if (nonceEsa.isEmpty ||
        nonceEsa.length.isOdd ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(nonceEsa)) {
      return null;
    }

    final firmaGiusta = d['f'] == _firmaSonda(ctx.chiaveVault, nonceEsa);
    final inAbbinamento = ctx.codiceAttivo() != null;

    if (firmaGiusta) {
      return {
        'vm': versione,
        'tipo': 'eccomi',
        'id': ctx.idDispositivo,
        'nome': ctx.nome,
        'porta': portaDelSync,
        'abbinabile': inAbbinamento,
        'f': _firmaEccomi(ctx.chiaveVault, nonceEsa, ctx.idDispositivo),
      };
    }

    if (inAbbinamento) {
      // Finestra voluta: il dispositivo nuovo il vault non ce l'ha ancora,
      // quindi non può firmare. Riceve il salt, che non è segreto.
      return {
        'vm': versione,
        'tipo': 'eccomi',
        'id': ctx.idDispositivo,
        'nome': ctx.nome,
        'porta': portaDelSync,
        'abbinabile': true,
        'salt': _esa(ctx.saltVault),
      };
    }

    // Nessuna firma e nessun abbinamento in corso: per chi sta su questa rete,
    // qui non c'è niente.
    return null;
  }

  void ferma() {
    _s?.close();
    _s = null;
  }
}

// ---------------------------------------------------------------- il canale

String _spiega(String codice) => const {
      'versione diversa': 'Le due app hanno versioni diverse del sync: aggiornale.',
      'non abbinato':
          'Questo dispositivo non è ancora abbinato: chiedi il codice sull\'altro.',
      'codice errato': 'Codice di abbinamento errato.',
      'chiave diversa': 'L\'altro dispositivo non ha la chiave di questo vault.',
    }[codice] ??
    'Il collegamento è stato rifiutato.';

Future<String> _strettaLatoServer(_Canale c, ContestoSync ctx) async {
  final ciao = await c.leggi();
  if (ciao['vm'] != versione) {
    c.scrivi({'tipo': 'no', 'perche': 'versione diversa'});
    throw const RifiutoSync('Le due app hanno versioni diverse del sync.');
  }
  final idPeer = '${ciao['id'] ?? ''}';
  final sfidaPeer = '${ciao['sfida'] ?? ''}';
  if (idPeer.isEmpty || sfidaPeer.isEmpty) {
    throw const RifiutoSync('Presentazione incompleta.');
  }

  final atteso = ctx.codiceAttivo();
  final nuovo = !ctx.siFidaDi(idPeer);
  if (nuovo) {
    // Primo incontro: serve il codice che l'utente sta leggendo sull'altro
    // schermo. Senza, un dispositivo che conosce la master password potrebbe
    // abbinarsi da solo, senza che nessuno se ne accorga.
    if (atteso == null) {
      c.scrivi({'tipo': 'no', 'perche': 'non abbinato'});
      throw const RifiutoSync('Dispositivo non abbinato.');
    }
    if ('${ciao['codice'] ?? ''}' != atteso) {
      c.scrivi({'tipo': 'no', 'perche': 'codice errato'});
      throw const RifiutoSync('Codice di abbinamento errato.');
    }
  }

  final miaSfida = nonce();
  c.scrivi({
    'tipo': 'sfida',
    'id': ctx.idDispositivo,
    'nome': ctx.nome,
    'sfida': _esa(miaSfida),
    'risposta': rispostaSfida(ctx.chiaveVault, ctx.idDispositivo, daEsa(sfidaPeer)),
    'vault': improntaVault(ctx.chiaveVault),
  });

  final conferma = await c.leggi();
  if (!verificaSfida(
      ctx.chiaveVault, idPeer, miaSfida, '${conferma['risposta'] ?? ''}')) {
    c.scrivi({'tipo': 'no', 'perche': 'chiave diversa'});
    throw const RifiutoSync('L\'altro dispositivo non ha la chiave di questo vault.');
  }

  if (nuovo) ctx.abbina(idPeer, '${ciao['nome'] ?? 'dispositivo'}');
  return idPeer;
}

Future<Map<String, String>> _strettaLatoClient(_Canale c, ContestoSync ctx,
    {String codice = ''}) async {
  final miaSfida = nonce();
  c.scrivi({
    'vm': versione,
    'tipo': 'ciao',
    'id': ctx.idDispositivo,
    'nome': ctx.nome,
    'sfida': _esa(miaSfida),
    'codice': codice,
  });

  final r = await c.leggi();
  if (r['tipo'] == 'no') throw RifiutoSync(_spiega('${r['perche'] ?? ''}'));
  if (r['tipo'] != 'sfida') throw const RifiutoSync('Risposta inattesa.');

  final idPeer = '${r['id'] ?? ''}';
  if (!verificaSfida(ctx.chiaveVault, idPeer, miaSfida, '${r['risposta'] ?? ''}')) {
    throw const RifiutoSync('L\'altro dispositivo non ha la chiave di questo vault.');
  }
  final suoVault = r['vault'];
  if (suoVault != null && suoVault != improntaVault(ctx.chiaveVault)) {
    // Non è un errore di rete: è un vault diverso, e riprovare non serve.
    throw const RifiutoSync('I due vault hanno master password diverse. '
        'Rimanda il vault dal dispositivo su cui l\'hai cambiata.');
  }

  c.scrivi({
    'tipo': 'conferma',
    'risposta': rispostaSfida(
        ctx.chiaveVault, ctx.idDispositivo, daEsa('${r['sfida'] ?? ''}')),
  });
  final nome = '${r['nome'] ?? 'dispositivo'}';
  // Anche chi CHIAMA registra l'altro. Prima lo faceva solo chi riceveva, e il
  // risultato era un abbinamento a metà: il sync funzionava in un verso solo, e
  // nell'elenco dei fidati mancava proprio il dispositivo appena abbinato.
  if (!ctx.siFidaDi(idPeer)) ctx.abbina(idPeer, nome);
  return {'id': idPeer, 'nome': nome};
}

/// Il server del sync. Vive solo mentre il vault è aperto.
class Ascoltatore {
  final ContestoSync ctx;
  final int porta;
  ServerSocket? _server;

  /// L'ultimo esito, da mostrare nella sezione Sincronizza.
  Map<String, dynamic>? ultimo;

  Ascoltatore(this.ctx, {this.porta = portaSync});

  int get portaVera => _server?.port ?? porta;

  Future<bool> avvia() async {
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, porta, shared: false);
      _server = s;
      s.listen(_servi, onError: (_) {});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _servi(Socket sock) async {
    final c = _Canale(sock);
    try {
      final idPeer = await _strettaLatoServer(c, ctx);
      // Da qui si parla con un dispositivo che ha dimostrato di avere la chiave
      // di QUESTO vault. Quello che viaggia è comunque cifrato: in chiaro non
      // passa niente, nemmeno adesso.
      c.scrivi({'tipo': 'vault', 'blob': await ctx.leggiVaultCifrato()});
      final suo = await c.leggi();
      if (suo['tipo'] == 'vault') {
        ultimo = await ctx.riceviVault('${suo['blob'] ?? ''}', idPeer);
      }
    } catch (_) {
      // un collegamento andato male non deve fermare l'ascoltatore
    } finally {
      await c.chiudi();
    }
  }

  Future<void> ferma() async {
    await _server?.close();
    _server = null;
  }
}

/// Il lato che chiama. Torna un riepilogo di cosa è successo.
///
/// Scambio simmetrico: ognuno manda il proprio vault cifrato e fonde in casa
/// propria. Così nessuno dei due deve fidarsi della fusione dell'altro, e un
/// conflitto lasciato in sospeso non blocca l'altro dispositivo.
/// `attesaConnessione` si accorcia quando l'indirizzo è **ricordato** invece
/// che appena sentito sulla rete: un dispositivo che non c'è più farebbe
/// aspettare venti secondi a vuoto, e chi ha toccato un pulsante penserebbe che
/// si è piantato tutto. Una volta collegati si torna al tempo pieno, perché lì
/// a viaggiare è il vault intero.
Future<Map<String, dynamic>> sincronizza(
  ContestoSync ctx,
  String indirizzo, {
  int porta = portaSync,
  String codice = '',
  Duration attesaConnessione = attesaMax,
}) async {
  final sock = await Socket.connect(indirizzo, porta, timeout: attesaConnessione);
  final c = _Canale(sock);
  try {
    final chi = await _strettaLatoClient(c, ctx, codice: codice);
    final suo = await c.leggi();
    if (suo['tipo'] != 'vault') {
      throw const RifiutoSync('L\'altro dispositivo non ha mandato il vault.');
    }
    c.scrivi({'tipo': 'vault', 'blob': await ctx.leggiVaultCifrato()});
    final esito = await ctx.riceviVault('${suo['blob'] ?? ''}', chi['id']!);
    return {'ok': true, 'con': chi['nome'], 'id': chi['id'], ...esito};
  } finally {
    await c.chiudi();
  }
}
