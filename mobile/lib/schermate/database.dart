/// Il database: tutte le voci, con ricerca, voci fissate in cima e modifica.
///
/// Fino al 04/08/2026 era la home dell'app (`elenco.dart`) ed era di sola
/// lettura. Ora è la seconda sezione — la prima è la chat — e da qui le voci
/// si aggiungono, si modificano e si eliminano.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../impostazioni.dart';
import '../ricerca.dart';
import '../sessione.dart';
import '../tema.dart';
import '../vault.dart';
import 'dialoghi.dart';
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

  /// Le fissate salgono in cima, nell'ordine in cui sono state fissate — ma
  /// solo quando non si sta cercando: durante una ricerca l'ordine giusto è
  /// quello della pertinenza, e vedere in testa una voce che non c'entra
  /// sarebbe solo confusione.
  List<Credenziale> get _ordinate {
    if (_ricerca.text.trim().isNotEmpty) return _trovate;
    final fissate = impostazioni.value.pinnate;
    if (fissate.isEmpty) return _trovate;
    final inCima = <Credenziale>[];
    for (final id in fissate) {
      final v = _trovate.where((c) => c.id == id);
      // Un pin che punta a una voce cancellata altrove si ignora in silenzio.
      if (v.isNotEmpty) inCima.add(v.first);
    }
    return [...inCima, ..._trovate.where((c) => !fissate.contains(c.id))];
  }

  Future<void> _nuova() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ModuloVoce(sessione: widget.sessione),
    ));
  }

  Future<void> _modifica(Credenziale c) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ModuloVoce(sessione: widget.sessione, voce: c),
    ));
  }

  Future<void> _elimina(Credenziale c) async {
    final ok = await confermaDistruttiva(
      context,
      titolo: 'Eliminare "${c.title}"?',
      dettaglio: 'La voce viene tolta dal vault di questo telefono. '
          'Non esiste un cestino, e se il PC non ne ha una copia è persa.',
    );
    if (ok != true) return;
    try {
      await widget.sessione.eliminaVoce(c.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Non è stato possibile eliminare la voce.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: TextField(
              controller: _ricerca,
              decoration: InputDecoration(
                hintText: 'Cerca…',
                prefixIcon: IconaVM(Icone.cerca, color: context.cTenue),
                suffixIcon: _ricerca.text.isEmpty
                    ? null
                    : IconButton(
                        icon: IconaVM(Icone.chiudi, color: context.cTenue),
                        onPressed: () => _ricerca.clear(),
                      ),
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<Impostazioni>(
              valueListenable: impostazioni,
              builder: (context, _, _) {
                final voci = _ordinate;
                if (voci.isEmpty) {
                  return Center(
                    child: Text(
                      _ricerca.text.trim().isEmpty
                          ? 'Il vault è vuoto. Il + qui sotto aggiunge la prima voce.'
                          : 'Nessuna voce corrisponde.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.cTenue),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 90),
                  itemCount: voci.length,
                  itemBuilder: (_, i) => SchedaVoce(
                    key: ValueKey(voci[i].id),
                    credenziale: voci[i],
                    onModifica: () => _modifica(voci[i]),
                    onElimina: () => _elimina(voci[i]),
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
