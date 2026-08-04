/// Aggiunta e modifica di una credenziale, dal telefono.
///
/// Esiste dal 04/08/2026, insieme alla scrittura del vault. Prima le voci si
/// creavano solo sul PC, perché il telefono non poteva scrivere.
library;

import 'package:flutter/material.dart';

import '../sessione.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';

/// Le etichette proposte quando si aggiunge un campo: sono quelle che ricorrono
/// nel 90% delle voci, e sceglierle da un elenco evita che la stessa cosa si
/// chiami "utente" in una voce e "username" in un'altra — cosa che peggiora
/// anche la ricerca, che indicizza le etichette.
const _etichetteComuni = [
  'Utente', 'Email', 'Password', 'URL', 'OTP (2FA)', 'PIN', 'Note',
];

class ModuloVoce extends StatefulWidget {
  final Sessione sessione;

  /// Assente = nuova voce.
  final Credenziale? voce;

  /// Categoria proposta: serve al "+" dentro una categoria, che deve creare
  /// la voce già dentro quella.
  final String categoriaIniziale;

  const ModuloVoce({
    super.key,
    required this.sessione,
    this.voce,
    this.categoriaIniziale = '',
  });

  @override
  State<ModuloVoce> createState() => _ModuloVoceState();
}

class _ModuloVoceState extends State<ModuloVoce> {
  late final TextEditingController _titolo;
  late final TextEditingController _tags;
  late List<({TextEditingController label, TextEditingController value})> _campi;
  late bool _critica;
  late String _categoria;
  bool _occupato = false;
  String? _errore;

  bool get _nuova => widget.voce == null;

  @override
  void initState() {
    super.initState();
    final v = widget.voce;
    _titolo = TextEditingController(text: v?.title ?? '');
    _tags = TextEditingController(text: (v?.tags ?? const []).join(', '));
    _critica = v?.critical ?? false;
    _categoria = v?.categoria ?? widget.categoriaIniziale;
    _campi = [
      for (final c in v?.fields ?? const <Campo>[])
        (
          label: TextEditingController(text: c.label),
          value: TextEditingController(text: c.value)
        ),
    ];
    if (_campi.isEmpty) _aggiungiCampo('Utente');
    if (_campi.length == 1 && _nuova) _aggiungiCampo('Password');
  }

  @override
  void dispose() {
    _titolo.dispose();
    _tags.dispose();
    for (final c in _campi) {
      c.label.dispose();
      c.value.dispose();
    }
    super.dispose();
  }

  void _aggiungiCampo([String etichetta = '']) {
    _campi.add((
      label: TextEditingController(text: etichetta),
      value: TextEditingController()
    ));
    if (mounted) setState(() {});
  }

  void _togliCampo(int i) {
    final c = _campi.removeAt(i);
    c.label.dispose();
    c.value.dispose();
    setState(() {});
  }

  /// Password e secret 2FA nella stessa voce: da quel momento il secondo
  /// fattore non è più un fattore separato, perché chi apre il vault ha
  /// entrambi. Si avvisa e basta — bloccare il salvataggio significherebbe
  /// decidere al posto di chi usa l'app, e a volte è una scelta consapevole.
  bool get _duefattoriInsieme {
    final etichette = _campi.map((c) => c.label.text).toList();
    final haPassword = etichette.any((l) =>
        RegExp(r'pass', caseSensitive: false).hasMatch(l));
    final haOtp = etichette.any(etichettaSembraOtp);
    return haPassword && haOtp;
  }

  Future<void> _salva() async {
    setState(() {
      _occupato = true;
      _errore = null;
    });
    try {
      final campi = [
        for (final c in _campi) Campo(c.label.text, c.value.text),
      ];
      final tags = _tags.text.split(',');
      if (_nuova) {
        await widget.sessione.aggiungiVoce(
          titolo: _titolo.text,
          campi: campi,
          tags: tags,
          critica: _critica,
          categoria: _categoria,
        );
      } else {
        await widget.sessione.modificaVoce(
          widget.voce!.id,
          titolo: _titolo.text,
          campi: campi,
          tags: tags,
          critica: _critica,
          categoria: _categoria,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ModificaRifiutata catch (e) {
      setState(() => _errore = e.messaggio);
    } catch (e) {
      // Se il salvataggio non riesce, la voce NON risulta salvata: la sessione
      // aggiorna la memoria solo a disco a posto.
      setState(() => _errore = 'Non è stato possibile salvare la voce.');
    } finally {
      if (mounted) setState(() => _occupato = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categorie = widget.sessione.vault.categorie;

    return Scaffold(
      appBar: AppBar(
        title: Text(_nuova ? 'Nuova voce' : 'Modifica voce'),
        actions: [
          TextButton(
            onPressed: _occupato ? null : _salva,
            child: Text('Salva',
                style: TextStyle(
                    color: context.cAccento, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          TextField(
            controller: _titolo,
            autofocus: _nuova,
            decoration: const InputDecoration(labelText: 'Titolo'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 18),

          Text('CAMPI',
              style: TextStyle(
                  fontSize: 10, letterSpacing: 1.5, color: context.cTenue)),
          const SizedBox(height: 8),
          for (var i = 0; i < _campi.length; i++) _rigaCampo(i),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _aggiungiCampo(),
              icon: Icon(Icons.add, size: 18, color: context.cAccento),
              label: Text('Aggiungi campo',
                  style: TextStyle(color: context.cAccento, fontSize: 13)),
            ),
          ),

          const SizedBox(height: 10),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tag (separati da virgola)',
              helperText: 'Servono alla ricerca, non al raggruppamento',
            ),
          ),
          const SizedBox(height: 20),

          DropdownButtonFormField<String>(
            initialValue: categorie.contains(_categoria) ? _categoria : '',
            decoration: const InputDecoration(labelText: 'Categoria'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Nessuna categoria')),
              for (final c in categorie)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() => _categoria = v ?? ''),
          ),
          if (categorie.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Nessuna categoria ancora: si creano nella sezione Categorie.',
                style: TextStyle(fontSize: 11.5, color: context.cTenue),
              ),
            ),

          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _critica,
            onChanged: (v) => setState(() => _critica = v),
            activeThumbColor: context.cAccento,
            title: const Text('Voce critica', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              'Account da cui si rimette le mani su tutto il resto: banca, email principale.',
              style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.4),
            ),
          ),

          if (_critica && _duefattoriInsieme) _avviso2FA(context),

          if (_errore != null) ...[
            const SizedBox(height: 16),
            Text(_errore!,
                style: TextStyle(color: context.cErrore, fontSize: 13)),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _occupato ? null : _salva,
              style: FilledButton.styleFrom(
                backgroundColor: context.cAccento,
                foregroundColor: context.cSuAccento,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              child: _occupato
                  // Niente const: il colore viene dal tema, e in Flutter un
                  // const non può leggere il context.
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.cSuAccento))
                  : Text(_nuova ? 'Aggiungi al vault' : 'Salva le modifiche',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rigaCampo(int i) {
    final c = _campi[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: c.label.text),
              optionsBuilder: (t) => t.text.isEmpty
                  ? _etichetteComuni
                  : _etichetteComuni.where((e) =>
                      e.toLowerCase().contains(t.text.toLowerCase())),
              onSelected: (v) => setState(() => c.label.text = v),
              fieldViewBuilder: (context, controller, focus, _) {
                // Il controller lo gestisce Autocomplete: si tiene allineato
                // quello vero della riga a ogni battuta.
                controller.addListener(() => c.label.text = controller.text);
                return TextField(
                  controller: controller,
                  focusNode: focus,
                  decoration: const InputDecoration(
                      labelText: 'Etichetta', isDense: true),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: c.value,
              decoration: const InputDecoration(labelText: 'Valore', isDense: true),
              maxLines: null,
            ),
          ),
          IconButton(
            iconSize: 18,
            tooltip: 'Togli il campo',
            icon: Icon(Icons.close, color: context.cTenue),
            onPressed: () => _togliCampo(i),
          ),
        ],
      ),
    );
  }

  Widget _avviso2FA(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.cAccento.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.cAccento.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 18, color: context.cAccento),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Password e secret 2FA sono nella stessa voce: chi apre il vault '
                'ha entrambi, e il secondo fattore smette di essere separato. '
                'Su una voce critica vale la pena saperlo — non impedisce di salvare.',
                style: TextStyle(fontSize: 11.5, color: context.cTesto, height: 1.45),
              ),
            ),
          ],
        ),
      );
}
