/// Impostazioni dell'app.
///
/// Ci sono solo le cose che sul telefono hanno senso. Cambio master password e
/// import CSV restano sul PC: il primo perché rifà tutto il vault, il secondo
/// perché un file CSV su un telefono non ce l'ha nessuno.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../aggiornamenti.dart';
import '../archivio.dart';
import '../impostazioni.dart';
import '../ponte_file.dart';
import '../sessione.dart';
import '../sfondo.dart';
import '../sync_gestore.dart';
import '../tema.dart';
import '../versione.dart';
import 'aggiornamento.dart';
import 'dialoghi.dart';
import 'foglio_generatore.dart';
import 'modulo_voce.dart';
import 'scheda_voce.dart'
    show avvisoAppunti, copiaNegliAppunti, copiaRifiutata, svuotaDopo;
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
  bool _controlloInCorso = false;

  /// La versione nuova già trovata, se c'è. Non si chiede a GitHub aprendo
  /// questa schermata: lo ha già fatto la casa, e il risultato è lì.
  Novita? get _novita => avvisoAggiornamento.value;

  @override
  void initState() {
    super.initState();
    _stato();
  }

  /// Il controllo chiesto a mano parla sempre, anche per dire che non c'era
  /// niente: chi tocca un pulsante e non vede succedere nulla non sa se ha
  /// funzionato. [silenzioso] serve a chi lo fa partire da un interruttore.
  Future<void> _controllaOra({bool silenzioso = false}) async {
    setState(() => _controlloInCorso = true);
    final esito = await controlla(forza: true);
    if (!mounted) return;
    setState(() => _controlloInCorso = false);
    if (esito.novita != null) {
      await offriAggiornamento(context, esito.novita!);
      if (mounted) setState(() {});
      return;
    }
    if (silenzioso || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(esito.risposto
          ? 'Hai già l\'ultima versione.'
          : 'Nessuna risposta da GitHub: riprova quando hai connessione.'),
    ));
  }

  /// Il tema ridisegna questa schermata da solo (cambia il `Theme`), lo
  /// sfondo no: senza il setState il segmento toccato resterebbe spento.
  void _salvaSfondo(Impostazioni nuove) {
    salvaImpostazioni(nuove);
    setState(() {});
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
            onChanged: (v) => salvaImpostazioni(
                imp.copia(tema: v ?? imp.tema, temaScelto: true)),
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
          // Uno sfondo per ognuna delle tre sezioni, come sul PC: chi trova
          // la costellazione bella nello sblocco può volerla ferma mentre
          // legge l'elenco.
          _SceltaSfondo(
            titolo: 'Sfondo dello sblocco',
            nota: 'Lo vedi quando il vault è chiuso.',
            valore: imp.sfondoSblocco,
            onScelto: (s) => _salvaSfondo(imp.copia(sfondoSblocco: s)),
          ),
          _SceltaSfondo(
            titolo: 'Sfondo della chat',
            valore: imp.sfondoChat,
            onScelto: (s) => _salvaSfondo(imp.copia(sfondoChat: s)),
          ),
          _SceltaSfondo(
            titolo: 'Sfondo del database',
            nota: 'Vale anche per Categorie.',
            valore: imp.sfondoDatabase,
            onScelto: (s) => _salvaSfondo(imp.copia(sfondoDatabase: s)),
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

          // Nel browser il sync non c'è (`sync_rete_web.dart`): la sezione
          // porterebbe a una ricerca che non trova mai nessuno.
          if (!kIsWeb) _Sezione('Dispositivi'),
          // Qui e non nella barra: abbinare si fa una volta sola, mentre
          // sincronizzare si fa spesso — e infatti il tasto in alto ora
          // sincronizza invece di aprire questa schermata.
          if (!kIsWeb) ListTile(
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
          // Nel browser il vault vive nella memoria dell'icona sulla Home, che
          // se ne va con lei. È il rischio che l'app Android non ha, e va
          // detto dove si decide di fare il backup, non in un foglio d'aiuto.
          if (kIsWeb)
            ListTile(
              leading: IconaVM(Icone.avviso, color: context.cErrore),
              title: const Text('Il vault vive dentro questa app'),
              subtitle: Text(
                  'Se togli VaultMind dalla schermata Home, il vault se ne va '
                  'con lei. Salva un backup ogni volta che aggiungi qualcosa '
                  'di importante.',
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
            // Non più «sul PC resta tutto»: da quando il vault può nascere sul
            // telefono, per qualcuno questa è l'unica copia.
            subtitle: Text('Senza un PC o un backup, le password sono perse.',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
            onTap: _elimina,
          ),

          // Nel browser non c'è niente da controllare: la pagina si aggiorna
          // da sola col service worker, e la CSP non lascerebbe passare la
          // richiesta a GitHub (`aggiornamenti_rete_web.dart`).
          if (!kIsWeb) ...[
            _Sezione('Aggiornamenti'),
            RigaInterruttore(
              acceso: imp.aggAttivi,
              icona: const IconaVM(Icone.aggiorna, size: 22),
              titolo: 'Controlla se c\'è una versione nuova',
              descrizione: imp.aggAttivi
                  ? 'Una richiesta a GitHub ogni 12 ore, senza nessun dato tuo: '
                      'è l\'unica volta che VaultMind esce su Internet. Il vault non si muove da qui.'
                  : 'Spento: l\'app non si collega a Internet per nessun motivo. '
                      'Le versioni nuove restano su github.com/$repoGitHub/releases.',
              onChanged: (v) async {
                await salvaImpostazioni(imp.copia(aggAttivi: v));
                // Appena acceso si guarda subito: chi ha alzato
                // l'interruttore voleva sapere, non aspettare 12 ore.
                if (v) await _controllaOra(silenzioso: true);
              },
            ),
            ListTile(
              leading: IconaVM(
                  _novita == null ? Icone.info : Icone.avviso,
                  color: _novita == null ? context.cTenue : context.cAccento),
              title: Text(_novita == null
                  ? 'Hai la versione $versioneApp'
                  : 'C\'è la ${_novita!.versione}'),
              subtitle: Text(
                  _novita == null
                      ? 'L\'APK viene da github.com/$repoGitHub, firmato con la stessa chiave: si installa sopra e i dati restano.'
                      : 'Tocca qui per installarla: il vault, le impostazioni e i dispositivi abbinati restano dove sono.',
                  style: TextStyle(fontSize: 12, color: context.cTenue)),
              trailing: _controlloInCorso
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.cTenue))
                  : (imp.aggAttivi && _novita == null
                      ? TextButton(
                          onPressed: _controllaOra,
                          child: Text('Controlla',
                              style: TextStyle(
                                  color: context.cAccento, fontSize: 12.5)))
                      : null),
              onTap: _novita == null
                  ? null
                  : () => offriAggiornamento(context, _novita!)
                      .then((_) => mounted ? setState(() {}) : null),
            ),
          ],

          const SizedBox(height: 24),
          Center(
            child: Text('VaultMind $versioneApp · vault locale, niente cloud',
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

    final ok = await copiaNegliAppunti(scelta.password);
    if (ok) svuotaDopo(scelta.password);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Password copiata — $avvisoAppunti' : copiaRifiutata),
      duration: const Duration(seconds: 3),
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
          'Viene tolto da questo telefono, insieme alle copie di sicurezza.\n\n'
          'Se usi VaultMind anche su un PC, là resta tutto e potrai riaverlo. '
          'Se invece il vault esiste solo qui e non hai un backup, le password '
          'sono perse per sempre: prima salvane uno.',
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

/// Anteprima del tema: si sceglie con l'occhio, non leggendo un nome. Il
/// fondo del tema e, dentro, la sua coppia di neon: è quella che lo distingue.
class _Pastiglia extends StatelessWidget {
  final TemaId tema;
  const _Pastiglia({required this.tema});

  @override
  Widget build(BuildContext context) {
    final dati = temaDati(tema);
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: dati.colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: context.cBordo),
      ),
      child: Center(
        child: Container(
          width: 15,
          height: 15,
          decoration: BoxDecoration(
              gradient: dati.extension<Cristallo>()!.sfumatura,
              shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// I tre sfondi affiancati, uno per segmento: si vede subito quale è acceso,
/// senza aprire un menu per scoprirlo.
class _SceltaSfondo extends StatelessWidget {
  final String titolo;
  final String? nota;
  final Sfondo valore;
  final ValueChanged<Sfondo> onScelto;
  const _SceltaSfondo(
      {required this.titolo,
      this.nota,
      required this.valore,
      required this.onScelto});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Le misure di `RigaInterruttore`, la riga accanto.
            Text(titolo, style: TextStyle(fontSize: 15, color: context.cTesto)),
            if (nota != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(nota!,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.35, color: context.cTenue)),
              ),
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<Sfondo>(
                segments: [
                  for (final s in Sfondo.values)
                    ButtonSegment(value: s, label: Text(nomiSfondo[s]!)),
                ],
                selected: {valore},
                showSelectedIcon: false,
                onSelectionChanged: (scelti) => onScelto(scelti.first),
              ),
            ),
          ],
        ),
      );
}
