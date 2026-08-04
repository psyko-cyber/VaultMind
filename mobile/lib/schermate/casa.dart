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

class SchermataCasa extends StatefulWidget {
  final Sessione sessione;
  const SchermataCasa({super.key, required this.sessione});

  @override
  State<SchermataCasa> createState() => _SchermataCasaState();
}

class _SchermataCasaState extends State<SchermataCasa> {
  int _sezione = 0;
  Timer? _inattivita;
  late final GestoreSync _sync;

  @override
  void initState() {
    super.initState();
    _riarmaBlocco();
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
    _sync.removeListener(_aggiorna);
    _sync.ferma();
    _sync.dispose();
    super.dispose();
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
  Future<void> _syncAutomatico() async {
    try {
      final trovati = await _sync.cerca();
      for (final d in trovati.where((x) => x.conosciuto)) {
        final esito = await _sync.sincronizzaCon(d);
        if (!mounted || esito.errore != null) continue;
        if (esito.conflitti > 0) {
          _avviso('${d.etichetta}: ${esito.riassunto}', importante: true);
        } else if (esito.qualcosaECambiato) {
          _avviso('${d.etichetta}: ${esito.riassunto}');
        }
      }
    } catch (_) {
      // Il sync automatico non deve mai disturbare: se non riesce, pazienza.
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
            title: const Text('VaultMind', style: TextStyle(letterSpacing: 1.5)),
            actions: [
              Center(
                child: Text('${vault.credenziali.length} voci',
                    style: TextStyle(fontSize: 12, color: context.cTenue)),
              ),
              IconButton(
                icon: Badge(
                  isLabelVisible: _sync.conflitti.isNotEmpty,
                  label: Text('${_sync.conflitti.length}'),
                  child: const Icon(Icons.sync),
                ),
                tooltip: 'Sincronizza',
                onPressed: _apriSync,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Impostazioni',
                onPressed: () {
                  Navigator.of(context)
                      .push(MaterialPageRoute(
                        builder: (_) => SchermataImpostazioni(
                            sessione: widget.sessione,
                            quanteVoci: vault.credenziali.length),
                      ))
                      .then((_) => _riarmaBlocco());
                },
              ),
              IconButton(
                icon: const Icon(Icons.lock_outline),
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
                  icon: Icon(Icons.forum_outlined),
                  selectedIcon: Icon(Icons.forum),
                  label: 'Chat'),
              NavigationDestination(
                  icon: Icon(Icons.list_alt_outlined),
                  selectedIcon: Icon(Icons.list_alt),
                  label: 'Database'),
              NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: 'Categorie'),
            ],
          ),
        ),
      ),
    );
  }
}
