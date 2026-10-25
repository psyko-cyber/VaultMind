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
import '../icone.dart';

class SezioneChat extends StatefulWidget {
  final Sessione sessione;

  /// Costruito e tenuto aggiornato dalla casa: qui si usa e basta. Farsene uno
  /// proprio voleva dire ricalcolare 800 voci in parallelo al database.
  final IndiceRicerca indice;

  const SezioneChat({super.key, required this.sessione, required this.indice});

  @override
  State<SezioneChat> createState() => _SezioneChatState();
}

/// Una battuta della conversazione.
class _Battuta {
  /// Scritta dall'utente (a destra) o dall'app (a sinistra).
  final bool mia;
  final String testo;

  /// Le voci da mostrare sotto la frase, se ce ne sono, col punteggio che le
  /// ha portate qui: è la «Somiglianza» della scheda.
  final List<Risultato> voci;

  /// Vero quando le voci sono una domanda ("quale intendi?") e non una
  /// risposta: si mostrano chiuse e toccabili.
  final bool daScegliere;

  const _Battuta(this.mia, this.testo,
      {this.voci = const [], this.daScegliere = false});
}

/// Le stesse quattro richieste del PC: provarne una insegna come si chiede
/// meglio di qualunque spiegazione.
const _suggerimenti = [
  'La password del wifi di casa',
  'Il codice della banca',
  "L'email di lavoro",
  'Il PIN della SIM',
];

class _SezioneChatState extends State<SezioneChat> {
  final _domanda = TextEditingController();
  final _scorrimento = ScrollController();

  /// Vuota all'inizio: al suo posto c'è il saluto, che sparisce alla prima
  /// domanda come sul PC.
  final _battute = <_Battuta>[];

  @override
  void dispose() {
    _domanda.dispose();
    _scorrimento.dispose();
    super.dispose();
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

    final risposta = interpreta(widget.indice.cerca(testo, quanti: 8));
    setState(() {
      _battute.add(_Battuta(true, testo));
      _battute.add(_rispondi(risposta));
    });
    _inFondo();
  }

  _Battuta _rispondi(RispostaRicerca r) {
    switch (r.esito) {
      case Esito.nessuna:
        return _Battuta(
          false,
          widget.sessione.vault.credenziali.isEmpty
              ? "Il vault è vuoto: non c'è ancora niente da cercare."
              : 'Non trovo niente che somigli abbastanza. Prova con il nome '
                  'del servizio, o con una parola che hai messo nei tag.',
        );
      case Esito.una:
        final v = r.voci.first;
        return _Battuta(false, 'Ecco "${v.voce.title}".', voci: [v]);
      case Esito.ambigua:
        return _Battuta(
          false,
          'Ho trovato ${r.voci.length} voci simili. Quale intendevi?',
          voci: r.voci,
          daScegliere: true,
        );
    }
  }

  void _scegli(Risultato r) {
    setState(() {
      _battute.add(_Battuta(true, r.voce.title));
      _battute.add(_Battuta(false, 'Ecco "${r.voce.title}".', voci: [r]));
    });
    _inFondo();
  }

  void _prova(String richiesta) {
    _domanda.text = richiesta;
    _chiedi();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _battute.isEmpty
              ? _Benvenuto(onProva: _prova)
              : ListView.builder(
                  controller: _scorrimento,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  itemCount: _battute.length,
                  itemBuilder: (_, i) => _Bolla(
                    battuta: _battute[i],
                    onScelta: _scegli,
                    onApri: (c) => apriVoce(context, widget.sessione, c.id),
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
                  // Niente icona dentro il campo: la scheda «Chat» sta due
                  // centimetri piu' sotto con la stessa identica bolla, e due
                  // volte lo stesso simbolo nella stessa schermata non
                  // aggiunge niente -- toglie soltanto spazio alla frase.
                  decoration: const InputDecoration(
                    hintText: 'Cosa ti serve?',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _chiedi,
                tooltip: 'Invia',
                // La sfumatura dei pulsanti pieni (`sfondoNeon` in tema.dart):
                // il tema dei pulsanti icona non la prende da solo.
                style: IconButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                ).copyWith(
                  backgroundBuilder: sfondoNeon(context.cristallo.sfumatura,
                      forma: const StadiumBorder()),
                ),
                // L'aereo di carta, lo stesso del PC. Prima era una freccia in
                // su, che sul telefono vuol dire «vai in cima», non «manda».
                icon: IconaVM(Icone.invia, size: 20, color: context.cSuAccento),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Il saluto al posto della conversazione vuota: dice cosa si può fare, con
/// quattro richieste vere da provare. Cambia con l'ora, niente di più.
class _Benvenuto extends StatelessWidget {
  final void Function(String) onProva;
  const _Benvenuto({required this.onProva});

  @override
  Widget build(BuildContext context) {
    final ora = DateTime.now().hour;
    final quando = ora < 6
        ? 'stanotte'
        : ora < 13
            ? 'stamattina'
            : ora < 18
                ? 'oggi pomeriggio'
                : 'stasera';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Cosa ti serve $quando?',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'Space Grotesk',
                    fontSize: 27,
                    fontWeight: FontWeight.w600,
                    height: 1.15)),
            const SizedBox(height: 10),
            Text(
              'Chiedilo come lo chiederesti a una persona. La risposta la '
              'trova il vault, nessuno la inventa.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.45, color: context.cTenue),
            ),
            const SizedBox(height: 22),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in _suggerimenti)
                  Material(
                    color: context.cPannello.withValues(alpha: .8),
                    shape: StadiumBorder(
                        side: BorderSide(color: context.cristallo.bordoForte)),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => onProva(t),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 15, vertical: 10),
                        child: Text(t,
                            style: TextStyle(fontSize: 13.5, color: context.cTesto)),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bolla extends StatelessWidget {
  final _Battuta battuta;
  final void Function(Risultato) onScelta;
  final void Function(Credenziale) onApri;
  const _Bolla(
      {required this.battuta, required this.onScelta, required this.onApri});

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
            // Piena anche la bolla mia: una tinta trasparente lascerebbe
            // passare la costellazione sotto le parole.
            color: battuta.mia
                ? Color.alphaBlend(
                    context.cAccento.withValues(alpha: 0.16), context.cPannello)
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
                for (final r in battuta.voci)
                  battuta.daScegliere
                      ? _Scelta(risultato: r, onTocco: () => onScelta(r))
                      : SchedaTrovata(
                          key: ValueKey('chat-${r.voce.id}'),
                          credenziale: r.voce,
                          somiglianza: r.punteggio,
                          onApri: () => onApri(r.voce),
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
  final Risultato risultato;
  final VoidCallback onTocco;
  const _Scelta({required this.risultato, required this.onTocco});

  @override
  Widget build(BuildContext context) {
    final c = risultato.voce;
    final descrizione = <String>[
      if (c.categoria.isNotEmpty) c.categoria,
      ...c.tags,
      ...c.fields.map((f) => f.label).take(2),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.cPannello,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cBordo),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTocco,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Monogramma.voce(c, lato: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      if (descrizione.isNotEmpty)
                        Text(descrizione.take(4).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: context.cTenue)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  label: 'Somiglianza ${formatoSomiglianza(risultato.punteggio)}',
                  excludeSemantics: true,
                  child: Text(formatoSomiglianza(risultato.punteggio),
                      style: TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.cristallo.neon2)),
                ),
                IconaVM(Icone.chevronDestra, color: context.cTenue),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
