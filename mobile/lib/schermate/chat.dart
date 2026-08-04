/// La chat: si chiede quello che serve, e la voce compare.
///
/// È la home dell'app, come sul PC. La differenza sta in cosa NON c'è: qui non
/// gira nessun modello. Sul telefono non esiste Ollama, e infilare un modello
/// da 3 miliardi di parametri nell'APK vorrebbe dire ~2 GB e minuti di attesa
/// per una frase.
///
/// Non è una perdita, è il contrario. Sul PC il recupero vero costa ~0,46 s su
/// 800 voci, ma la frase dell'assistente ne fa percepire quindici (TODO §4):
/// la ricerca è pronta subito ed è la cosmesi a tenerla in ostaggio. Qui la
/// risposta è **istantanea**, e il principio del progetto vale in purezza —
/// nessuno "parla", il match è trovato e mostrato.
///
/// Le frasi sono quindi fisse. Quello che decide *quale* frase è la stessa
/// regola del PC, portata in `interpreta()`: una voce sola, più voci
/// ugualmente pertinenti, oppure nessuna.
library;

import 'package:flutter/material.dart';

import '../ricerca.dart';
import '../sessione.dart';
import '../tema.dart';
import '../vault.dart';
import 'scheda_voce.dart';

class SezioneChat extends StatefulWidget {
  final Sessione sessione;
  const SezioneChat({super.key, required this.sessione});

  @override
  State<SezioneChat> createState() => _SezioneChatState();
}

/// Una battuta della conversazione.
class _Battuta {
  /// Scritta dall'utente (a destra) o dall'app (a sinistra).
  final bool mia;
  final String testo;

  /// Le voci da mostrare sotto la frase, se ce ne sono.
  final List<Credenziale> voci;

  /// Vero quando le voci sono una domanda ("quale intendi?") e non una
  /// risposta: si mostrano chiuse e toccabili.
  final bool daScegliere;

  const _Battuta(this.mia, this.testo,
      {this.voci = const [], this.daScegliere = false});
}

class _SezioneChatState extends State<SezioneChat> {
  final _domanda = TextEditingController();
  final _scorrimento = ScrollController();
  final _battute = <_Battuta>[];
  late IndiceRicerca _indice;

  @override
  void initState() {
    super.initState();
    _ricostruisciIndice();
    widget.sessione.addListener(_ricostruisciIndice);
    _battute.add(const _Battuta(false,
        'Chiedimi una credenziale: "la password di Amazon", "il conto in banca". '
        'Cerco fra le voci del vault — non invento niente.'));
  }

  @override
  void dispose() {
    widget.sessione.removeListener(_ricostruisciIndice);
    _domanda.dispose();
    _scorrimento.dispose();
    super.dispose();
  }

  void _ricostruisciIndice() {
    _indice = IndiceRicerca(widget.sessione.vault.credenziali);
  }

  void _inFondo() {
    // Dopo che la lista è stata ridisegnata, altrimenti si scorre verso una
    // fine che non esiste ancora.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scorrimento.hasClients) return;
      _scorrimento.animateTo(
        _scorrimento.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _chiedi() {
    final testo = _domanda.text.trim();
    if (testo.isEmpty) return;
    _domanda.clear();

    final risposta = interpreta(_indice.cerca(testo, quanti: 8));
    setState(() {
      _battute.add(_Battuta(true, testo));
      _battute.add(_rispondi(testo, risposta));
    });
    _inFondo();
  }

  _Battuta _rispondi(String domanda, RispostaRicerca r) {
    switch (r.esito) {
      case Esito.nessuna:
        return _Battuta(
          false,
          widget.sessione.vault.credenziali.isEmpty
              ? 'Il vault è vuoto: non c\'è ancora niente da cercare.'
              : 'Non ho trovato niente per «$domanda». Prova col nome del '
                  'servizio, o guarda nel Database.',
        );
      case Esito.una:
        final v = r.voci.first.voce;
        return _Battuta(false, 'Ecco "${v.title}".', voci: [v]);
      case Esito.ambigua:
        return _Battuta(
          false,
          'Ne ho trovate ${r.voci.length} che corrispondono allo stesso modo. Quale intendi?',
          voci: r.voci.map((x) => x.voce).toList(),
          daScegliere: true,
        );
    }
  }

  void _scegli(Credenziale c) {
    setState(() {
      _battute.add(_Battuta(true, c.title));
      _battute.add(_Battuta(false, 'Ecco "${c.title}".', voci: [c]));
    });
    _inFondo();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scorrimento,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            itemCount: _battute.length,
            itemBuilder: (_, i) => _Bolla(
              battuta: _battute[i],
              onScelta: _scegli,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _domanda,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _chiedi(),
                  decoration: InputDecoration(
                    hintText: 'Cosa ti serve?',
                    prefixIcon: Icon(Icons.forum_outlined, color: context.cTenue),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _chiedi,
                style: IconButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                ),
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bolla extends StatelessWidget {
  final _Battuta battuta;
  final void Function(Credenziale) onScelta;
  const _Bolla({required this.battuta, required this.onScelta});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          battuta.mia ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // Chi sta parlando, come sul PC: un pallino e il nome. Senza, le due
        // bolle si distinguono solo dalla parte in cui stanno, e la risposta
        // sembra comparire da sola invece che venire da qualcuno.
        if (!battuta.mia)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      color: context.cAccento, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text('mind',
                    style: TextStyle(
                        fontSize: 11.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w500,
                        color: context.cAccento)),
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: battuta.mia
                ? context.cAccento.withValues(alpha: 0.16)
                : context.cPannello,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: battuta.mia
                    ? context.cAccento.withValues(alpha: 0.4)
                    : context.cBordo),
          ),
          child: Text(battuta.testo,
              style: TextStyle(fontSize: 13.5, height: 1.45, color: context.cTesto)),
        ),
        if (battuta.voci.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: [
                for (final c in battuta.voci)
                  battuta.daScegliere
                      ? _Scelta(credenziale: c, onTocco: () => onScelta(c))
                      : SchedaVoce(
                          key: ValueKey('chat-${c.id}'),
                          credenziale: c,
                          aperta: true,
                        ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Una delle voci fra cui scegliere quando la richiesta è ambigua. Mostra
/// titolo e categoria, mai i valori: la scelta si fa su cosa **è** la voce,
/// e stampare le password di tutte le candidate sarebbe il contrario di quello
/// che serve.
class _Scelta extends StatelessWidget {
  final Credenziale credenziale;
  final VoidCallback onTocco;
  const _Scelta({required this.credenziale, required this.onTocco});

  @override
  Widget build(BuildContext context) {
    final descrizione = <String>[
      if (credenziale.categoria.isNotEmpty) credenziale.categoria,
      ...credenziale.tags,
      ...credenziale.fields.map((f) => f.label).take(2),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTocco,
        leading: Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(color: context.cAccento, shape: BoxShape.circle),
        ),
        title: Text(credenziale.title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: descrizione.isEmpty
            ? null
            : Text(descrizione.take(4).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: context.cTenue)),
        trailing: Icon(Icons.chevron_right, color: context.cTenue),
      ),
    );
  }
}
