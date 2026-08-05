/// Le categorie: raggruppamenti scelti a mano.
///
/// **Niente viene assegnato in automatico.** Non si deducono dai tag: quelli
/// di un vault importato sono spesso parole ricavate dal titolo (`Poste
/// Italiane` → `italiane`), e raggrupparci sopra darebbe centinaia di sezioni
/// da una voce sola. Si crea la categoria, poi ci si mettono dentro le voci
/// una per una o a blocchi.
///
/// Una voce sta in **una categoria sola**: metterla altrove la sposta. Così le
/// sezioni non si sovrappongono e i conteggi tornano col totale.
library;

import 'package:flutter/material.dart';

import '../ricerca.dart';
import '../sessione.dart';
import '../tema.dart';
import '../vault.dart';
import 'dialoghi.dart';
import 'modulo_voce.dart';
import 'scheda_voce.dart';

class SezioneCategorie extends StatefulWidget {
  final Sessione sessione;
  const SezioneCategorie({super.key, required this.sessione});

  @override
  State<SezioneCategorie> createState() => _SezioneCategorieState();
}

class _SezioneCategorieState extends State<SezioneCategorie> {
  Future<void> _conErrore(Future<void> Function() azione) async {
    try {
      await azione();
    } on ModificaRifiutata catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.messaggio)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Non è stato possibile salvare la modifica.')),
      );
    }
  }

  Future<void> _crea() async {
    final nome = await _chiediNome(context, titolo: 'Nuova categoria');
    if (nome == null) return;
    await _conErrore(() => widget.sessione.creaCategoria(nome));
  }

  Future<void> _rinomina(String categoria) async {
    final nome = await _chiediNome(context,
        titolo: 'Rinomina categoria', iniziale: categoria);
    if (nome == null) return;
    await _conErrore(() => widget.sessione.rinominaCategoria(categoria, nome));
  }

  Future<void> _elimina(String categoria, int quante) async {
    final ok = await confermaDistruttiva(
      context,
      titolo: 'Eliminare la categoria "$categoria"?',
      dettaglio: quante == 0
          ? 'La categoria è vuota: non cambia nient\'altro.'
          : 'Le $quante voci che contiene NON vengono eliminate: restano nel '
              'vault, senza categoria.',
    );
    if (ok != true) return;
    await _conErrore(() => widget.sessione.eliminaCategoria(categoria));
  }

  /// Il "+" della categoria: apre il database e ci si spuntano le voci da
  /// metterci dentro. È il gesto che Luca ha chiesto il 04/08 — si parte dalla
  /// categoria, non dalla voce.
  Future<void> _aggiungiVoci(String categoria) async {
    final scelte = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute(
        builder: (_) => _SceltaVoci(
          sessione: widget.sessione,
          categoria: categoria,
        ),
      ),
    );
    if (scelte == null || scelte.isEmpty) return;
    await _conErrore(() async {
      final quante = await widget.sessione.assegnaCategoria(scelte, categoria);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(quante == 1
            ? '1 voce spostata in "$categoria"'
            : '$quante voci spostate in "$categoria"'),
      ));
    });
  }

  Future<void> _togliDallaCategoria(Credenziale c) async {
    await _conErrore(() => widget.sessione.assegnaCategoria([c.id], ''));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Vault>(
      valueListenable: widget.sessione,
      builder: (context, vault, _) {
        final senza = vault.credenziali.where((c) => c.categoria.isEmpty).toList();

        return Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _crea,
            backgroundColor: context.cAccento,
            foregroundColor: context.cSuAccento,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Nuova categoria'),
          ),
          body: vault.categorie.isEmpty && senza.isEmpty
              ? Center(
                  child: Text('Il vault è vuoto.',
                      style: TextStyle(color: context.cTenue)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
                  children: [
                    // A categorie vuote non si dice niente, come sul PC: il
                    // pulsante per crearne una e' li', e una spiegazione che
                    // compare solo finche' non hai fatto nulla e' la
                    // definizione di riga che leggi una volta e poi da'
                    // fastidio.
                    for (final cat in vault.categorie)
                      _Gruppo(
                        titolo: cat,
                        voci: vault.credenziali
                            .where((c) => c.categoria == cat)
                            .toList(),
                        sessione: widget.sessione,
                        onAggiungi: () => _aggiungiVoci(cat),
                        onRinomina: () => _rinomina(cat),
                        onElimina: (quante) => _elimina(cat, quante),
                        onTogli: _togliDallaCategoria,
                      ),
                    if (senza.isNotEmpty)
                      _Gruppo(
                        titolo: 'Senza categoria',
                        voci: senza,
                        sessione: widget.sessione,
                        // Non è una categoria vera: non si rinomina, non si
                        // elimina, e non ha un "+" perché è dove si sta già.
                      ),
                  ],
                ),
        );
      },
    );
  }

}

/// Una categoria e le sue voci.
class _Gruppo extends StatelessWidget {
  final String titolo;
  final List<Credenziale> voci;
  final Sessione sessione;
  final VoidCallback? onAggiungi;
  final VoidCallback? onRinomina;
  final void Function(int quante)? onElimina;
  final void Function(Credenziale)? onTogli;

  const _Gruppo({
    required this.titolo,
    required this.voci,
    required this.sessione,
    this.onAggiungi,
    this.onRinomina,
    this.onElimina,
    this.onTogli,
  });

  @override
  Widget build(BuildContext context) {
    final colore = context.cAccento;
    final vera = onRinomina != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(vera ? Icons.folder : Icons.folder_off_outlined,
              color: vera ? colore : context.cTenue),
          title: Text(titolo,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          subtitle: Text(
            voci.isEmpty ? 'vuota' : (voci.length == 1 ? '1 voce' : '${voci.length} voci'),
            style: TextStyle(fontSize: 11, color: context.cTenue),
          ),
          trailing: !vera
              ? null
              : PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: context.cTenue),
                  color: context.cPannello,
                  onSelected: (v) {
                    if (v == 'rinomina') onRinomina!();
                    if (v == 'elimina') onElimina!(voci.length);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rinomina', child: Text('Rinomina')),
                    PopupMenuItem(value: 'elimina', child: Text('Elimina categoria')),
                  ],
                ),
          children: [
            if (onAggiungi != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: onAggiungi,
                      icon: Icon(Icons.add, size: 18, color: context.cAccento),
                      label: Text('Aggiungi voci',
                          style: TextStyle(color: context.cAccento, fontSize: 13)),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ModuloVoce(
                            sessione: sessione, categoriaIniziale: titolo),
                      )),
                      icon: Icon(Icons.note_add_outlined,
                          size: 17, color: context.cTenue),
                      label: Text('Nuova voce qui',
                          style: TextStyle(color: context.cTenue, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            if (voci.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text('Ancora nessuna voce qui dentro.',
                    style: TextStyle(fontSize: 12, color: context.cTenue)),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  children: [
                    for (final c in voci)
                      Row(
                        children: [
                          Expanded(child: SchedaVoce(key: ValueKey(c.id), credenziale: c)),
                          if (onTogli != null)
                            IconButton(
                              iconSize: 18,
                              tooltip: 'Togli dalla categoria',
                              icon: Icon(Icons.remove_circle_outline,
                                  color: context.cTenue),
                              onPressed: () => onTogli!(c),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Scelta multipla di voci da mettere in una categoria.
class _SceltaVoci extends StatefulWidget {
  final Sessione sessione;
  final String categoria;
  const _SceltaVoci({required this.sessione, required this.categoria});

  @override
  State<_SceltaVoci> createState() => _SceltaVociState();
}

class _SceltaVociState extends State<_SceltaVoci> {
  final _ricerca = TextEditingController();
  final _scelte = <int>{};
  late final IndiceRicerca _indice;
  late List<Credenziale> _mostrate;

  @override
  void initState() {
    super.initState();
    _indice = IndiceRicerca(widget.sessione.vault.credenziali);
    _mostrate = widget.sessione.vault.credenziali;
    _ricerca.addListener(() {
      final q = _ricerca.text.trim();
      setState(() {
        _mostrate = q.isEmpty
            ? widget.sessione.vault.credenziali
            : _indice.cerca(q).map((r) => r.voce).toList();
      });
    });
  }

  @override
  void dispose() {
    _ricerca.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Aggiungi a "${widget.categoria}"'),
        actions: [
          TextButton(
            onPressed: _scelte.isEmpty
                ? null
                : () => Navigator.of(context).pop(_scelte.toList()),
            child: Text(
              _scelte.isEmpty ? 'Scegli' : 'Aggiungi (${_scelte.length})',
              style: TextStyle(
                  color: _scelte.isEmpty ? context.cTenue : context.cAccento,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: TextField(
              controller: _ricerca,
              decoration: InputDecoration(
                hintText: 'Cerca fra le voci…',
                prefixIcon: Icon(Icons.search, color: context.cTenue),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: _mostrate.length,
              itemBuilder: (_, i) {
                final c = _mostrate[i];
                final gia = c.categoria == widget.categoria;
                return CheckboxListTile(
                  value: gia || _scelte.contains(c.id),
                  // Una voce già dentro non si può "scegliere di nuovo": si
                  // mostra spuntata e ferma, così è chiaro che c'è già.
                  onChanged: gia
                      ? null
                      : (v) => setState(() {
                            if (v == true) {
                              _scelte.add(c.id);
                            } else {
                              _scelte.remove(c.id);
                            }
                          }),
                  activeColor: context.cAccento,
                  title: Text(c.title, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    gia
                        ? 'già in questa categoria'
                        : (c.categoria.isEmpty
                            ? 'senza categoria'
                            : 'ora in "${c.categoria}" — verrà spostata'),
                    style: TextStyle(fontSize: 11.5, color: context.cTenue),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Chiede un nome di categoria. Restituisce `null` se si annulla.
Future<String?> _chiediNome(BuildContext context,
    {required String titolo, String iniziale = ''}) {
  final c = TextEditingController(text: iniziale);
  return showDialog<String>(
    context: context,
    builder: (dc) => AlertDialog(
      backgroundColor: dc.cPannello,
      title: Text(titolo),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Nome', hintText: 'es. Banche'),
        onSubmitted: (v) => Navigator.pop(dc, v.trim().isEmpty ? null : v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dc),
          child: Text('Annulla', style: TextStyle(color: dc.cTenue)),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dc, c.text.trim().isEmpty ? null : c.text),
          style: FilledButton.styleFrom(
              backgroundColor: dc.cAccento, foregroundColor: dc.cSuAccento),
          child: const Text('Salva'),
        ),
      ],
    ),
  );
}
