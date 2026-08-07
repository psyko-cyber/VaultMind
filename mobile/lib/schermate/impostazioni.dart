/// Impostazioni dell'app.
///
/// Ci sono solo le cose che sul telefono hanno senso. Cambio master password e
/// import CSV restano sul PC: il primo perché rifà tutto il vault, il secondo
/// perché un file CSV su un telefono non ce l'ha nessuno.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../archivio.dart';
import '../impostazioni.dart';
import '../ponte_file.dart';
import '../sessione.dart';
import '../sync_gestore.dart';
import '../tema.dart';
import 'dialoghi.dart';
import 'foglio_generatore.dart';
import 'modulo_voce.dart';
import 'scheda_voce.dart' show svuotaDopo;
import 'sincronizza.dart';
import '../icone.dart';
import '../interruttore.dart';

class SchermataImpostazioni extends StatefulWidget {
  final Sessione sessione;
  final GestoreSync gestoreSync;
  final int quanteVoci;
  const SchermataImpostazioni(
      {super.key,
      required this.sessione,
      required this.gestoreSync,
      required this.quanteVoci});

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
            // copia() e non un Impostazioni nuovo: costruirlo da zero
            // dimenticherebbe le voci fissate, che sono l'unico dato vero
            // conservato qui dentro.
            onChanged: (v) => salvaImpostazioni(imp.copia(tema: v ?? imp.tema)),
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
            leading: IconaVM(Icone.orologio, color: context.cTenue),
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
              onChanged: (v) =>
                  salvaImpostazioni(imp.copia(autoBlocco: v ?? imp.autoBlocco)),
            ),
          ),
          if (_improntaDisponibile)
            RigaInterruttore(
              acceso: _improntaAttiva,
              icona: const IconaVM(Icone.impronta, size: 22),
              titolo: 'Sblocco con impronta',
              descrizione: _improntaAttiva
                  ? 'Attivo. La master password non è salvata: è la chiave del vault a essere protetta dal telefono.'
                  : 'Si attiva al prossimo sblocco con la master password.',
              // Si può solo spegnere da qui: per accenderlo serve la chiave,
              // che esiste solo nel momento in cui si sblocca con la password.
              onChanged: _improntaAttiva
                  ? (_) async {
                      await improntaDisattiva();
                      _stato();
                    }
                  : null,
            ),

          _Sezione('Strumenti'),
          // Qui e non nella barra in alto: la barra ha già tre icone, e
          // generare una password è una cosa che si fa qualche volta a
          // settimana, non ogni volta che si apre l'app. Dentro il modulo di
          // una voce c'è comunque il suo pulsante, che è dove serve più
          // spesso.
          ListTile(
            leading: IconaVM(Icone.dado, color: context.cTenue),
            title: const Text('Genera una password'),
            subtitle: Text(
                'Da copiare in un modulo di registrazione, o da salvare subito in una voce.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: _generatore,
          ),

          _Sezione('Dispositivi'),
          // Qui e non nella barra: abbinare si fa una volta sola, mentre
          // sincronizzare si fa spesso — e infatti il tasto in alto ora
          // sincronizza invece di aprire questa schermata.
          ListTile(
            leading: IconaVM(Icone.dispositivi, color: context.cTenue),
            title: const Text('Sincronizza con altri dispositivi'),
            subtitle: Text(
                widget.gestoreSync.fidati.isEmpty
                    ? 'Nessuno abbinato. Serve il codice mostrato sull\'altro dispositivo.'
                    : '${widget.gestoreSync.fidati.length} abbinati. '
                        'Si allineano da soli quando cambia qualcosa.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) =>
                        SchermataSincronizza(gestore: widget.gestoreSync)))
                .then((_) => setState(() {})),
          ),

          _Sezione('Vault'),
          ListTile(
            leading: IconaVM(Icone.info, color: context.cTenue),
            title: Text('${widget.quanteVoci} voci su questo telefono'),
            subtitle: Text(
                'Una copia completa e cifrata, che funziona anche senza rete.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
          ),
          if (imp.pinnate.isNotEmpty)
            ListTile(
              leading: IconaVM(Icone.fissa, color: context.cTenue),
              title: Text('${imp.pinnate.length} voci fissate in cima'),
              subtitle: Text(
                  'Valgono solo su questo telefono: non stanno nel vault e non viaggiano col backup.',
                  style: TextStyle(fontSize: 12, color: context.cTenue)),
              trailing: TextButton(
                onPressed: () => salvaImpostazioni(imp.copia(pinnate: [])),
                child: Text('Libera tutte',
                    style: TextStyle(color: context.cAccento, fontSize: 12.5)),
              ),
            ),
          ListTile(
            leading: IconaVM(Icone.backup, color: context.cTenue),
            title: const Text('Salva un backup'),
            subtitle: Text(
                'Il vault cifrato di questo telefono, da mandare dove vuoi: chi lo intercetta vede rumore.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: _backup,
          ),
          ListTile(
            // Non 'backup': quella e' l'icona del salvataggio, e le due righe
            // stanno una sotto l'altra. Con la stessa icona si legge il titolo
            // per capire quale delle due e' — cioe' l'icona non serve a niente.
            leading: IconaVM(Icone.documentoSu, color: context.cTenue),
            title: const Text('Importa un altro backup'),
            subtitle: Text('Sostituisce il vault attuale, conservandone una copia.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: _reimporta,
          ),
          ListTile(
            leading: IconaVM(Icone.cestino, color: context.cErrore),
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

  /// Il generatore aperto da solo, senza una voce da compilare.
  ///
  /// Le due uscite non sono equivalenti e non si fa finta che lo siano: copiare
  /// serve a incollare *adesso* in un modulo di registrazione aperto nel
  /// browser, ma una password copiata e mai salvata è una password persa. Per
  /// questo la seconda strada porta dritta al modulo della voce, con la
  /// password già dentro.
  Future<void> _generatore() async {
    final scelta = await mostraGeneratore(
      context,
      etichettaAzione: 'Copia negli appunti',
      mostraCreaVoce: true,
    );
    if (scelta == null || !mounted) return;

    if (scelta.creaVoce) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ModuloVoce(
          sessione: widget.sessione,
          passwordIniziale: scelta.password,
        ),
      ));
      return;
    }

    await Clipboard.setData(ClipboardData(text: scelta.password));
    svuotaDopo(scelta.password);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Password copiata — gli appunti si svuotano fra 45 secondi'),
      duration: Duration(seconds: 3),
    ));
  }

  /// Il backup parte dal vault **in memoria**, non dal file: se l'utente ha
  /// appena modificato qualcosa il file è già aggiornato, ma passare dalla
  /// sessione toglie di mezzo ogni dubbio su cosa finisce dentro.
  Future<void> _backup() async {
    try {
      final quando = DateTime.now();
      String due(int n) => n.toString().padLeft(2, '0');
      final nome = 'vaultmind-${quando.year}${due(quando.month)}${due(quando.day)}'
          '-${due(quando.hour)}${due(quando.minute)}.json';
      final ok = await salvaBackup(await widget.sessione.testoCifrato(), nome);
      if (!mounted || ok) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup non riuscito.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup non riuscito.')),
      );
    }
  }

  Future<void> _reimporta() async {
    // Da quando il telefono scrive, un backup che arriva da fuori può
    // cancellare lavoro fatto qui: si chiede prima. Vedi dialoghi.dart.
    if (await modificatoInLocale()) {
      if (!mounted) return;
      final procedi = await confermaSovrascrittura(context);
      if (procedi != true) return;
    }
    if (!mounted) return;
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
            fontFamily: 'Space Grotesk',
            fontSize: 11,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
            color: context.cAccento,
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
