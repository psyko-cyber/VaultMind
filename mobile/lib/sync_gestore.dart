/// Il sync del telefono col PC: la colla fra `sync_protocollo` (chiave e
/// messaggi), `sync_rete` (la porta aperta) e la [Sessione]. Gemello sul PC:
/// `VaultMind_Windows/app/sync_app.py`, che fa la parte di chi chiama.
///
/// ## Il telefono risponde e basta
///
/// Il PC chiama ogni pochi secondi; il telefono tiene aperta la porta 8732
/// finché il vault è sbloccato, e a ogni chiamata risponde. Non cerca
/// nessuno, non fonde niente: manda le sue voci quando il PC le chiede, e
/// adotta il risultato che il PC rimanda. La fusione esiste in un posto solo
/// (`merge.py`), così due fusioni non possono pestarsi i piedi, né divergere
/// fra due lingue.
///
/// ## Chi può chiamare
///
/// Solo un PC di cui il telefono ha la chiave: quella letta dal QR. Le chiavi
/// stanno **nel vault** (`sync_pc` nella radice del contenuto cifrato):
/// cifrate come le password, sopravvivono al cambio della master password e
/// non si leggono senza. A chi bussa senza chiave si risponde `{"no":"pc"}` e
/// si chiude: non riceve niente, né può scrivere niente.
///
/// ## Il gettone
///
/// Un valore a caso che cambia a ogni modifica delle voci. Il PC se lo
/// ricorda: se alla chiamata dopo il gettone è lo stesso e il PC non ha
/// cambiato niente, lo scambio finisce in un messaggio, senza mandare il
/// vault. Il risultato del PC si adotta solo se il gettone è ancora quello
/// che il PC ha visto: una voce salvata qui mentre il PC fondeva non va
/// persa, ci pensa il giro dopo.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'impostazioni.dart';
import 'sessione.dart';
import 'sync_protocollo.dart';
import 'sync_rete.dart';
import 'vault.dart';

/// Dove stanno, nella radice del vault, i PC collegati e le loro chiavi.
const radiceSync = 'sync_pc';

/// Per quanto il telefono aspetta il PC dopo aver inquadrato il QR. Lo
/// stesso tempo per cui il PC tiene valido il QR.
const attesaCollegamento = Duration(minutes: 10);

class PcCollegato {
  final String id, nome;
  final Uint8List chiave;
  const PcCollegato(this.id, this.nome, this.chiave);
}

/// Com'è andato l'ultimo scambio con un PC, da raccontare in una riga.
class EsitoSync {
  final String pc;
  final DateTime quando;
  final int aggiunte, aggiornate, cancellate;

  const EsitoSync(this.pc, this.quando,
      {this.aggiunte = 0, this.aggiornate = 0, this.cancellate = 0});

  bool get qualcosa => aggiunte > 0 || aggiornate > 0 || cancellate > 0;

  /// «2 voci nuove · 1 aggiornata», o «già allineati».
  String get riassunto {
    final pezzi = <String>[
      if (aggiunte == 1) '1 voce nuova',
      if (aggiunte > 1) '$aggiunte voci nuove',
      if (aggiornate == 1) '1 aggiornata',
      if (aggiornate > 1) '$aggiornate aggiornate',
      if (cancellate == 1) '1 eliminata',
      if (cancellate > 1) '$cancellate eliminate',
    ];
    return pezzi.isEmpty ? 'già allineati' : pezzi.join(' · ');
  }
}

String _pulito(Object? nome, String predefinito) {
  final n = '${nome ?? ''}'.trim().split(RegExp(r'\s+')).join(' ');
  if (n.isEmpty) return predefinito;
  return n.length <= 40 ? n : n.substring(0, 40);
}

class GestoreSync extends ChangeNotifier {
  final Sessione sessione;

  /// A parametro **solo per i test**, come nel gemello Python: con la 8732
  /// fissa un test fallirebbe a caso quando l'app vera è aperta.
  final int porta;

  Ascoltatore? _ascoltatore;
  bool _portaOccupata = false;
  bool _chiuso = false;

  String _gettone = nuovoGettone();

  /// L'ultimo vault visto: serve a capire se una notifica della sessione è
  /// una modifica delle voci (gettone nuovo) o solo della radice.
  Vault? _visto;

  /// Alzata mentre si adotta il risultato del PC: quella scrittura non è una
  /// modifica di chi usa il telefono, e il gettone lo decide lo scambio.
  bool _adottando = false;

  /// Un collegamento alla volta. Due PC che chiamano insieme si mettono in
  /// fila: due adozioni intrecciate si cancellerebbero a vicenda.
  Future<void> _coda = Future.value();

  QrPc? _attesa;
  DateTime _scade = DateTime.fromMillisecondsSinceEpoch(0);

  /// Il PC appena collegato col QR, finché la schermata non l'ha detto.
  String? collegatoOra;

  /// Per PC: l'ultimo scambio riuscito. Solo in memoria: dopo un riavvio
  /// il PC richiama entro pochi secondi.
  final ultimi = <String, EsitoSync>{};

  /// L'ultimo scambio che ha portato qualcosa, e quanti ce ne sono stati: la
  /// casa lo guarda per dire «dal PC: 2 voci nuove».
  EsitoSync? ultimoArrivo;
  int arrivi = 0;

  bool inCorso = false;

  GestoreSync(this.sessione, {this.porta = portaSync});

  Impostazioni get _imp => impostazioni.value;

  String get idDispositivo => _imp.idDispositivo;
  String get nome => _pulito(_imp.nomeDispositivo, 'Telefono');
  bool get acceso => _imp.syncAcceso;
  bool get inAscolto => _ascoltatore != null;
  bool get portaOccupata => _portaOccupata;
  int get portaVera => _ascoltatore?.portaVera ?? porta;

  void _avvisa() {
    if (!_chiuso) notifyListeners();
  }

  @override
  void dispose() {
    _chiuso = true;
    sessione.removeListener(_cambiato);
    super.dispose();
  }

  // -------------------------------------------------------------- i PC

  Map<String, PcCollegato> get pcCollegati {
    final fuori = <String, PcCollegato>{};
    final grezzi = sessione.vault.extraRadice[radiceSync];
    if (grezzi is! Map) return fuori;
    for (final e in grezzi.entries) {
      // Una voce scritta male si salta: un PC illeggibile non vale il sync
      // degli altri.
      try {
        final v = e.value as Map;
        final chiave = daEsa('${v['chiave']}');
        if (chiave.length == lunghezzaChiaveSync) {
          fuori['${e.key}'] = PcCollegato('${e.key}', _pulito(v['nome'], 'PC'), chiave);
        }
      } catch (_) {}
    }
    return fuori;
  }

  Map<String, dynamic> _grezzi() {
    final g = sessione.vault.extraRadice[radiceSync];
    return g is Map ? Map<String, dynamic>.from(g) : <String, dynamic>{};
  }

  Future<void> _registra(String id, String nomePc, Uint8List chiave) {
    final g = _grezzi()..[id] = {'nome': nomePc, 'chiave': esa(chiave)};
    return sessione.impostaRadice(radiceSync, g);
  }

  Future<bool> scollega(String id) async {
    final g = _grezzi();
    if (g.remove(id) == null) return false;
    await sessione.impostaRadice(radiceSync, g.isEmpty ? null : g);
    ultimi.remove(id);
    _avvisa();
    return true;
  }

  // ------------------------------------------------------------ il QR

  bool get inAttesaDelPc => _attesa != null && DateTime.now().isBefore(_scade);
  String get pcInAttesa => _attesa?.nome ?? '';

  /// Legge il QR del PC e aspetta che il PC chiami. Solleva
  /// [FormatException] con un messaggio da mostrare così com'è.
  Future<void> collega(String testoQr) async {
    final q = leggiQr(testoQr);
    // Chi collega un PC vuole il sync: se era spento si accende.
    if (!acceso) {
      await imposta(acceso: true);
    } else if (!inAscolto) {
      await avvia();
    }
    _attesa = q;
    _scade = DateTime.now().add(attesaCollegamento);
    collegatoOra = null;
    _avvisa();
  }

  void annullaCollegamento() {
    _attesa = null;
    _avvisa();
  }

  // ---------------------------------------------------- accendi / spegni

  Future<bool> avvia() async {
    await ferma();
    if (!acceso) return false;
    final a = Ascoltatore(_servi, porta: porta);
    if (!await a.avvia()) {
      _portaOccupata = true;
      _avvisa();
      return false;
    }
    _portaOccupata = false;
    _ascoltatore = a;
    _visto = sessione.vault;
    sessione.addListener(_cambiato);
    _avvisa();
    return true;
  }

  Future<void> ferma() async {
    sessione.removeListener(_cambiato);
    final a = _ascoltatore;
    _ascoltatore = null;
    await a?.ferma();
    _avvisa();
  }

  Future<void> imposta({String? nome, bool? acceso}) async {
    await salvaImpostazioni(_imp.copia(
      nomeDispositivo:
          (nome != null && nome.trim().isNotEmpty) ? _pulito(nome, 'Telefono') : null,
      syncAcceso: acceso,
    ));
    // Spegnerlo deve chiudere la porta subito: chi lo spegne di solito è
    // preoccupato.
    if (this.acceso) {
      if (!inAscolto) await avvia();
    } else {
      _attesa = null;
      await ferma();
    }
    _avvisa();
  }

  void _cambiato() {
    final v = sessione.vault;
    final prima = _visto;
    _visto = v;
    if (_adottando || prima == null) return;
    // Le liste si confrontano per riferimento: `Vault.con` tiene le stesse
    // quando non sono state toccate. Scrivere solo la radice (un PC
    // collegato) non è una modifica delle voci, e non deve far rimandare
    // il vault al PC.
    if (!identical(v.credenziali, prima.credenziali) ||
        !identical(v.lapidi, prima.lapidi) ||
        !identical(v.categorie, prima.categorie)) {
      _gettone = nuovoGettone();
    }
  }

  // ----------------------------------------------------------- il lavoro

  Future<void> _inCoda(Future<void> Function() lavoro) {
    final prima = _coda;
    final fatto = Completer<void>();
    _coda = fatto.future;
    return prima.then((_) => lavoro()).whenComplete(fatto.complete);
  }

  /// Un collegamento in arrivo. La prima riga si legge fuori dalla coda: chi
  /// bussa soltanto (il PC che cerca il telefono) chiude subito, e non deve
  /// far aspettare lo scambio vero.
  Future<void> _servi(Canale c) async {
    try {
      final prima = await c.leggi(attesa: const Duration(seconds: 5));
      if (prima['v'] != versioneSync) {
        c.scrivi({'no': 'versione'});
        return;
      }
      final idPc = '${prima['pc'] ?? ''}';
      final m = '${prima['m'] ?? ''}';

      // Prima la chiave del QR appena inquadrato, poi quella salvata: chi
      // ricollega lo stesso PC con un QR nuovo deve vincere sulla chiave
      // vecchia, ma un giro del PC ancora con quella non va respinto.
      final candidate = <(Uint8List, bool)>[
        if (inAttesaDelPc && _attesa!.idPc == idPc) (_attesa!.chiave, true),
        if (pcCollegati[idPc] != null) (pcCollegati[idPc]!.chiave, false),
      ];
      if (candidate.isEmpty) {
        c.scrivi({'no': 'pc'});
        return;
      }
      for (final (chiave, nuovo) in candidate) {
        Map<String, dynamic> ciao;
        try {
          ciao = await decifra(chiave, m);
        } on MessaggioRifiutato {
          continue;
        }
        final mezza = '${ciao['s'] ?? ''}';
        if (ciao['t'] != 'ciao' || mezza.length != 16) return;
        await _inCoda(() => _scambio(c, idPc, chiave, nuovo,
            _pulito(ciao['nome'], 'PC'), mezza));
        return;
      }
      c.scrivi({'no': 'chiave'});
    } catch (_) {
      // un collegamento andato male non deve fermare l'ascolto
    } finally {
      await c.chiudi();
    }
  }

  Future<void> _scambio(Canale c, String idPc, Uint8List chiave, bool nuovo,
      String nomePc, String mezza) async {
    if (nuovo) {
      // Il PC ha dimostrato di avere la chiave del QR: da qui è collegato.
      await _registra(idPc, nomePc, chiave);
      _attesa = null;
      collegatoOra = nomePc;
    } else if (pcCollegati[idPc]?.nome != nomePc) {
      await _registra(idPc, nomePc, chiave); // ha cambiato nome sul PC
    }

    final s = mezza + nuovaMetaSessione();
    Future<void> manda(Map<String, dynamic> d) async =>
        c.scrivi({'m': await cifra(chiave, {...d, 's': s})});
    Future<Map<String, dynamic>> ricevi(Set<String> tipi) async {
      final r = await c.leggi();
      if (r.containsKey('no')) throw RifiutoSync('Il PC ha rifiutato: ${r['no']}.');
      final Map<String, dynamic> d;
      try {
        d = await decifra(chiave, '${r['m'] ?? ''}');
      } on MessaggioRifiutato {
        throw const RifiutoSync('Messaggio del PC non decifrabile.');
      }
      if (d['s'] != s || !tipi.contains(d['t'])) {
        throw const RifiutoSync('Il PC ha detto qualcosa fuori protocollo.');
      }
      return d;
    }

    inCorso = true;
    _avvisa();
    try {
      await manda({'t': 'stato', 'id': idDispositivo, 'nome': nome, 'token': _gettone});
      final d = await ricevi({'fine', 'dammi'});
      if (d['t'] == 'fine') {
        ultimi[idPc] = EsitoSync(nomePc, DateTime.now());
        return;
      }

      final v = sessione.vault;
      await manda({
        't': 'vault',
        'token': _gettone,
        'voci': v.credenziali.map((x) => x.toJson()).toList(),
        'lapidi': v.lapidi.map((x) => x.toJson()).toList(),
        'categorie': v.categorie,
      });
      final r = await ricevi({'uguale', 'prendi'});
      if (r['t'] == 'uguale') {
        ultimi[idPc] = EsitoSync(nomePc, DateTime.now());
        return;
      }
      if (r['base'] != _gettone) {
        // Hai salvato qualcosa qui mentre il PC fondeva: non si adotta
        // niente, e il PC riprova fra pochi secondi con la versione nuova.
        await manda({'t': 'cambiato'});
        return;
      }

      final List<Credenziale> voci;
      final List<Lapide> lapidi;
      final List<String> categorie;
      try {
        voci = (r['voci'] as List)
            .map((x) => Credenziale.fromJson(x as Map<String, dynamic>))
            .toList();
        lapidi = ((r['lapidi'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(Lapide.fromJson)
            .where((l) => l.uid.isNotEmpty)
            .toList();
        categorie = ripulisciCategorie((r['categorie'] ?? const []) as List);
      } catch (_) {
        // Mai un vault adottato a metà: si chiude, e il vault resta com'era.
        throw const RifiutoSync('Il PC ha mandato voci illeggibili.');
      }
      await _adotta(voci, lapidi, categorie);
      await manda({'t': 'preso', 'token': _gettone});

      final riep = r['riepilogo'] is Map ? r['riepilogo'] as Map : const {};
      int n(String k) => (riep[k] as num?)?.toInt() ?? 0;
      final esito = EsitoSync(nomePc, DateTime.now(),
          aggiunte: n('aggiunte'), aggiornate: n('aggiornate'), cancellate: n('cancellate'));
      ultimi[idPc] = esito;
      if (esito.qualcosa) {
        ultimoArrivo = esito;
        arrivi++;
      }
    } finally {
      inCorso = false;
      _avvisa();
    }
  }

  /// Il risultato del PC prende il posto delle voci di qui, in una scrittura.
  ///
  /// Gli `id` possono cambiare (il telefono prende quelli del PC), quindi le
  /// voci fissate in cima si ritrovano per `uid`: senza, dopo il primo sync i
  /// pin punterebbero a voci a caso.
  Future<void> _adotta(
      List<Credenziale> voci, List<Lapide> lapidi, List<String> categorie) async {
    final uidDi = {for (final c in sessione.vault.credenziali) c.id: c.uid};
    final fissate = [
      for (final id in _imp.pinnate)
        if (uidDi[id] != null) uidDi[id]!
    ];
    _adottando = true;
    try {
      await sessione.applicaFusione(voci, lapidi, categorie);
    } finally {
      _adottando = false;
    }
    _visto = sessione.vault;
    _gettone = nuovoGettone();

    final idDi = {for (final c in voci) c.uid: c.id};
    final nuove = [
      for (final u in fissate)
        if (idDi[u] != null) idDi[u]!
    ];
    if (!listEquals(nuove, _imp.pinnate)) {
      await salvaImpostazioni(_imp.copia(pinnate: nuove));
    }
  }
}
