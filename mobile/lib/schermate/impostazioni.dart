/// Impostazioni dell'app.
///
/// Ci sono solo le cose che sul telefono hanno senso. Cambio master password,
/// generatore, import CSV e l'assistente restano sul PC: scrivono nel vault
/// (che qui è in sola lettura) oppure richiedono Ollama, che su Android non
/// gira.
library;

import 'package:flutter/material.dart';

import '../archivio.dart';
import '../impostazioni.dart';
import '../ponte_file.dart';
import '../tema.dart';

class SchermataImpostazioni extends StatefulWidget {
  final int quanteVoci;
  const SchermataImpostazioni({super.key, required this.quanteVoci});

  @override
  State<SchermataImpostazioni> createState() => _SchermataImpostazioniState();
}

class _SchermataImpostazioniState extends State<SchermataImpostazioni> {
  bool _improntaDisponibile = false;
  bool _improntaAttiva = false;

  @override
  void initState() {
    super.initState();
    _stato();
  }

  Future<void> _stato() async {
    final d = await impresaDisponibile();
    final a = await improntaAttiva();
    if (mounted) {
      setState(() {
        _improntaDisponibile = d;
        _improntaAttiva = a;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final imp = impostazioni.value;
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Sezione('Aspetto'),
          RadioGroup<TemaId>(
            groupValue: imp.tema,
            onChanged: (v) => salvaImpostazioni(Impostazioni(
              tema: v ?? imp.tema,
              autoBlocco: imp.autoBlocco,
            )),
            child: Column(
              children: [
                for (final t in TemaId.values)
                  RadioListTile<TemaId>(
                    value: t,
                    title: Text(nomiTema[t]!),
                    secondary: _Pastiglia(tema: t),
                    activeColor: context.cAccento,
                  ),
              ],
            ),
          ),

          _Sezione('Sicurezza'),
          ListTile(
            leading: Icon(Icons.lock_clock, color: context.cTenue),
            title: const Text('Blocca dopo inattività'),
            subtitle: Text(
              imp.autoBlocco == 0
                  ? 'Mai: il vault resta aperto finché non chiudi l\'app'
                  : 'Dopo ${imp.autoBlocco} minuti senza toccare lo schermo',
              style: TextStyle(fontSize: 12, color: context.cTenue),
            ),
            trailing: DropdownButton<int>(
              value: imp.autoBlocco,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Mai')),
                DropdownMenuItem(value: 1, child: Text('1 min')),
                DropdownMenuItem(value: 5, child: Text('5 min')),
                DropdownMenuItem(value: 15, child: Text('15 min')),
                DropdownMenuItem(value: 30, child: Text('30 min')),
              ],
              onChanged: (v) => salvaImpostazioni(Impostazioni(
                tema: imp.tema,
                autoBlocco: v ?? imp.autoBlocco,
              )),
            ),
          ),
          if (_improntaDisponibile)
            SwitchListTile(
              value: _improntaAttiva,
              activeThumbColor: context.cAccento,
              secondary: Icon(Icons.fingerprint, color: context.cTenue),
              title: const Text('Sblocco con impronta'),
              subtitle: Text(
                _improntaAttiva
                    ? 'Attivo. La master password non è salvata: è la chiave del vault a essere protetta dal telefono.'
                    : 'Si attiva al prossimo sblocco con la master password.',
                style: TextStyle(fontSize: 12, color: context.cTenue),
              ),
              // Si può solo spegnere da qui: per accenderlo serve la chiave,
              // che esiste solo nel momento in cui si sblocca con la password.
              onChanged: _improntaAttiva
                  ? (_) async {
                      await improntaDisattiva();
                      _stato();
                    }
                  : null,
            ),

          _Sezione('Vault'),
          ListTile(
            leading: Icon(Icons.info_outline, color: context.cTenue),
            title: Text('${widget.quanteVoci} voci su questo telefono'),
            subtitle: Text('In sola lettura: le modifiche si fanno sul PC.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
          ),
          ListTile(
            leading: Icon(Icons.download_outlined, color: context.cTenue),
            title: const Text('Importa un altro backup'),
            subtitle: Text('Sostituisce il vault attuale, conservandone una copia.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: _reimporta,
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: context.cErrore),
            title: Text('Elimina il vault da questo telefono',
                style: TextStyle(color: context.cErrore)),
            subtitle: Text('Sul PC resta tutto: qui c\'è solo una copia.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: _elimina,
          ),

          const SizedBox(height: 24),
          Center(
            child: Text('VaultMind · vault locale, niente cloud',
                style: TextStyle(fontSize: 11, color: context.cTenue)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _reimporta() async {
    final contenuto = await scegliFile();
    if (contenuto == null) return;
    try {
      await importaVault(contenuto);
      if (!mounted) return;
      // Il vault è cambiato: la chiave dell'impronta non lo apre più.
      await improntaDisattiva();
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.of(context).pushReplacementNamed('/');
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _elimina() async {
    final sicuro = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Eliminare il vault?'),
        content: const Text(
          'Viene tolto solo da questo telefono. Sul PC resta tutto, e potrai '
          'reimportarlo quando vuoi con un nuovo backup.',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Annulla', style: TextStyle(color: context.cTenue)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Elimina', style: TextStyle(color: context.cErrore)),
          ),
        ],
      ),
    );
    if (sicuro != true) return;
    await eliminaVault();
    await improntaDisattiva();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }
}

class _Sezione extends StatelessWidget {
  final String titolo;
  const _Sezione(this.titolo);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          titolo.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
            color: context.cTenue,
          ),
        ),
      );
}

/// Anteprima del tema: si sceglie con l'occhio, non leggendo un nome.
class _Pastiglia extends StatelessWidget {
  final TemaId tema;
  const _Pastiglia({required this.tema});

  @override
  Widget build(BuildContext context) {
    final s = temaDati(tema).colorScheme;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: s.surface,
        shape: BoxShape.circle,
        border: Border.all(color: context.cBordo),
      ),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: s.primary, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
