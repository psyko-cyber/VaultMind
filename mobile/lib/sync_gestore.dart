/// La colla fra il motore del sync e l'app, lato telefono.
///
/// Gemello di `VaultMind_Windows/app/sync_app.py`. `sync_protocollo` decide di
/// chi fidarsi, `sync_rete` porta i byte, `fusione` decide cosa vince: qui si
/// mettono insieme.
///
/// ## Cosa sta su disco e cosa no
///
/// Nelle preferenze finiscono **id del dispositivo, nome, elenco dei fidati e
/// basi** — e nient'altro. Le chiavi per parlare con ciascun dispositivo si
/// ricavano dalla chiave del vault, quindi non c'è nessun segreto nuovo da
/// custodire.
///
/// I **conflitti in sospeso** stanno solo in memoria, di proposito. Se l'app si
/// chiude prima che tu abbia deciso, le voci restano com'erano e al sync
/// successivo il conflitto si ripresenta identico — perché la base esclude
/// proprio le voci contese. Nessuno stato da riparare a mano.
///
/// ## Quando è aperto
///
/// L'ascoltatore vive **insieme alla sessione**: si apre a vault sbloccato e si
/// chiude al blocco. Senza chiave non c'è niente da sincronizzare, e restare in
/// ascolto sarebbe solo una porta aperta che non serve a nessuno.
library;

import 'package:flutter/foundation.dart';

import 'fusione.dart';
import 'impostazioni.dart';
import 'sessione.dart';
import 'sync_protocollo.dart';
import 'sync_rete.dart';
import 'vault.dart';

/// Com'è andato l'ultimo sync, da raccontare in una riga.
class EsitoSync {
  final String con;
  final int aggiunte, aggiornate, cancellate, conflitti;
  final String? errore;

  const EsitoSync({
    this.con = '',
    this.aggiunte = 0,
    this.aggiornate = 0,
    this.cancellate = 0,
    this.conflitti = 0,
    this.errore,
  });

  bool get qualcosaECambiato =>
      aggiunte > 0 || aggiornate > 0 || cancellate > 0 || conflitti > 0;

  String get riassunto {
    if (errore != null) return errore!;
    final pezzi = <String>[
      if (aggiunte > 0) '$aggiunte in arrivo',
      if (aggiornate > 0) '$aggiornate aggiornate',
      if (cancellate > 0) '$cancellate rimosse',
      if (conflitti > 0) '$conflitti da decidere',
    ];
    return pezzi.isEmpty ? 'Già allineati' : pezzi.join(' · ');
  }
}

class GestoreSync extends ChangeNotifier {
  final Sessione sessione;

  Ascoltatore? _ascoltatore;
  Annunciatore? _annunciatore;

  String? _codice;
  DateTime _scade = DateTime.fromMillisecondsSinceEpoch(0);

  /// Conflitti da decidere, per uid, con il dispositivo da cui sono nati:
  /// serve a registrare la scelta nella base giusta.
  final conflitti = <String, Conflitto>{};
  final _daChi = <String, String>{};

  EsitoSync? ultimo;

  GestoreSync(this.sessione);

  Impostazioni get _imp => impostazioni.value;

  String get idDispositivo => _imp.idDispositivo;
  String get nome => _imp.nomeDispositivo;
  bool get acceso => _imp.syncAcceso;
  bool get inAscolto => _ascoltatore != null;
  int get portaVera => _ascoltatore?.portaVera ?? portaSync;
  Map<String, String> get fidati => Map.unmodifiable(_imp.fidati);

  // ----------------------------------------------------------- abbinamento

  /// Il codice, se è ancora valido. Scade da solo dopo 120 secondi: una
  /// finestra che resta aperta è una finestra.
  String? codiceAttivo() {
    if (_codice != null && DateTime.now().isBefore(_scade)) return _codice;
    _codice = null;
    return null;
  }

  int get secondiRimasti {
    if (codiceAttivo() == null) return 0;
    return _scade.difference(DateTime.now()).inSeconds.clamp(0, validitaCodiceS);
  }

  String apriAbbinamento() {
    _codice = codiceAbbinamento();
    _scade = DateTime.now().add(const Duration(seconds: validitaCodiceS));
    notifyListeners();
    return _codice!;
  }

  void chiudiAbbinamento() {
    _codice = null;
    notifyListeners();
  }

  // ------------------------------------------------------- accendi / spegni

  ContestoSync _contesto() => ContestoSync(
        idDispositivo: _imp.idDispositivo,
        nome: _imp.nomeDispositivo,
        chiaveVault: sessione.chiave,
        // La mappa VIVA, non una copia: l'elenco cambia mentre l'ascoltatore è
        // già aperto — è quello che succede al primo abbinamento — e con una
        // fotografia il dispositivo appena abbinato resterebbe sconosciuto.
        fidati: _imp.fidati,
        saltVault: sessione.vault.salt,
        leggiVaultCifrato: () => _cifratoOra,
        riceviVault: riceviVault,
        codiceAttivo: codiceAttivo,
        abbina: _abbina,
      );

  /// Il vault cifrato pronto da mandare. Si ricalcola a ogni sync e non si
  /// tiene in giro più del necessario.
  String _cifratoOra = '';

  Future<bool> avvia() async {
    await ferma(pulisciCodice: false);
    if (!acceso) {
      _codice = null;
      return false;
    }
    final ctx = _contesto();
    final a = Ascoltatore(ctx);
    if (!await a.avvia()) return false;
    _ascoltatore = a;
    final ann = Annunciatore(ctx, portaDelSync: a.portaVera);
    await ann.avvia();
    _annunciatore = ann;
    notifyListeners();
    return true;
  }

  Future<void> ferma({bool pulisciCodice = true}) async {
    _annunciatore?.ferma();
    _annunciatore = null;
    await _ascoltatore?.ferma();
    _ascoltatore = null;
    if (pulisciCodice) _codice = null;
    notifyListeners();
  }

  Future<void> imposta({String? nome, bool? acceso}) async {
    await salvaImpostazioni(_imp.copia(
      nomeDispositivo: (nome != null && nome.trim().isNotEmpty)
          ? nome.trim()
          : _imp.nomeDispositivo,
      syncAcceso: acceso,
    ));
    // Accendere o spegnere deve avere effetto subito, non al prossimo avvio:
    // chi lo spegne di solito lo fa perché è preoccupato.
    await avvia();
  }

  // ------------------------------------------------------------- i fidati

  void _abbina(String idPeer, String nomePeer) {
    // La mappa è quella viva dentro le impostazioni: si aggiorna qui e si
    // salva, così l'ascoltatore già aperto la vede subito.
    _imp.fidati[idPeer] = nomePeer.isEmpty ? 'dispositivo' : nomePeer;
    salvaImpostazioni(_imp);
    notifyListeners();
  }

  Future<bool> revoca(String idPeer) async {
    if (!_imp.fidati.containsKey(idPeer)) return false;
    final f = Map<String, String>.from(_imp.fidati)..remove(idPeer);
    final b = Map<String, Map<String, int>>.from(_imp.basi)..remove(idPeer);
    // Via anche la base: se un giorno si riabbina, si riparte prudenti invece
    // che con una fotografia vecchia di cui non ci si può più fidare.
    await salvaImpostazioni(_imp.copia(fidati: f, basi: b));
    notifyListeners();
    return true;
  }

  // -------------------------------------------------------------- il lavoro

  Future<List<Trovato>> cerca() async {
    final trovati = await cercaDispositivi(_contesto());
    for (final t in trovati) {
      // il nome che conosciamo noi vince su quello annunciato
      final noto = _imp.fidati[t.id];
      if (noto != null) t.nomeLocale = noto;
    }
    return trovati;
  }

  Future<EsitoSync> sincronizzaCon(Trovato d, {String codice = ''}) async {
    _cifratoOra = await sessione.testoCifrato();
    try {
      await sincronizza(_contesto(), d.indirizzo,
          porta: d.porta, codice: codice);
      return ultimo ?? const EsitoSync();
    } on RifiutoSync catch (e) {
      final esito = EsitoSync(errore: e.messaggio);
      ultimo = esito;
      notifyListeners();
      return esito;
    } catch (e) {
      final esito = EsitoSync(
          errore: 'Non è stato possibile raggiungere quel dispositivo.');
      ultimo = esito;
      notifyListeners();
      return esito;
    } finally {
      _cifratoOra = '';
    }
  }

  /// Il cuore: prende il vault dell'altro, lo fonde col nostro e applica.
  ///
  /// Quello che arriva è cifrato con la stessa chiave che abbiamo — l'ha appena
  /// dimostrato la stretta di mano — quindi si apre come si aprirebbe il
  /// proprio file. In chiaro sulla rete non è passato niente.
  Future<Map<String, dynamic>> riceviVault(String blob, String idPeer) async {
    Vault suo;
    try {
      suo = await apriVaultConChiave(blob, sessione.chiave);
    } on WrongPassword {
      ultimo = const EsitoSync(
          errore: 'I due vault hanno master password diverse.');
      notifyListeners();
      return {};
    } catch (_) {
      ultimo = const EsitoSync(errore: 'Il vault ricevuto non è leggibile.');
      notifyListeners();
      return {};
    }

    final base = _imp.basi[idPeer];
    final f = fondi(Istantanea.da(sessione.vault), Istantanea.da(suo), base);

    await sessione.applicaFusione(f.voci, f.lapidi, f.categorie);

    // La base registra solo ciò su cui siamo d'accordo: le voci contese restano
    // fuori, così al prossimo giro risultano ancora cambiate da entrambi e il
    // conflitto si ripresenta invece di sparire non deciso.
    final contesi = f.conflitti.map((c) => c.uid).toSet();
    final basi = Map<String, Map<String, int>>.from(_imp.basi);
    basi[idPeer] = {
      for (final c in f.voci)
        if (!contesi.contains(c.uid)) c.uid: c.rev
    };
    await salvaImpostazioni(_imp.copia(basi: basi));

    conflitti
      ..clear()
      ..addEntries(f.conflitti.map((c) => MapEntry(c.uid, c)));
    _daChi
      ..clear()
      ..addEntries(f.conflitti.map((c) => MapEntry(c.uid, idPeer)));

    ultimo = EsitoSync(
      con: _imp.fidati[idPeer] ?? 'dispositivo',
      aggiunte: f.aggiunte,
      aggiornate: f.aggiornate,
      cancellate: f.cancellate,
      conflitti: f.conflitti.length,
    );
    notifyListeners();
    return {};
  }

  // ------------------------------------------------------------- conflitti

  /// `scelta` = "mia" | "sua". Applica la versione scelta e chiude il caso.
  Future<bool> risolvi(String uid, String scelta) async {
    final c = conflitti[uid];
    if (c == null) return false;
    final tenuta = scelta == 'mia' ? c.mia : c.sua;

    final voci = sessione.vault.credenziali.where((v) => v.uid != uid).toList();
    final lapidi = sessione.vault.lapidi.where((l) => l.uid != uid).toList();

    if (tenuta != null) {
      // Un giro di contatore in più: la scelta è essa stessa una modifica, e
      // deve battere quella dell'altro dispositivo al prossimo sync.
      voci.add(tenuta.modificata());
    } else {
      final r = (c.revMia > c.revSua ? c.revMia : c.revSua) + 1;
      lapidi.add(Lapide(uid, rev: r, mod: oraOra()));
    }
    await sessione.applicaFusione(voci, lapidi, sessione.vault.categorie);

    // Il pezzo che fa **convergere** la scelta: registrando nella base il `rev`
    // che l'altro aveva, al prossimo giro lui risulta fermo e la mia decisione
    // vince da sola, invece di far tornare la stessa domanda per sempre.
    final idPeer = _daChi.remove(uid);
    if (idPeer != null && c.revSua > 0) {
      final basi = Map<String, Map<String, int>>.from(_imp.basi);
      basi[idPeer] = {...(basi[idPeer] ?? {}), uid: c.revSua};
      await salvaImpostazioni(_imp.copia(basi: basi));
    }

    conflitti.remove(uid);
    notifyListeners();
    return true;
  }
}
