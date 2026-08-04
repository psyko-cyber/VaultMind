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
import '../tema.dart';
import '../vault.dart';
import 'categorie.dart';
import 'chat.dart';
import 'database.dart';
import 'impostazioni.dart';
import 'sblocco.dart';

class SchermataCasa extends StatefulWidget {
  final Sessione sessione;
  const SchermataCasa({super.key, required this.sessione});

  @override
  State<SchermataCasa> createState() => _SchermataCasaState();
}

class _SchermataCasaState extends State<SchermataCasa> {
  int _sezione = 0;
  Timer? _inattivita;

  @override
  void initState() {
    super.initState();
    _riarmaBlocco();
  }

  @override
  void dispose() {
    _inattivita?.cancel();
    super.dispose();
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
