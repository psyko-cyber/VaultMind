/// La casa dell'app: chat, database, categorie.
///
/// La **chat è la home**, come sul PC, dove è la cosa principale: si apre
/// l'app e si chiede quello che serve. L'elenco, che fino al 04/08/2026 era la
/// prima schermata, diventa la seconda sezione.
///
/// Qui vivono anche le due cose che valgono per tutte le sezioni: il blocco
/// per inattività e la chiusura a chiave.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../aggiornamenti.dart';
import '../impostazioni.dart';
import '../ricerca.dart';
import '../sessione.dart';
import '../sfondo.dart';
import '../sync_gestore.dart';
import '../tema.dart';
import '../vault.dart';
import 'aggiornamento.dart';
import 'categorie.dart';
import 'chat.dart';
import 'database.dart';
import 'impostazioni.dart';
import 'sblocco.dart';
import 'sincronizza.dart';
import '../icone.dart';

class SchermataCasa extends StatefulWidget {
  final Sessione sessione;
  const SchermataCasa({super.key, required this.sessione});

  @override
  State<SchermataCasa> createState() => _SchermataCasaState();
}

class _SchermataCasaState extends State<SchermataCasa>
    with WidgetsBindingObserver {
  int _sezione = 0;
  Timer? _inattivita;

  /// L'ultimo tocco sullo schermo. Il timer da solo non basta: con l'app in
  /// secondo piano un iPhone ferma i timer della versione browser (e Android
  /// può sospendere l'app), quindi chi torna dopo un'ora troverebbe il vault
  /// ancora aperto. Al rientro si guarda l'orologio, non il timer.
  DateTime _ultimoTocco = DateTime.now();
  late final GestoreSync _sync;

  /// Un giro alla volta, e non due di fila: senza, tornare in primo piano due
  /// volte in dieci secondi vorrebbe dire scambiare il vault due volte.
  bool _syncInCorso = false;
  DateTime _ultimoGiro = DateTime.fromMillisecondsSinceEpoch(0);

  IndiceRicerca? _indice;
  List<Credenziale>? _indicizzate;

  /// Le sezioni già aperte almeno una volta. La chat nasce dentro: è la home.
  ///
  /// [IndexedStack] tiene vive tutte le sezioni — ed è quello che vogliamo, per
  /// non perdere ricerca, scorrimento e conversazione — ma le **costruisce
  /// tutte a ogni ridisegno**, anche quelle che non si stanno guardando. Le
  /// Categorie sono le più care (un gruppo per categoria, e dentro una scheda
  /// per voce), e le si pagava a ogni cambio di scheda e a ogni giro di sync
  /// pur senza averle mai aperte. Dopo la prima visita la sezione resta, quindi
  /// non si perde niente: si rimanda soltanto un lavoro che non serviva ancora.
  final _visitate = <int>{0};

  /// L'indice è **uno solo per tutta la casa**, e si rifà solo quando le voci
  /// cambiano davvero.
  ///
  /// Prima lo costruivano per conto loro sia la chat sia il database, e ognuna
  /// lo rifaceva a ogni notifica della sessione: due costruzioni complete a
  /// ogni voce salvata e a ogni giro di sync, anche quando a cambiare era solo
  /// una categoria. Su 800 voci, nel browser dell'iPhone, era l'attesa a schermo
  /// fermo che si vedeva dopo ogni modifica.
  ///
  /// `identical` e non `==`: [Vault.con] tiene la stessa lista quando le voci
  /// non sono state toccate, quindi il confronto per riferimento basta e non
  /// costa niente.
  IndiceRicerca _indicePer(List<Credenziale> voci) {
    if (!identical(voci, _indicizzate)) {
      _indicizzate = voci;
      _indice = IndiceRicerca(voci);
    }
    return _indice!;
  }

  @override
  void initState() {
    super.initState();
    _riarmaBlocco();
    WidgetsBinding.instance.addObserver(this);
    // Il sync vive insieme al vault aperto: si accende qui e si spegne al
    // blocco. Senza chiave non c'è niente da sincronizzare, e restare in
    // ascolto sarebbe solo una porta aperta che non serve a nessuno.
    _sync = GestoreSync(widget.sessione);
    _sync.addListener(_aggiorna);
    _sync.avvia().then((ok) {
      if (ok) _syncAutomatico();
    });
    // Il controllo della versione si chiede da QUI, col vault già aperto, e
    // non all'avvio dell'app: la schermata di sblocco deve comportarsi
    // esattamente nello stesso modo senza rete. Niente await e niente errori
    // mostrati: se la risposta non arriva, di questa riga non resta traccia.
    _controllaAggiornamento();
  }

  @override
  void dispose() {
    _inattivita?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sync.removeListener(_aggiorna);
    _sync.ferma();
    _sync.dispose();
    super.dispose();
  }

  /// Il rientro vero: il telefono è stato in tasca, l'app è rimasta aperta, e
  /// tornando a casa la rete c'è di nuovo. Prima il sync automatico partiva
  /// **solo** allo sblocco, quindi chi non blocca mai il vault non si
  /// allineava più — ed è il caso normale, non un caso limite.
  @override
  void didChangeAppLifecycleState(AppLifecycleState stato) {
    if (stato != AppLifecycleState.resumed) return;
    final minuti = impostazioni.value.autoBlocco;
    if (minuti > 0 &&
        DateTime.now().difference(_ultimoTocco) >= Duration(minutes: minuti)) {
      _blocca();
      return;
    }
    // Chi non blocca mai il vault potrebbe non riavviare l'app per settimane:
    // il tetto delle 12 ore sta in `controlla()`, qui si guarda solo al
    // rientro. Prima del sync, che può metterci un po'.
    _controllaAggiornamento();
    if (DateTime.now().difference(_ultimoGiro) < const Duration(seconds: 20)) {
      return;   // rientri a raffica: uno vale per tutti
    }
    _syncAutomatico();
  }

  /// La versione nuova si propone una volta, e solo se non è stata rimandata.
  Future<void> _controllaAggiornamento() async {
    try {
      final novita = (await controlla()).novita;
      if (novita == null || rinviata(novita) || !mounted) return;
      await offriAggiornamento(context, novita);
    } catch (_) {
      // Non essere riusciti a sapere se c'è una versione nuova non è un
      // problema di chi sta usando l'app.
    }
  }

  void _aggiorna() {
    if (mounted) setState(() {});
  }

  /// Torni a casa, apri l'app, e i due si allineano da soli.
  ///
  /// **Quasi silenzioso di proposito**: se non c'è niente da decidere lascia
  /// una riga che sparisce da sé. Si fa vivo solo per i conflitti, che sono
  /// l'unica cosa che richiede te. Un sync automatico che chiede conferma a
  /// ogni rientro non lo terrebbe acceso nessuno.
  ///
  /// Chiesto **a mano** invece parla sempre, anche per dire che non c'era
  /// niente da fare: chi tocca un pulsante e non vede succedere nulla non sa
  /// se ha funzionato.
  Future<void> _syncAutomatico({bool aMano = false}) async {
    if (_syncInCorso) return;
    setState(() => _syncInCorso = true);
    try {
      final giro = await _sync.sincronizzaTutti();
      _ultimoGiro = DateTime.now();
      if (!mounted) return;

      if (giro.conflitti > 0) {
        _avviso(giro.riassunto ?? 'Ci sono voci da decidere.', importante: true);
      } else if (giro.errore != null) {
        if (aMano) _avviso(giro.errore!, importante: true);
      } else if (giro.qualcosaECambiato) {
        _avviso(giro.riassunto!);
      } else if (aMano) {
        _avviso(giro.abbinati == 0
            ? 'Nessun dispositivo abbinato in linea: apri l\'app sull\'altro '
                'e sblocca il vault.'
            : 'Era già tutto allineato.');
      }
    } catch (_) {
      // Il sync automatico non deve mai disturbare: se non riesce, pazienza.
      if (aMano && mounted) _avviso('Sincronizzazione non riuscita.', importante: true);
    } finally {
      if (mounted) setState(() => _syncInCorso = false);
    }
  }

  void _avviso(String testo, {bool importante = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(testo),
      duration: Duration(seconds: importante ? 6 : 3),
      action: importante
          ? SnackBarAction(label: 'Decidi', onPressed: _apriSync)
          : null,
    ));
  }

  void _apriSync() {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => SchermataSincronizza(gestore: _sync)))
        .then((_) => _riarmaBlocco());
  }

  /// Il vault si richiude da solo dopo un po' che non lo si tocca: un telefono
  /// si lascia sul tavolo molto più facilmente di un computer.
  void _riarmaBlocco() {
    _ultimoTocco = DateTime.now();
    _inattivita?.cancel();
    final minuti = impostazioni.value.autoBlocco;
    if (minuti <= 0) return;
    _inattivita = Timer(Duration(minutes: minuti), _blocca);
  }

  void _blocca() {
    if (!mounted) return;
    _sync.ferma();   // prima la porta, poi la chiave
    // Le voci decifrate se ne vanno insieme a questa schermata, e con loro la
    // chiave: dopo il blocco in memoria non resta niente di apribile.
    Navigator.of(context).popUntil((r) => r.isFirst);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SchermataSblocco(vaultPresente: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Qualsiasi tocco rimanda il blocco: si conta l'inattività vera, non il
      // tempo trascorso.
      onPointerDown: (_) => _riarmaBlocco(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Uno sfondo solo per tutte le sezioni, e DIETRO allo Scaffold, non
          // dentro: cambiando scheda la nuvola scivola al posto nuovo invece
          // di ricominciare, e quando la tastiera della chat si apre il corpo
          // si accorcia ma il cielo resta dov'era. Categorie segue il
          // database, come sul PC.
          ValueListenableBuilder<Impostazioni>(
            valueListenable: impostazioni,
            builder: (context, imp, _) => SfondoCristallo(
              tipo: _sezione == 0 ? imp.sfondoChat : imp.sfondoDatabase,
              posa: _sezione == 0 ? posaChat : posaDatabase,
            ),
          ),
          _scaffold(),
        ],
      ),
    );
  }

  Widget _scaffold() {
    return ValueListenableBuilder<Vault>(
      valueListenable: widget.sessione,
      builder: (context, vault, _) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          // Dalla 7.1 la barra non è più una fascia piena col filo sotto: sta
          // sul cielo, come la testata del PC. Il numero delle voci è sceso
          // nel filtro «Tutte» del database, dove serve.
          backgroundColor: Colors.transparent,
          shape: const Border(),
          titleSpacing: 0,
          leading: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Center(
              child: Image.asset('assets/logo.png',
                  width: 28, height: 28, excludeFromSemantics: true),
            ),
          ),
          leadingWidth: 52,
          title: const Text('VaultMind',
              style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)),
          actions: [
            // Toccarlo SINCRONIZZA, non apre una schermata: è quello che
            // vuol dire un'icona così in una barra, ed è la cosa che si fa
            // spesso. L'abbinamento e i dispositivi fidati stanno nelle
            // impostazioni, dov'è giusto che stia una cosa da configurare
            // una volta sola.
            // Nel browser niente sync (`sync_rete_web.dart`): un pulsante che
            // non trova mai nessuno insegna solo a non fidarsi dei pulsanti.
            if (!kIsWeb) IconButton(
              icon: Badge(
                isLabelVisible: _sync.conflitti.isNotEmpty,
                label: Text('${_sync.conflitti.length}'),
                child: _syncInCorso
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: context.cTenue),
                      )
                    : const IconaVM(Icone.sync),
              ),
              tooltip: 'Sincronizza ora',
              onPressed: _syncInCorso ? null : () => _syncAutomatico(aMano: true),
            ),
            IconButton(
              icon: const IconaVM(Icone.impostazioni),
              tooltip: 'Impostazioni',
              onPressed: () {
                Navigator.of(context)
                    .push(MaterialPageRoute(
                      builder: (_) => SchermataImpostazioni(
                          sessione: widget.sessione,
                          gestoreSync: _sync,
                          quanteVoci: vault.credenziali.length),
                    ))
                    .then((_) => _riarmaBlocco());
              },
            ),
            IconButton(
              icon: const IconaVM(Icone.lucchetto),
              tooltip: 'Blocca',
              onPressed: _blocca,
            ),
          ],
        ),
        // IndexedStack e non uno switch: passando da una sezione all'altra
        // non si perdono il testo cercato, lo scorrimento e la conversazione.
        body: IndexedStack(
          index: _sezione,
          children: [
            if (_visitate.contains(0))
              SezioneChat(
                  sessione: widget.sessione,
                  indice: _indicePer(vault.credenziali))
            else
              const SizedBox.shrink(),
            if (_visitate.contains(1))
              SezioneDatabase(
                  sessione: widget.sessione,
                  indice: _indicePer(vault.credenziali))
            else
              const SizedBox.shrink(),
            if (_visitate.contains(2))
              SezioneCategorie(
                  sessione: widget.sessione,
                  indice: _indicePer(vault.credenziali))
            else
              const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: _NavFluttuante(
          scelta: _sezione,
          onScelta: (i) => setState(() {
            _sezione = i;
            _visitate.add(i);
          }),
        ),
      ),
    );
  }
}

/// Le tre sezioni, in un'isola staccata dal bordo, come il binario del PC:
/// la sezione accesa ha il neon pieno. La `NavigationBar` di Material
/// metteva una fascia piena da bordo a bordo e una pillola chiara sotto
/// l'icona, che con i temi nuovi era l'unica cosa di un altro stile.
class _NavFluttuante extends StatelessWidget {
  final int scelta;
  final void Function(int) onScelta;
  const _NavFluttuante({required this.scelta, required this.onScelta});

  static const _voci = [
    (Icone.chat, 'Chat'),
    (Icone.elenco, 'Database'),
    (Icone.cartella, 'Categorie'),
  ];

  @override
  Widget build(BuildContext context) {
    final k = context.cristallo;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          height: 66,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: context.cPannello,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: context.cBordo),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < _voci.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == scelta,
                    button: true,
                    label: _voci[i].$2,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onScelta(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: i == scelta
                              ? LinearGradient(colors: [k.neon1, k.neon2])
                              : null,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconaVM(_voci[i].$1,
                                size: 21,
                                color: i == scelta ? k.suNeon : context.cTenue),
                            const SizedBox(height: 3),
                            Text(_voci[i].$2,
                                style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight:
                                        i == scelta ? FontWeight.w600 : FontWeight.w500,
                                    color: i == scelta ? k.suNeon : context.cTenue)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
