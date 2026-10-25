/// Il database: tutte le voci, con ricerca, voci fissate in cima e modifica.
///
/// Fino al 04/08/2026 era la home dell'app (`elenco.dart`) ed era di sola
/// lettura. Ora è la seconda sezione — la prima è la chat — e da qui le voci
/// si aggiungono, si modificano e si eliminano.
///
/// Dalla 7.1 l'elenco è raggruppato per categoria, con un filtro per
/// categoria sopra, e una voce non si apre più sul posto: il tocco porta alla
/// sua schermata (`voce.dart`), come il dettaglio accanto all'elenco sul PC.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../impostazioni.dart';
import '../ricerca.dart';
import '../sessione.dart';
import '../tema.dart';
import '../vault.dart';
import 'modulo_voce.dart';
import 'scheda_voce.dart';
import '../icone.dart';

class SezioneDatabase extends StatefulWidget {
  final Sessione sessione;

  /// Costruito e tenuto aggiornato dalla casa. Quando le voci cambiano arriva
  /// un indice diverso, ed è quello il segnale per rifare la ricerca.
  final IndiceRicerca indice;

  const SezioneDatabase(
      {super.key, required this.sessione, required this.indice});

  @override
  State<SezioneDatabase> createState() => _SezioneDatabaseState();
}

class _SezioneDatabaseState extends State<SezioneDatabase> {
  final _ricerca = TextEditingController();
  List<Credenziale> _trovate = const [];
  Timer? _attesa;

  @override
  void initState() {
    super.initState();
    _aggiornaTrovate();
    _ricerca.addListener(_programmaRicerca);
  }

  /// Aggiungere o modificare una voce cambia anche l'indice: senza questo,
  /// una voce appena creata non si troverebbe cercandola.
  @override
  void didUpdateWidget(SezioneDatabase vecchio) {
    super.didUpdateWidget(vecchio);
    // Siamo già dentro un ridisegno: aggiornare il campo basta, un setState
    // qui ne chiederebbe un secondo per niente.
    if (!identical(widget.indice, vecchio.indice)) _aggiornaTrovate();
  }

  @override
  void dispose() {
    _attesa?.cancel();
    _ricerca.dispose();
    super.dispose();
  }

  /// Con 800 voci una ricerca costa qualche decina di millisecondi: farla a
  /// ogni singolo tasto premuto renderebbe la digitazione a scatti. Si aspetta
  /// che l'utente smetta di scrivere per un attimo.
  void _programmaRicerca() {
    _attesa?.cancel();
    _attesa = Timer(const Duration(milliseconds: 120), _cerca);
  }

  void _aggiornaTrovate() {
    final q = _ricerca.text.trim();
    _trovate = q.isEmpty
        ? widget.sessione.vault.credenziali
        : widget.indice.cerca(q).map((r) => r.voce).toList();
  }

  void _cerca() {
    if (!mounted) return;
    setState(_aggiornaTrovate);
  }

  /// Il filtro di categoria: `null` = tutte.
  String? _filtro;

  /// Cosa si disegna, in una lista sola: intestazioni di gruppo ([_Testata])
  /// e voci. Un solo `ListView.builder`, perché 800 righe non si costruiscono
  /// tutte insieme.
  ///
  /// Cercando, l'ordine giusto è quello della pertinenza, e i gruppi lo
  /// romperebbero: niente intestazioni. Senza ricerca, prima le fissate
  /// (nell'ordine in cui sono state fissate), poi una categoria alla volta
  /// nell'ordine scelto dall'utente, e dentro in ordine di nome.
  List<Object> _elementi(Vault vault) {
    bool passa(Credenziale c) => _filtro == null || c.categoria == _filtro;
    if (_ricerca.text.trim().isNotEmpty) return _trovate.where(passa).toList();

    final out = <Object>[];
    final fissate = _filtro == null ? impostazioni.value.pinnate : const <int>[];
    final inCima = <Credenziale>[];
    for (final id in fissate) {
      // Un pin che punta a una voce cancellata altrove si ignora in silenzio.
      for (final c in vault.credenziali) {
        if (c.id == id) {
          inCima.add(c);
          break;
        }
      }
    }
    if (inCima.isNotEmpty) {
      out
        ..add(_Testata('Fissate', inCima.length))
        ..addAll(inCima);
    }

    final gruppi = <String, List<Credenziale>>{};
    for (final c in vault.credenziali) {
      if (!passa(c) || (_filtro == null && fissate.contains(c.id))) continue;
      final g = vault.categorie.contains(c.categoria) ? c.categoria : '';
      (gruppi[g] ??= []).add(c);
    }
    for (final g in [...vault.categorie, '']) {
      final voci = gruppi[g];
      if (voci == null) continue;
      voci.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      // Senza nessuna categoria nel vault, un'intestazione «Senza
      // categoria» sopra tutto direbbe solo una cosa ovvia.
      if (g.isNotEmpty || gruppi.length > 1 || inCima.isNotEmpty) {
        out.add(_Testata(g.isEmpty ? 'Senza categoria' : g, voci.length));
      }
      out.addAll(voci);
    }
    return out;
  }

  Future<void> _nuova() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ModuloVoce(sessione: widget.sessione),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final vault = widget.sessione.vault;
    // Solo le categorie che hanno almeno una voce: un filtro che dà un
    // elenco vuoto è un tocco sprecato.
    final usate = {for (final c in vault.credenziali) c.categoria};
    final filtri = vault.categorie.where(usate.contains).toList();
    if (_filtro != null && !filtri.contains(_filtro)) _filtro = null;

    return Scaffold(
      // Trasparente: lo sfondo è quello dello Scaffold della casa.
      backgroundColor: Colors.transparent,
      floatingActionButton: sottoNeon(
        context,
        FloatingActionButton(
          onPressed: _nuova,
          backgroundColor: Colors.transparent,
          foregroundColor: context.cSuAccento,
          tooltip: 'Nuova voce',
          child: const IconaVM(Icone.piu),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: TextField(
              controller: _ricerca,
              decoration: InputDecoration(
                hintText: 'Cerca una voce',
                prefixIcon: IconaVM(Icone.cerca, color: context.cTenue),
                suffixIcon: _ricerca.text.isEmpty
                    ? null
                    : IconButton(
                        icon: IconaVM(Icone.chiudi, color: context.cTenue),
                        tooltip: 'Cancella la ricerca',
                        onPressed: () => _ricerca.clear(),
                      ),
              ),
            ),
          ),
          if (filtri.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                children: [
                  _Filtro(
                    testo: 'Tutte · ${vault.credenziali.length}',
                    scelto: _filtro == null,
                    onTocco: () => setState(() => _filtro = null),
                  ),
                  for (final f in filtri)
                    _Filtro(
                      testo: f,
                      scelto: _filtro == f,
                      onTocco: () => setState(() => _filtro = f),
                    ),
                ],
              ),
            )
          else
            const SizedBox(height: 10),
          Expanded(
            child: ValueListenableBuilder<Impostazioni>(
              valueListenable: impostazioni,
              builder: (context, _, _) {
                final elementi = _elementi(vault);
                if (elementi.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        vault.credenziali.isEmpty
                            ? 'Il vault è vuoto. Il + qui sotto aggiunge la prima voce.'
                            : 'Nessuna voce corrisponde.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.cTenue),
                      ),
                    ),
                  );
                }
                // Un pannello solo sotto tutto l'elenco, non una scheda per
                // voce: le righe si leggono sopra un colore fermo invece che
                // sopra il cielo, e 800 bordi in meno da disegnare.
                return Container(
                  margin: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                  decoration: BoxDecoration(
                    color: context.cPannello.withValues(alpha: .86),
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(22)),
                    border: Border.all(color: context.cBordo),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 90),
                    itemCount: elementi.length,
                    itemBuilder: (_, i) {
                      final e = elementi[i];
                      if (e is _Testata) return _IntestazioneGruppo(e);
                      final c = e as Credenziale;
                      return RigaVoce(
                          key: ValueKey(c.id),
                          credenziale: c,
                          sessione: widget.sessione);
                    },
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

/// L'intestazione di un gruppo nell'elenco.
class _Testata {
  final String titolo;
  final int quante;
  const _Testata(this.titolo, this.quante);
}

class _IntestazioneGruppo extends StatelessWidget {
  final _Testata t;
  const _IntestazioneGruppo(this.t);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Flexible(
              child: Text(t.titolo,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.cTenue)),
            ),
            const SizedBox(width: 8),
            Text('${t.quante}',
                style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 12,
                    color: context.cTenue)),
          ],
        ),
      ),
    );
  }
}

/// Un filtro di categoria. Acceso ha il neon pieno, come sul PC.
class _Filtro extends StatelessWidget {
  final String testo;
  final bool scelto;
  final VoidCallback onTocco;
  const _Filtro({required this.testo, required this.scelto, required this.onTocco});

  @override
  Widget build(BuildContext context) {
    final k = context.cristallo;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        selected: scelto,
        button: true,
        child: Material(
          color: scelto ? k.neon2 : context.cPannello.withValues(alpha: .7),
          shape: StadiumBorder(
              side: BorderSide(color: scelto ? Colors.transparent : context.cBordo)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTocco,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Center(
                widthFactor: 1,
                child: Text(testo,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: scelto ? k.suNeon : context.cTesto)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
