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

  /// Appena dentro, apri Sincronizza con la fotocamera pronta: è il seguito
  /// di «Collegati al PC» sulla prima schermata, per chi ha appena creato il
  /// vault apposta.
  final bool collegaPc;

  const SchermataCasa({super.key, required this.sessione, this.collegaPc = false});

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

  /// Quanti arrivi dal PC sono già stati detti con un avviso.
  int _arriviDetti = 0;

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
    // Il sync vive insieme al vault aperto: la porta si apre qui e si chiude
    // al blocco. Senza chiave non c'è niente da sincronizzare, e restare in
    // ascolto sarebbe solo una porta aperta che non serve a nessuno. Da qui
    // in poi è il PC a chiamare: il telefono non deve fare altro.
    _sync = GestoreSync(widget.sessione);
    _sync.addListener(_novitaSync);
    _sync.avvia();
    if (widget.collegaPc && !kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _apriSync(inquadra: true));
    }
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
    _sync.removeListener(_novitaSync);
    _sync.ferma();
    _sync.dispose();
    super.dispose();
  }

  /// Il rientro: il telefono è stato in tasca con l'app aperta. Android può
  /// aver chiuso la porta mentre l'app dormiva, quindi la si riapre: costa
  /// niente, e senza il PC busserebbe a una porta chiusa finché non riavvii.
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
    // rientro.
    _controllaAggiornamento();
    if (_sync.acceso && !_sync.inCorso) _sync.avvia();
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

  /// Il PC ha portato qualcosa: lo si dice in una riga che sparisce da sé.
  /// Gli scambi in cui non cambia niente — quasi tutti, uno ogni pochi
  /// secondi — non dicono niente: un avviso ogni cinque secondi non lo
  /// terrebbe acceso nessuno.
  void _novitaSync() {
    if (!mounted) return;
    setState(() {});
    final e = _sync.ultimoArrivo;
    if (e == null || _sync.arrivi == _arriviDetti) return;
    _arriviDetti = _sync.arrivi;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Da «${e.pc}»: ${e.riassunto}'),
      duration: const Duration(seconds: 3),
    ));
  }

  void _apriSync({bool inquadra = false}) {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) =>
                SchermataSincronizza(gestore: _sync, inquadraSubito: inquadra)))
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
            // Apre Sincronizza: il sync parte da solo (è il PC a chiamare),
            // quindi qui non c'è niente da far partire, ma si vede con chi
            // ci si è parlati e quando.
            // Nel browser niente sync (`sync_rete_web.dart`): un pulsante che
            // non trova mai nessuno insegna solo a non fidarsi dei pulsanti.
            if (!kIsWeb) IconButton(
              icon: const IconaVM(Icone.sync),
              tooltip: 'Sincronizza',
              onPressed: _apriSync,
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
