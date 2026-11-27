/// Importa le password da un altro gestore, col CSV che quello esporta.
///
/// Esiste per chi usa VaultMind **solo dal telefono** (27/11/2026): senza PC
/// non c'è Ollama e quindi niente import intelligente, ed è giusto così. Ma
/// chi arriva da Google, Chrome, Bitwarden, LastPass, KeePass, Apple o Firefox
/// ha un file CSV, e leggerlo non chiede nessun LLM: `import_csv.dart`, lo
/// stesso parser del PC.
///
/// Come sul PC, **niente si salva finché l'utente non conferma**: prima vede
/// le voci trovate e toglie quelle che non vuole. Quelle che il vault ha già
/// (stesso titolo, stessa password) partono spente, perché chi riprova un
/// import dopo un errore non si ritrovi tutto doppio.
///
/// Il CSV ha le password **in chiaro**: a fine import si dice di cancellarlo.
library;

import 'package:flutter/material.dart';

import '../icone.dart';
import '../import_csv.dart';
import '../ponte_file.dart';
import '../sessione.dart';
import '../tema.dart';
import '../vault.dart';

class SchermataImportaCsv extends StatefulWidget {
  final Sessione sessione;
  const SchermataImportaCsv({super.key, required this.sessione});

  @override
  State<SchermataImportaCsv> createState() => _SchermataImportaCsvState();
}

class _SchermataImportaCsvState extends State<SchermataImportaCsv> {
  RisultatoImport? _letto;
  List<VoceImport> _voci = const [];
  Set<int> _scelte = {};
  Set<int> _gia = {}; // indici delle voci che il vault ha già
  String? _errore;
  bool _salvataggio = false;

  Future<void> _scegli() async {
    setState(() => _errore = null);
    final testo = await scegliFile();
    if (testo == null || !mounted) return; // annullato: non è un errore

    // Il backup di VaultMind è un JSON: letto come CSV darebbe voci assurde.
    // Chi lo sceglie qui ha sbagliato porta, e va detto quale è quella giusta.
    if (testo.trimLeft().startsWith('{')) {
      setState(() => _errore = 'Questo sembra un backup di VaultMind, non un CSV. '
          'Per quello c\'è «Importa un altro backup» nelle Impostazioni.');
      return;
    }

    final r = leggiCsv(testo);
    // Come l'endpoint del PC: una riga senza nessun campo non è una voce.
    final voci = r.voci.where((v) => v.campi.isNotEmpty).toList();
    if (voci.isEmpty) {
      setState(() => _errore = 'Nel file non ho trovato voci. Serve il CSV '
          'esportato dal gestore di password, con una riga di intestazioni '
          '(nome, utente, password...).');
      return;
    }

    final esistenti = {
      for (final c in widget.sessione.vault.credenziali)
        _chiave(c.title, _password(c.fields.map((f) => (f.label, f.value))))
    };
    final gia = <int>{
      for (var i = 0; i < voci.length; i++)
        if (esistenti.contains(_chiave(voci[i].titolo, voci[i].valore('Password'))))
          i
    };
    setState(() {
      _letto = r;
      _voci = voci;
      _gia = gia;
      _scelte = {for (var i = 0; i < voci.length; i++) if (!gia.contains(i)) i};
    });
  }

  static String? _password(Iterable<(String, String)> campi) {
    for (final (l, v) in campi) {
      if (l.toLowerCase() == 'password') return v;
    }
    return null;
  }

  static String _chiave(String titolo, String? password) =>
      '${titolo.trim().toLowerCase()}\u0000${password ?? ''}';

  Future<void> _importa() async {
    setState(() => _salvataggio = true);
    final scelte = [for (var i = 0; i < _voci.length; i++) if (_scelte.contains(i)) _voci[i]];
    try {
      final n = await widget.sessione.aggiungiVoci(scelte.map((v) => (
            titolo: v.titolo,
            campi: [for (final (l, x) in v.campi) Campo(l, x)],
            tags: v.tags,
          )));
      final con2fa = scelte.where((v) => v.con2fa).length;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: c.cPannello,
          title: Text(n == 1 ? 'Importata 1 voce' : 'Importate $n voci'),
          content: Text(
            '${con2fa > 0 ? 'Di queste, $con2fa hanno anche il codice 2FA: '
                'lo trovi già pronto nella voce.\n\n' : ''}'
            'Ora cancella il file CSV dal telefono (di solito sta in Download): '
            'contiene tutte le password in chiaro, e chiunque lo apra le legge.',
            style: const TextStyle(height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text('Ho capito', style: TextStyle(color: c.cAccento)),
            ),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _salvataggio = false;
        _errore = 'Salvataggio non riuscito: nessuna voce è stata aggiunta. ($e)';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importa da un altro gestore')),
      body: _letto == null ? _inizio(context) : _anteprima(context),
    );
  }

  Widget _inizio(BuildContext context) {
    final tenue = TextStyle(fontSize: 13, color: context.cTenue, height: 1.5);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        Text(
          'Dal gestore di password che usavi prima, esporta le password in un '
          'file CSV, poi sceglilo qui. Lo leggo sul telefono, senza Internet, '
          'e prima di salvare ti mostro cosa ho trovato.',
          style: TextStyle(fontSize: 14, color: context.cTesto, height: 1.5),
        ),
        const SizedBox(height: 16),
        Text('Dove si esporta', style: TextStyle(fontSize: 13, color: context.cAccento)),
        const SizedBox(height: 6),
        Text(
          '• Google (Android, Chrome): Impostazioni › Google › Gestore delle '
          'password › Impostazioni › Esporta password\n'
          '• Bitwarden: Impostazioni › Esporta cassaforte › formato .csv\n'
          '• LastPass, 1Password, KeePass, Firefox, Apple, Proton Pass, '
          'Dashlane, NordPass: la voce «Esporta» in CSV\n'
          '• Un tuo foglio Excel salvato come CSV, con colonne tipo '
          'Servizio, Utente, Password, Note',
          style: tenue,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _scegli,
            icon: const IconaVM(Icone.documento),
            label: const Text('Scegli il file CSV',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccento,
              foregroundColor: context.cSuAccento,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        if (_errore != null) _avviso(context, _errore!),
      ],
    );
  }

  Widget _anteprima(BuildContext context) {
    final tutte = _scelte.length == _voci.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_voci.length} voci trovate · ${_letto!.origine}'
                  '${_gia.isEmpty ? '' : '\n${_gia.length} sono già nel vault: le ho lasciate spente'}',
                  style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.4),
                ),
              ),
              TextButton(
                onPressed: _salvataggio
                    ? null
                    : () => setState(() => _scelte = tutte
                        ? {}
                        : {for (var i = 0; i < _voci.length; i++) i}),
                child: Text(tutte ? 'Nessuna' : 'Tutte',
                    style: TextStyle(color: context.cAccento)),
              ),
            ],
          ),
        ),
        if (_errore != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _avviso(context, _errore!),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _voci.length,
            itemBuilder: (_, i) {
              final v = _voci[i];
              final chi = v.valore('Utente') ?? v.valore('Email') ?? '';
              final dettagli = [
                if (chi.isNotEmpty) chi,
                if (v.con2fa) '2FA',
                if (_gia.contains(i)) 'già nel vault',
              ].join(' · ');
              return CheckboxListTile(
                value: _scelte.contains(i),
                onChanged: _salvataggio
                    ? null
                    : (s) => setState(() => s == true ? _scelte.add(i) : _scelte.remove(i)),
                activeColor: context.cAccento,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(v.titolo, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: dettagli.isEmpty
                    ? null
                    : Text(dettagli,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: context.cTenue)),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _scelte.isEmpty || _salvataggio ? null : _importa,
                style: FilledButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _salvataggio
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: context.cSuAccento))
                    : Text(
                        _scelte.length == 1
                            ? 'Importa 1 voce'
                            : 'Importa ${_scelte.length} voci',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _avviso(BuildContext context, String testo) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconaVM(Icone.avviso, size: 16, color: context.cErrore),
            const SizedBox(width: 8),
            Expanded(
              child: Text(testo,
                  style: TextStyle(fontSize: 13, color: context.cErrore, height: 1.45)),
            ),
          ],
        ),
      );
}
