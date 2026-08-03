/// Elenco delle voci, con ricerca, copia e codici 2FA.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../impostazioni.dart';
import '../ponte_file.dart';
import '../ricerca.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';
import 'impostazioni.dart';
import 'sblocco.dart';

/// Etichette il cui valore è un segreto: si mostrano a pallini finché non si
/// tocca l'occhio. Un vault aperto in metropolitana non deve stampare le
/// password sullo schermo.
final _segreto = RegExp(r'pass|pin|secret|chiave|key|token|codice|puk|puc',
    caseSensitive: false);
final _url = RegExp(r'^(url|sito|link|indirizzo|website|web)$', caseSensitive: false);

class SchermataElenco extends StatefulWidget {
  final Vault vault;
  const SchermataElenco({super.key, required this.vault});

  @override
  State<SchermataElenco> createState() => _SchermataElencoState();
}

class _SchermataElencoState extends State<SchermataElenco> {
  final _ricerca = TextEditingController();
  late final IndiceRicerca _indice;
  List<Credenziale> _mostrate = const [];
  Timer? _attesa;
  Timer? _inattivita;

  @override
  void initState() {
    super.initState();
    // L'indice si costruisce una volta sola: i vettori delle voci non
    // cambiano fra una ricerca e l'altra.
    _indice = IndiceRicerca(widget.vault.credenziali);
    _mostrate = widget.vault.credenziali;
    _ricerca.addListener(_programmaRicerca);
    _riarmaBlocco();
  }

  @override
  void dispose() {
    _attesa?.cancel();
    _inattivita?.cancel();
    _ricerca.dispose();
    super.dispose();
  }

  /// Il vault si richiude da solo dopo un po' che non lo si tocca: un telefono
  /// si lascia sul tavolo molto più facilmente di un computer.
  void _riarmaBlocco() {
    _inattivita?.cancel();
    final minuti = impostazioni.value.autoBlocco;
    if (minuti <= 0) return;
    _inattivita = Timer(Duration(minutes: minuti), _blocca);
  }

  void _blocca() {
    if (!mounted) return;
    // Si torna alla schermata di sblocco, e le voci decifrate se ne vanno
    // insieme a questa schermata: non restano in memoria.
    Navigator.of(context).popUntil((r) => r.isFirst);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SchermataSblocco(vaultPresente: true)),
    );
  }

  /// Con 800 voci una ricerca costa qualche decina di millisecondi: farla a
  /// ogni singolo tasto premuto renderebbe la digitazione a scatti. Si aspetta
  /// che l'utente smetta di scrivere per un attimo.
  void _programmaRicerca() {
    _attesa?.cancel();
    _attesa = Timer(const Duration(milliseconds: 120), _cerca);
  }

  void _cerca() {
    final q = _ricerca.text.trim();
    if (!mounted) return;
    setState(() {
      _mostrate = q.isEmpty
          ? widget.vault.credenziali
          : _indice.cerca(q).map((r) => r.voce).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Qualsiasi tocco rimanda il blocco: si conta l'inattività vera, non il
      // tempo trascorso.
      onPointerDown: (_) => _riarmaBlocco(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('VaultMind', style: TextStyle(letterSpacing: 1.5)),
          actions: [
            Center(
              child: Text('${widget.vault.credenziali.length} voci',
                  style: TextStyle(fontSize: 12, color: context.cTenue)),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Impostazioni',
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SchermataImpostazioni(
                      quanteVoci: widget.vault.credenziali.length),
                )).then((_) => _riarmaBlocco());
              },
            ),
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: 'Blocca',
              onPressed: _blocca,
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
                  hintText: 'Cerca…',
                  prefixIcon: Icon(Icons.search, color: context.cTenue),
                  suffixIcon: _ricerca.text.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.clear, color: context.cTenue),
                          onPressed: () => _ricerca.clear(),
                        ),
                ),
              ),
            ),
            if (_mostrate.isEmpty)
              Expanded(
                child: Center(
                  child: Text('Nessuna voce corrisponde.',
                      style: TextStyle(color: context.cTenue)),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                  itemCount: _mostrate.length,
                  itemBuilder: (_, i) => _SchedaVoce(credenziale: _mostrate[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SchedaVoce extends StatelessWidget {
  final Credenziale credenziale;
  const _SchedaVoce({required this.credenziale});

  /// Il campo che si copia con un tocco lungo: la password, o il primo
  /// segreto disponibile. È il gesto più frequente, e merita la via corta.
  Campo? get _daCopiare {
    for (final f in credenziale.fields) {
      if (f.value.trim().isEmpty) continue;
      if (RegExp(r'^pass', caseSensitive: false).hasMatch(f.label)) return f;
    }
    for (final f in credenziale.fields) {
      if (f.value.trim().isNotEmpty &&
          !etichettaSembraOtp(f.label) &&
          _segreto.hasMatch(f.label)) {
        return f;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final rapido = _daCopiare;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          title: GestureDetector(
            onLongPress: rapido == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: rapido.value));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('${rapido.label} di "${credenziale.title}" copiata'),
                      duration: const Duration(seconds: 2),
                    ));
                    _svuotaDopo(rapido.value);
                  },
            child: Row(
              children: [
                if (credenziale.critical)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(Icons.star, size: 15, color: context.cAccento),
                  ),
                Expanded(
                  child: Text(credenziale.title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          subtitle: credenziale.tags.isEmpty
              ? null
              : Text(credenziale.tags.join(' · '),
                  style: TextStyle(fontSize: 11, color: context.cTenue)),
          children: credenziale.fields
              .where((f) => f.value.trim().isNotEmpty)
              .map((f) => _RigaCampo(campo: f))
              .toList(),
        ),
      ),
    );
  }
}

/// Su Android gli appunti sono leggibili da altre app: un segreto non ci resta
/// a tempo indefinito.
void _svuotaDopo(String testo) {
  Future.delayed(const Duration(seconds: 45), () async {
    final attuale = await Clipboard.getData(Clipboard.kTextPlain);
    if (attuale?.text == testo) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  });
}

class _RigaCampo extends StatefulWidget {
  final Campo campo;
  const _RigaCampo({required this.campo});

  @override
  State<_RigaCampo> createState() => _RigaCampoState();
}

class _RigaCampoState extends State<_RigaCampo> {
  bool _visibile = false;
  CodiceOtp? _otp;
  Timer? _timer;

  bool get _isOtp => etichettaSembraOtp(widget.campo.label);
  bool get _isSegreto => !_isOtp && _segreto.hasMatch(widget.campo.label);
  bool get _isUrl => _url.hasMatch(widget.campo.label.trim());

  /// Il valore è davvero un indirizzo apribile? Un campo etichettato "sito"
  /// che contiene "quello vecchio" non deve mostrare un pulsante che non
  /// porta da nessuna parte.
  bool get _sembraIndirizzo =>
      RegExp(r'^https?://', caseSensitive: false).hasMatch(widget.campo.value.trim());

  @override
  void initState() {
    super.initState();
    if (_isOtp) {
      _aggiornaOtp();
      // Il codice cambia ogni 30 secondi: senza aggiornamento si copierebbe
      // un codice già scaduto, che è il modo più frustrante di fallire.
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _aggiornaOtp());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _aggiornaOtp() {
    try {
      final o = generaOtp(widget.campo.value);
      if (mounted) setState(() => _otp = o);
    } catch (_) {
      _timer?.cancel();
      if (mounted) setState(() => _otp = null);
    }
  }

  Future<void> _apri() async {
    final ok = await apriNelBrowser(widget.campo.value.trim());
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Non è stato possibile aprire l\'indirizzo.'),
      ));
    }
  }

  Future<void> _copia(String testo, String cosa) async {
    await Clipboard.setData(ClipboardData(text: testo));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$cosa copiato — gli appunti si svuotano fra 45 secondi'),
      duration: const Duration(seconds: 2),
    ));
    _svuotaDopo(testo);
  }

  @override
  Widget build(BuildContext context) {
    if (_isOtp) return _rigaOtp();

    final mostra = !_isSegreto || _visibile;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(widget.campo.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: context.cTenue)),
          ),
          Expanded(
            child: Text(
              mostra ? widget.campo.value : '••••••••••',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: _isUrl ? context.cLink : context.cTesto),
            ),
          ),
          // Se il campo è un indirizzo, si apre nel browser con un tocco:
          // altrimenti andrebbe copiato e incollato a mano ogni volta.
          if (_isUrl && _sembraIndirizzo)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: 'Apri nel browser',
              icon: Icon(Icons.open_in_new, color: context.cLink),
              onPressed: _apri,
            ),
          if (_isSegreto)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: Icon(_visibile ? Icons.visibility_off : Icons.visibility,
                  color: context.cTenue),
              onPressed: () => setState(() => _visibile = !_visibile),
            ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy, color: context.cTenue),
            onPressed: () => _copia(widget.campo.value, widget.campo.label),
          ),
        ],
      ),
    );
  }

  Widget _rigaOtp() {
    final o = _otp;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.cFondo,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.cBordo),
      ),
      child: o == null
          ? Text('Secret 2FA non valido (atteso base32)',
              style: TextStyle(fontSize: 11.5, color: context.cErrore))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.campo.label.toUpperCase(),
                    style: TextStyle(
                        fontSize: 9.5, letterSpacing: 1.2, color: context.cTenue)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${o.code.substring(0, 3)} ${o.code.substring(3)}',
                        style: TextStyle(
                            fontSize: 26,
                            letterSpacing: 4,
                            fontFamily: 'monospace',
                            color: context.cVerde),
                      ),
                    ),
                    Text('${o.remaining}s',
                        style: TextStyle(fontSize: 12, color: context.cTenue)),
                    IconButton(
                      icon: Icon(Icons.copy, color: context.cTenue),
                      onPressed: () => _copia(o.code, 'Codice 2FA'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: o.remaining / 30,
                  minHeight: 3,
                  backgroundColor: context.cBordo,
                  valueColor: AlwaysStoppedAnimation(context.cVerde),
                ),
              ],
            ),
    );
  }
}
