/// La schermata Sincronizza: collegare il PC col QR, e vedere com'è andata.
///
/// Dal 25/10/2026 non c'è più niente da cercare né codici da scrivere: il PC
/// mostra un QR, il telefono lo inquadra, e da lì il PC chiama da solo ogni
/// pochi secondi. Qui restano un pulsante, l'elenco dei PC collegati e una
/// riga per ciascuno che dice quando si sono parlati l'ultima volta.
library;

import 'package:flutter/material.dart';

import '../icone.dart';
import '../interruttore.dart';
import '../ponte_file.dart';
import '../sync_gestore.dart';
import '../sync_rete.dart';
import '../tema.dart';
import 'dialoghi.dart';

class SchermataSincronizza extends StatefulWidget {
  final GestoreSync gestore;

  /// Apre subito la fotocamera: è la strada di chi ha appena creato il vault
  /// per collegarlo al PC, e non deve cercare il pulsante.
  final bool inquadraSubito;

  const SchermataSincronizza(
      {super.key, required this.gestore, this.inquadraSubito = false});

  @override
  State<SchermataSincronizza> createState() => _SchermataSincronizzaState();
}

class _SchermataSincronizzaState extends State<SchermataSincronizza> {
  late final TextEditingController _nome;
  late final Future<List<String>> _indirizzi;
  String? _errore;

  GestoreSync get g => widget.gestore;

  @override
  void initState() {
    super.initState();
    _nome = TextEditingController(text: g.nome);
    _indirizzi = indirizziLocali();
    g.addListener(_aggiorna);
    if (widget.inquadraSubito) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _inquadra());
    }
  }

  @override
  void dispose() {
    g.removeListener(_aggiorna);
    g.collegatoOra = null; // detto: la prossima volta non si ripete
    _nome.dispose();
    super.dispose();
  }

  void _aggiorna() {
    if (mounted) setState(() {});
  }

  Future<void> _inquadra() async {
    setState(() => _errore = null);
    final r = await qrDaFotocamera(
        coloreAccento: context.cAccento.toARGB32(), titolo: 'Inquadra il QR del PC');
    if (!mounted) return;
    switch (r.esito) {
      case EsitoQr.letto:
        try {
          await g.collega(r.testo!);
        } on FormatException catch (e) {
          setState(() => _errore = e.message);
        }
      case EsitoQr.permessoNegato:
        setState(() => _errore = 'Serve il permesso della fotocamera: '
            'consentilo nelle impostazioni di Android per VaultMind.');
      case EsitoQr.fotocameraNonDisponibile:
        setState(() => _errore = 'La fotocamera non è disponibile: chiudi le '
            'altre app che la usano e riprova.');
      default:
        break; // tornato indietro: niente da dire
    }
  }

  @override
  Widget build(BuildContext context) {
    final pc = g.pcCollegati.values.toList();
    final tenue = TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.5);
    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizza')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          RigaInterruttore(
            acceso: g.acceso,
            onChanged: (v) => g.imposta(acceso: v),
            icona: const IconaVM(Icone.sync, size: 20),
            titolo: 'Sincronizzazione',
            descrizione: !g.acceso
                ? 'Spenta: nessuna porta aperta, il PC non trova questo telefono.'
                : (g.portaOccupata
                    ? 'Accesa, ma la porta $portaSync è occupata da un\'altra app: '
                        'riavvia il telefono.'
                    : 'Accesa: risponde solo ai PC collegati col QR.'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nome,
            maxLength: 40,
            decoration: const InputDecoration(
                labelText: 'Nome di questo telefono, come lo vedrà il PC',
                counterText: ''),
            onSubmitted: (v) => g.imposta(nome: v),
            onTapOutside: (_) {
              if (_nome.text.trim() != g.nome) g.imposta(nome: _nome.text);
            },
          ),
          const SizedBox(height: 20),

          if (g.collegatoOra != null)
            _riquadro(context, Icone.scudoOk,
                'Collegato a «${g.collegatoOra}». Da adesso le voci si allineano '
                'da sole, ogni volta che VaultMind è aperto qui.')
          else if (g.inAttesaDelPc && g.inAscolto)
            _attesa(context)
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _inquadra,
                icon: const IconaVM(Icone.fotocamera),
                label: Text(pc.isEmpty ? 'Collega al PC' : 'Collega un altro PC',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                style: FilledButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          if (_errore != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconaVM(Icone.avviso, size: 16, color: context.cErrore),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_errore!,
                        style: TextStyle(
                            fontSize: 12.5, color: context.cErrore, height: 1.45))),
              ],
            ),
          ],
          if (pc.isEmpty && !g.inAttesaDelPc) ...[
            const SizedBox(height: 10),
            Text(
                'Sul PC apri VaultMind › Sincronizza › «Collega un telefono», '
                'poi tocca qui sopra e inquadra il QR.',
                style: tenue),
          ],

          const SizedBox(height: 22),
          _titoletto(context, 'PC collegati'),
          if (pc.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Nessuno ancora.', style: tenue),
            )
          else
            ...pc.map((p) => _rigaPc(context, p)),

          const SizedBox(height: 24),
          Text(
            'Il PC cerca questo telefono da solo, ogni pochi secondi, finché '
            'VaultMind è aperto e sbloccato qui e i due sono sulla stessa WiFi. '
            'Se una voce cambia su tutti e due, vince l\'ultima modifica. I dati '
            'viaggiano cifrati con la chiave del QR.',
            style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.5),
          ),
          FutureBuilder<List<String>>(
            future: _indirizzi,
            builder: (context, s) => (s.data ?? const []).isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                        'Indirizzo di questo telefono: ${s.data!.join(' · ')}',
                        style: TextStyle(
                            fontSize: 11.5, color: context.cTenue, height: 1.5)),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _titoletto(BuildContext c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t.toUpperCase(),
            style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: c.cTenue)),
      );

  Widget _riquadro(BuildContext context, String icona, String testo) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cAccento.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cAccento.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconaVM(icona, size: 20, color: context.cAccento),
            const SizedBox(width: 10),
            Expanded(
                child: Text(testo,
                    style: TextStyle(fontSize: 13, color: context.cTesto, height: 1.5))),
          ],
        ),
      );

  Widget _attesa(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cPannello,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cBordo),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: context.cAccento),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    g.pcInAttesa.isEmpty
                        ? 'Aspetto il PC…'
                        : 'Aspetto «${g.pcInAttesa}»…',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Lascia aperto il QR sul PC e questa schermata qui: si collegano '
              'da soli in pochi secondi, se sono sulla stessa WiFi.',
              style: TextStyle(fontSize: 12.5, color: context.cTesto, height: 1.5),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: g.annullaCollegamento,
                child: Text('Annulla', style: TextStyle(color: context.cTenue)),
              ),
            ),
          ],
        ),
      );

  String _quando(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'adesso';
    if (d.inMinutes < 60) return '${d.inMinutes} min fa';
    String due(int n) => n.toString().padLeft(2, '0');
    return 'alle ${due(t.hour)}:${due(t.minute)}';
  }

  Widget _rigaPc(BuildContext context, PcCollegato p) {
    final e = g.ultimi[p.id];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: IconaVM(Icone.dispositivi,
            color: e != null ? context.cAccento : context.cTenue),
        title: Text(p.nome, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          e == null
              ? 'Non ancora sentito da quando hai aperto l\'app: se il PC è acceso '
                  'con VaultMind aperto, si fa vivo in pochi secondi.'
              : 'Sentito ${_quando(e.quando)}${e.qualcosa ? ' · ${e.riassunto}' : ' · allineati'}',
          style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.4),
        ),
        trailing: TextButton(
          onPressed: () async {
            final ok = await confermaDistruttiva(
              context,
              titolo: 'Scollegare «${p.nome}»?',
              dettaglio: 'Le voci restano dove sono, su tutti e due. Per '
                  'sincronizzare di nuovo servirà inquadrare un QR nuovo.',
              conferma: 'Scollega',
            );
            if (ok == true) await g.scollega(p.id);
          },
          child: Text('Scollega',
              style: TextStyle(color: context.cErrore, fontSize: 12.5)),
        ),
      ),
    );
  }
}
