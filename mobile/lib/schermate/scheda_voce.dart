/// La scheda di una credenziale: titolo, campi, 2FA, copia e azioni.
///
/// Sta in un file suo perché la usano tre sezioni — database, categorie e la
/// risposta della chat — e una scheda che si comporta in tre modi diversi a
/// seconda di dove sta è un modo lento di introdurre incoerenze.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../impostazioni.dart';
import '../ponte_file.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';
import '../icone.dart';

/// Etichette il cui valore è un segreto: si mostrano a pallini finché non si
/// tocca l'occhio. Un vault aperto in metropolitana non deve stampare le
/// password sullo schermo.
final segreto = RegExp(r'pass|pin|secret|chiave|key|token|codice|puk|puc',
    caseSensitive: false);
final _url = RegExp(r'^(url|sito|link|indirizzo|website|web)$', caseSensitive: false);

/// Su Android gli appunti sono leggibili da altre app: un segreto non ci resta
/// a tempo indefinito.
void svuotaDopo(String testo) {
  Future.delayed(const Duration(seconds: 45), () async {
    final attuale = await Clipboard.getData(Clipboard.kTextPlain);
    if (attuale?.text == testo) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  });
}

class SchedaVoce extends StatelessWidget {
  final Credenziale credenziale;

  /// Assenti quando la scheda è di sola consultazione (la risposta della chat).
  final VoidCallback? onModifica;
  final VoidCallback? onElimina;

  /// Aperta già espansa: serve alla chat, dove la voce trovata è la risposta e
  /// nascondere i campi vorrebbe dire chiedere un tocco in più per niente.
  final bool aperta;

  const SchedaVoce({
    super.key,
    required this.credenziale,
    this.onModifica,
    this.onElimina,
    this.aperta = false,
  });

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
          segreto.hasMatch(f.label)) {
        return f;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Un colore solo, quello del tema. Prima ogni scheda ne prendeva uno
    // diverso ricavato dalla categoria: l'elenco diventava arlecchino e il
    // tema non si vedeva più.
    final colore = context.cAccento;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Barra verticale a sinistra, come sulle schede del PC.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(width: 4, color: colore),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _contenuto(context, _daCopiare, colore),
          ),
        ],
      ),
    );
  }

  Widget _contenuto(BuildContext context, Campo? rapido, Color colore) {
    final sottotitolo = <String>[
      if (credenziale.categoria.isNotEmpty) credenziale.categoria,
      ...credenziale.tags,
    ];

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ValueListenableBuilder<Impostazioni>(
        valueListenable: impostazioni,
        builder: (context, _, _) {
          final fissata = eFissata(credenziale.id);
          return ExpansionTile(
            shape: const Border(),
            collapsedShape: const Border(),
            initiallyExpanded: aperta,
            leading: _Pallino(colore: colore, titolo: credenziale.title),
            title: GestureDetector(
              onLongPress: rapido == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: rapido.value));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content:
                            Text('${rapido.label} di "${credenziale.title}" copiata'),
                        duration: const Duration(seconds: 2),
                      ));
                      svuotaDopo(rapido.value);
                    },
              child: Row(
                children: [
                  if (fissata)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: IconaVM(Icone.fissa, size: 14, color: colore),
                    ),
                  if (credenziale.critical)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: IconaVM(Icone.stella, size: 15, color: context.cAccento),
                    ),
                  Expanded(
                    child: Text(credenziale.title,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            subtitle: sottotitolo.isEmpty
                ? null
                : Text(sottotitolo.join(' · '),
                    style: TextStyle(fontSize: 11, color: context.cTenue)),
            children: [
              ...credenziale.fields
                  .where((f) => f.value.trim().isNotEmpty)
                  .map((f) => _RigaCampo(campo: f)),
              _Azioni(
                fissata: fissata,
                onFissa: () => cambiaFissata(credenziale.id),
                onModifica: onModifica,
                onElimina: onElimina,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// La riga in fondo alla scheda aperta.
///
/// Le azioni stanno qui e non sul tocco lungo perché quel gesto è già preso da
/// "copia la password", che è il motivo per cui si apre l'app: spostarlo per
/// far posto a un menu significherebbe rendere più lenta la cosa più frequente.
class _Azioni extends StatelessWidget {
  final bool fissata;
  final VoidCallback onFissa;
  final VoidCallback? onModifica;
  final VoidCallback? onElimina;

  const _Azioni({
    required this.fissata,
    required this.onFissa,
    this.onModifica,
    this.onElimina,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: onFissa,
            icon: IconaVM(fissata ? Icone.fissa : Icone.fissa,
                size: 16, color: context.cTenue),
            label: Text(fissata ? 'Liberala' : 'Fissa in cima',
                style: TextStyle(fontSize: 12, color: context.cTenue)),
          ),
          const Spacer(),
          if (onModifica != null)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: 'Modifica',
              icon: IconaVM(Icone.matita, color: context.cTenue),
              onPressed: onModifica,
            ),
          if (onElimina != null)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: 'Elimina',
              icon: IconaVM(Icone.cestino, color: context.cErrore),
              onPressed: onElimina,
            ),
        ],
      ),
    );
  }
}

/// Segno di riconoscimento della voce: l'iniziale su un cerchio del colore
/// della categoria.
///
/// **Non** si scaricano le icone vere dei servizi: bisognerebbe chiederle a
/// Internet, e ogni richiesta direbbe a qualcuno quali servizi usi — cioè
/// esattamente ciò che questo prodotto promette di non fare. Vedi TODO §1.2.
class _Pallino extends StatelessWidget {
  final Color colore;
  final String titolo;
  const _Pallino({required this.colore, required this.titolo});

  @override
  Widget build(BuildContext context) {
    final t = titolo.trim();
    final iniziale = t.isEmpty ? '?' : t.substring(0, 1).toUpperCase();
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: colore.withValues(alpha: 0.16),
        shape: BoxShape.circle,
        border: Border.all(color: colore.withValues(alpha: 0.55)),
      ),
      child: Center(
        child: Text(iniziale,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: colore)),
      ),
    );
  }
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
  bool get _isSegreto => !_isOtp && segreto.hasMatch(widget.campo.label);
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
    svuotaDopo(testo);
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
                  fontFamily: 'JetBrains Mono',
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
              icon: IconaVM(Icone.esterno, color: context.cLink),
              onPressed: _apri,
            ),
          if (_isSegreto)
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: IconaVM(_visibile ? Icone.occhioBarrato : Icone.occhio,
                  color: context.cTenue),
              onPressed: () => setState(() => _visibile = !_visibile),
            ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: IconaVM(Icone.copia, color: context.cTenue),
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
                            fontFamily: 'JetBrains Mono',
                            color: context.cVerde),
                      ),
                    ),
                    Text('${o.remaining}s',
                        style: TextStyle(fontSize: 12, color: context.cTenue)),
                    IconButton(
                      icon: IconaVM(Icone.copia, color: context.cTenue),
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
