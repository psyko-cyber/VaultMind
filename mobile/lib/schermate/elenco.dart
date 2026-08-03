/// Elenco delle voci, con ricerca, copia e codici 2FA.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../ponte_file.dart';
import '../ricerca.dart';
import '../totp.dart';
import '../vault.dart';

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

  @override
  void initState() {
    super.initState();
    // L'indice si costruisce una volta sola: i vettori delle voci non
    // cambiano fra una ricerca e l'altra.
    _indice = IndiceRicerca(widget.vault.credenziali);
    _mostrate = widget.vault.credenziali;
    _ricerca.addListener(_programmaRicerca);
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
    final totali = widget.vault.credenziali.length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorePannello,
        title: const Text('VaultMind', style: TextStyle(letterSpacing: 1.5)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Text('$totali voci',
                  style: const TextStyle(fontSize: 12, color: coloreTenue)),
            ),
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
                prefixIcon: const Icon(Icons.search, color: coloreTenue),
                suffixIcon: _ricerca.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, color: coloreTenue),
                        onPressed: () => _ricerca.clear(),
                      ),
              ),
            ),
          ),
          if (_mostrate.isEmpty)
            const Expanded(
              child: Center(
                child: Text('Nessuna voce corrisponde.',
                    style: TextStyle(color: coloreTenue)),
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
    );
  }
}

class _SchedaVoce extends StatelessWidget {
  final Credenziale credenziale;
  const _SchedaVoce({required this.credenziale});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: colorePannello,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: coloreBordo),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          title: Row(
            children: [
              if (credenziale.critical)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.star, size: 15, color: coloreAccento),
                ),
              Expanded(
                child: Text(credenziale.title,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          subtitle: credenziale.tags.isEmpty
              ? null
              : Text(credenziale.tags.join(' · '),
                  style: const TextStyle(fontSize: 11, color: coloreTenue)),
          children: credenziale.fields
              .where((f) => f.value.trim().isNotEmpty)
              .map((f) => _RigaCampo(campo: f, idVoce: credenziale.id))
              .toList(),
        ),
      ),
    );
  }
}

class _RigaCampo extends StatefulWidget {
  final Campo campo;
  final int idVoce;
  const _RigaCampo({required this.campo, required this.idVoce});

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

  Future<void> _apri() async {
    final ok = await apriNelBrowser(widget.campo.value.trim());
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Non è stato possibile aprire l\'indirizzo.'),
      ));
    }
  }

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

  Future<void> _copia(String testo, String cosa) async {
    await Clipboard.setData(ClipboardData(text: testo));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$cosa copiato — gli appunti si svuotano fra 45 secondi'),
      duration: const Duration(seconds: 2),
    ));
    // Su Android gli appunti sono leggibili da altre app: un segreto non ci
    // resta a tempo indefinito.
    Future.delayed(const Duration(seconds: 45), () async {
      final attuale = await Clipboard.getData(Clipboard.kTextPlain);
      if (attuale?.text == testo) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
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
                style: const TextStyle(fontSize: 11, color: coloreTenue)),
          ),
          Expanded(
            child: Text(
              mostra ? widget.campo.value : '••••••••••',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: _isUrl ? const Color(0xFF6EA8FF) : coloreTesto),
            ),
          ),
          // Se il campo è un indirizzo, si apre nel browser con un tocco:
          // altrimenti andrebbe copiato e incollato a mano ogni volta.
          if (_isUrl && _sembraIndirizzo)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: 'Apri nel browser',
              icon: const Icon(Icons.open_in_new, color: Color(0xFF6EA8FF)),
              onPressed: _apri,
            ),
          if (_isSegreto)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: Icon(_visibile ? Icons.visibility_off : Icons.visibility,
                  color: coloreTenue),
              onPressed: () => setState(() => _visibile = !_visibile),
            ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, color: coloreTenue),
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
        color: const Color(0xFF0A1124),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: coloreBordo),
      ),
      child: o == null
          ? const Text('Secret 2FA non valido (atteso base32)',
              style: TextStyle(fontSize: 11.5, color: Color(0xFFE36868)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.campo.label.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 9.5, letterSpacing: 1.2, color: coloreTenue)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${o.code.substring(0, 3)} ${o.code.substring(3)}',
                        style: const TextStyle(
                            fontSize: 26,
                            letterSpacing: 4,
                            fontFamily: 'monospace',
                            color: Color(0xFF4CC38A)),
                      ),
                    ),
                    Text('${o.remaining}s',
                        style: const TextStyle(fontSize: 12, color: coloreTenue)),
                    IconButton(
                      icon: const Icon(Icons.copy, color: coloreTenue),
                      onPressed: () => _copia(o.code, 'Codice 2FA'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: o.remaining / 30,
                  minHeight: 3,
                  backgroundColor: coloreBordo,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF4CC38A)),
                ),
              ],
            ),
    );
  }
}
