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

import 'package:flutter/material.dart';

import '../impostazioni.dart';
import '../sessione.dart';
import '../sync_gestore.dart';
import '../tema.dart';
import '../vault.dart';
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
  late final GestoreSync _sync;

  /// Un giro alla volta, e non due di fila: senza, tornare in primo piano due
  /// volte in dieci secondi vorrebbe dire scambiare il vault due volte.
  bool _syncInCorso = false;
  DateTime _ultimoGiro = DateTime.fromMillisecondsSinceEpoch(0);

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
    if (DateTime.now().difference(_ultimoGiro) < const Duration(seconds: 20)) {
      return;   // rientri a raffica: uno vale per tutti
    }
    _syncAutomatico();
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
      child: ValueListenableBuilder<Vault>(
        valueListenable: widget.sessione,
        builder: (context, vault, _) => Scaffold(
          appBar: AppBar(
            title: const Text('VaultMind',
                style: TextStyle(
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2)),
            actions: [
              Center(
                child: Text('${vault.credenziali.length} voci',
                    style: TextStyle(fontSize: 12, color: context.cTenue)),
              ),
              // Toccarlo SINCRONIZZA, non apre una schermata: è quello che
              // vuol dire un'icona così in una barra, ed è la cosa che si fa
              // spesso. L'abbinamento e i dispositivi fidati stanno nelle
              // impostazioni, dov'è giusto che stia una cosa da configurare
              // una volta sola.
              IconButton(
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
              SezioneChat(sessione: widget.sessione),
              SezioneDatabase(sessione: widget.sessione),
              SezioneCategorie(sessione: widget.sessione),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _sezione,
            onDestinationSelected: (i) => setState(() => _sezione = i),
            destinations: const [
              NavigationDestination(
                  icon: IconaVM(Icone.chat),
                  selectedIcon: IconaVM(Icone.chat),
                  label: 'Chat'),
              NavigationDestination(
                  icon: IconaVM(Icone.elenco),
                  selectedIcon: IconaVM(Icone.elenco),
                  label: 'Database'),
              NavigationDestination(
                  icon: IconaVM(Icone.cartella),
                  selectedIcon: IconaVM(Icone.cartella),
                  label: 'Categorie'),
            ],
          ),
        ),
      ),
    );
  }
}
