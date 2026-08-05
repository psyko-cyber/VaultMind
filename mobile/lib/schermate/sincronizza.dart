/// La schermata Sincronizza.
///
/// Non si chiama VPN: dentro l'app non costruiamo una VPN — quella è WireGuard
/// sul router — e chi legge quel nome si aspetterebbe di essere protetto fuori
/// casa. La VPN è spiegata qui dentro come la strada per il caso "fuori casa",
/// che per il codice è identica all'essere sulla rete di casa.
library;

import 'package:flutter/material.dart';

import '../fusione.dart';
import '../sync_gestore.dart';
import '../sync_rete.dart';
import '../tema.dart';
import 'dialoghi.dart';

class SchermataSincronizza extends StatefulWidget {
  final GestoreSync gestore;
  const SchermataSincronizza({super.key, required this.gestore});

  @override
  State<SchermataSincronizza> createState() => _SchermataSincronizzaState();
}

class _SchermataSincronizzaState extends State<SchermataSincronizza> {
  late final TextEditingController _nome;
  final _indirizzo = TextEditingController();
  List<Trovato> _trovati = const [];
  bool _cerco = false;
  bool _aManoInCorso = false;
  String? _messaggio;

  GestoreSync get g => widget.gestore;

  @override
  void initState() {
    super.initState();
    _nome = TextEditingController(text: g.nome);
    g.addListener(_aggiorna);
    if (g.acceso) _cerca();
  }

  @override
  void dispose() {
    g.removeListener(_aggiorna);
    _nome.dispose();
    _indirizzo.dispose();
    super.dispose();
  }

  void _aggiorna() {
    if (mounted) setState(() {});
  }

  Future<void> _cerca() async {
    setState(() {
      _cerco = true;
      _messaggio = null;
    });
    final t = await g.cerca();
    if (!mounted) return;
    setState(() {
      _trovati = t;
      _cerco = false;
    });
  }

  Future<void> _sincronizza(Trovato d, {String codice = ''}) async {
    setState(() => _messaggio = null);
    final esito = await g.sincronizzaCon(d, codice: codice);
    if (!mounted) return;
    setState(() => _messaggio = esito.errore ?? 'Con ${d.etichetta}: ${esito.riassunto}');
    _cerca();
  }

  /// Il collegamento all'indirizzo scritto a mano.
  ///
  /// Non serve il codice: qui si parla con un dispositivo **già abbinato** —
  /// se non lo fosse verrebbe respinto, ed è giusto così. Riuscito una volta,
  /// l'indirizzo se lo ricorda l'app e questo campo non serve mai più.
  Future<void> _aManoVai() async {
    final ind = _indirizzo.text.trim();
    if (ind.isEmpty || _aManoInCorso) return;
    setState(() {
      _aManoInCorso = true;
      _messaggio = null;
    });
    final esito = await g.sincronizzaConIndirizzo(ind);
    if (!mounted) return;
    setState(() {
      _aManoInCorso = false;
      _messaggio = esito.errore ?? 'Con ${esito.con}: ${esito.riassunto}';
    });
    if (esito.errore == null) _indirizzo.clear();
  }

  Widget _aMano(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _indirizzo,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Indirizzo del dispositivo',
                  hintText: '192.168.5.53',
                  isDense: true,
                ),
                onSubmitted: (_) => _aManoVai(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _aManoInCorso ? null : _aManoVai,
              style: OutlinedButton.styleFrom(
                  side: BorderSide(color: context.cBordo),
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14)),
              child: Text(_aManoInCorso ? '…' : 'Vai',
                  style: TextStyle(color: context.cAccento)),
            ),
          ],
        ),
      );

  Future<void> _chiediCodice(Trovato d) async {
    // Campo in linea e non un dialogo di sistema: stessa scelta del PC, e su
    // Android un dialogo in più su una schermata già piena è solo rumore.
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: dc.cPannello,
        title: Text('Abbina "${d.etichetta}"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scrivi le sei cifre mostrate sull\'altro dispositivo.',
                style: TextStyle(fontSize: 13, color: dc.cTenue, height: 1.45)),
            const SizedBox(height: 14),
            TextField(
              controller: c,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(
                  fontSize: 22, letterSpacing: 8, fontFamily: 'monospace'),
              decoration: const InputDecoration(counterText: '', hintText: '000000'),
              onSubmitted: (_) => Navigator.pop(dc, true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dc, false),
              child: Text('Annulla', style: TextStyle(color: dc.cTenue))),
          FilledButton(
            onPressed: () => Navigator.pop(dc, true),
            style: FilledButton.styleFrom(
                backgroundColor: dc.cAccento, foregroundColor: dc.cSuAccento),
            child: const Text('Abbina'),
          ),
        ],
      ),
    );
    if (ok == true && c.text.trim().length == 6) {
      await _sincronizza(d, codice: c.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final codice = g.codiceAttivo();
    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizza')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: g.acceso,
            onChanged: (v) => g.imposta(acceso: v),
            activeThumbColor: context.cAccento,
            title: const Text('Sincronizzazione', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              !g.acceso
                  ? 'Spenta. Nessuna porta aperta, questo telefono non risponde a nessuno.'
                  : (g.inAscolto
                      ? 'Accesa: risponde solo a chi ha la chiave di questo vault.'
                      : 'Accesa, ma la porta non si è aperta. Il sync a mano funziona lo stesso.'),
              style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.4),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nome,
            decoration: const InputDecoration(labelText: 'Nome di questo telefono'),
            onSubmitted: (v) => g.imposta(nome: v),
            onTapOutside: (_) => g.imposta(nome: _nome.text),
          ),

          if (g.conflitti.isNotEmpty) ...[
            const SizedBox(height: 20),
            _Conflitti(gestore: g),
          ],

          if (_messaggio != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.cPannello,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: context.cBordo),
              ),
              child: Text(_messaggio!,
                  style: TextStyle(fontSize: 12.5, color: context.cTesto, height: 1.45)),
            ),
          ],

          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: g.acceso ? _cerca : null,
                  icon: Icon(Icons.search, size: 18, color: context.cAccento),
                  label: Text(_cerco ? 'Cerco…' : 'Cerca',
                      style: TextStyle(color: context.cAccento)),
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.cBordo),
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: g.acceso
                      ? () {
                          g.apriAbbinamento();
                          _cerca();
                        }
                      : null,
                  icon: Icon(Icons.add_link, size: 18, color: context.cAccento),
                  label: Text('Abbina', style: TextStyle(color: context.cAccento)),
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.cBordo),
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ],
          ),

          if (codice != null) _codiceInCorso(context, codice),

          const SizedBox(height: 18),
          _titoletto(context, 'Sulla rete adesso'),
          if (_trovati.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _cerco
                    ? 'Cerco sulla rete locale…'
                    : 'Nessuno ha risposto. L\'altro dev\'essere sulla stessa rete, '
                        'con l\'app aperta e il vault sbloccato.\n\n'
                        'Se sei fuori casa con la VPN, la domanda non passa: i tunnel '
                        'non portano i broadcast. Scrivi qui sotto l\'indirizzo del PC '
                        '— poi l\'app se lo ricorda.',
                style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.5),
              ),
            )
          else
            ..._trovati.map((d) => _rigaTrovato(context, d)),

          if (_trovati.isEmpty && !_cerco) _aMano(context),

          const SizedBox(height: 18),
          _titoletto(context, 'Dispositivi fidati'),
          if (g.fidati.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Nessuno ancora. «Abbina» mostra un codice da scrivere sull\'altro '
                'dispositivo — o scrivi qui quello che mostra lui.',
                style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.5),
              ),
            )
          else
            ...g.fidati.entries.map((e) => _rigaFidato(context, e.key, e.value)),

          const SizedBox(height: 24),
          Text(
            'I due dispositivi devono essere sulla stessa rete e con il vault '
            'aperto. Fuori casa, una VPN verso casa (WireGuard sul router) '
            'rimette il telefono dentro la rete: per il sync è identico '
            'all\'essere sul divano.',
            style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _titoletto(BuildContext c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 10, letterSpacing: 1.5, color: c.cTenue)),
      );

  Widget _codiceInCorso(BuildContext context, String codice) => Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cAccento.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cAccento.withValues(alpha: 0.45)),
        ),
        child: Column(
          children: [
            Text('CODICE DI ABBINAMENTO',
                style: TextStyle(
                    fontSize: 10, letterSpacing: 1.4, color: context.cTenue)),
            const SizedBox(height: 8),
            Text(codice,
                style: TextStyle(
                    fontSize: 32,
                    letterSpacing: 8,
                    fontFamily: 'monospace',
                    color: context.cAccento)),
            const SizedBox(height: 8),
            Text(
              'Scrivilo sull\'altro dispositivo entro ${g.secondiRimasti} secondi. '
              'Poi controlla che l\'impronta mostrata sia identica sui due schermi: '
              'è la verifica che nessuno si sia messo in mezzo.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: context.cTesto, height: 1.5),
            ),
          ],
        ),
      );

  Widget _rigaTrovato(BuildContext context, Trovato d) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(d.conosciuto ? Icons.devices : Icons.device_unknown,
              color: d.conosciuto ? context.cAccento : context.cTenue),
          title: Text(d.etichetta, style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            d.conosciuto
                ? 'già abbinato · ${d.indirizzo}'
                : (d.abbinabile ? 'pronto ad abbinarsi' : 'da abbinare'),
            style: TextStyle(fontSize: 11.5, color: context.cTenue),
          ),
          trailing: FilledButton(
            onPressed: () =>
                d.conosciuto ? _sincronizza(d) : _chiediCodice(d),
            style: FilledButton.styleFrom(
                backgroundColor: context.cAccento,
                foregroundColor: context.cSuAccento,
                visualDensity: VisualDensity.compact),
            child: Text(d.conosciuto ? 'Sincronizza' : 'Abbina'),
          ),
        ),
      );

  Widget _rigaFidato(BuildContext context, String id, String nome) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(Icons.verified_user_outlined, color: context.cAccento),
          title: Text(nome, style: const TextStyle(fontSize: 14)),
          trailing: TextButton(
            onPressed: () async {
              final ok = await confermaDistruttiva(
                context,
                titolo: 'Revocare "$nome"?',
                dettaglio: 'Da quel momento non potrà più sincronizzare con '
                    'questo telefono senza essere abbinato di nuovo.',
                conferma: 'Revoca',
              );
              if (ok == true) await g.revoca(id);
            },
            child: Text('Revoca',
                style: TextStyle(color: context.cErrore, fontSize: 12.5)),
          ),
        ),
      );
}

/// Le voci cambiate su tutti e due i dispositivi. Finché non decidi, ognuno
/// tiene la propria: niente è andato perso.
class _Conflitti extends StatelessWidget {
  final GestoreSync gestore;
  const _Conflitti({required this.gestore});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.cAccento.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.cAccento.withValues(alpha: 0.45)),
          ),
          child: Text(
            'Da decidere. Queste voci sono state cambiate su tutti e due i '
            'dispositivi. Finché non scegli, ognuno tiene la propria: niente è '
            'andato perso.',
            style: TextStyle(fontSize: 12, color: context.cTesto, height: 1.45),
          ),
        ),
        for (final c in gestore.conflitti.values) _scheda(context, c),
      ],
    );
  }

  Widget _scheda(BuildContext context, Conflitto c) => Card(
        margin: const EdgeInsets.only(top: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.titolo,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text(_spiega(c.motivo),
                  style: TextStyle(fontSize: 11.5, color: context.cTenue)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _scelta(context, c, 'mia', 'Tieni la mia', c.mia)),
                  const SizedBox(width: 8),
                  Expanded(child: _scelta(context, c, 'sua', 'Tieni la sua', c.sua)),
                ],
              ),
            ],
          ),
        ),
      );

  /// Si mostrano le ETICHETTE dei campi, mai i valori: scegliere fra due
  /// versioni non deve costringere a farsi stampare due password sullo schermo.
  Widget _scelta(BuildContext context, Conflitto c, String quale, String etichetta,
          dynamic versione) =>
      OutlinedButton(
        onPressed: () => gestore.risolvi(c.uid, quale),
        style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.cBordo),
            padding: const EdgeInsets.symmetric(vertical: 10)),
        child: Column(
          children: [
            Text(etichetta,
                style: TextStyle(fontSize: 12.5, color: context.cAccento)),
            const SizedBox(height: 2),
            Text(
              versione == null
                  ? 'cancellata'
                  : (versione.fields.isEmpty
                      ? 'nessun campo'
                      : versione.fields.map((f) => f.label).join(' · ')),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: context.cTenue),
            ),
          ],
        ),
      );

  String _spiega(String motivo) => const {
        entrambiModificata: 'modificata su tutti e due',
        modificataQuiCancellataLa: 'modificata qui, cancellata sull\'altro',
        cancellataQuiModificataLa: 'cancellata qui, modificata sull\'altro',
      }[motivo] ??
      motivo;
}
