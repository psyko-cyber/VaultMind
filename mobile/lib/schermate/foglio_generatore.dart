/// Il generatore di password, come foglio che sale dal basso.
///
/// Un foglio e non una schermata: si apre **sopra** quello che stavi facendo,
/// e quel che stavi facendo — di solito un modulo mezzo compilato — resta
/// visibile dietro. Una schermata intera obbligherebbe a fidarsi che tornando
/// indietro il modulo sia ancora lì.
///
/// La logica sta in `generatore.dart` ed è provata dai test; qui c'è solo il
/// modo di guardarla.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../generatore.dart';
import '../icone.dart';
import '../impostazioni.dart';
import '../tema.dart';
import 'scheda_voce.dart' show svuotaDopo;

/// Cosa ha deciso chi ha aperto il foglio.
class SceltaGeneratore {
  final String password;

  /// L'utente ha chiesto di salvarla in una voce nuova, non solo di copiarla.
  /// Vale solo quando il foglio è stato aperto da fuori da un modulo.
  final bool creaVoce;

  const SceltaGeneratore(this.password, {this.creaVoce = false});
}

/// Apre il generatore. `null` se si chiude senza scegliere niente.
///
/// [etichettaAzione] cambia col posto da cui si apre: dentro un modulo la
/// password va **nel campo**, da sola va **negli appunti**. È la stessa
/// schermata, ma il pulsante grande deve dire cosa succede davvero.
Future<SceltaGeneratore?> mostraGeneratore(
  BuildContext context, {
  String etichettaAzione = 'Usa questa password',
  bool mostraCreaVoce = false,
}) {
  return showModalBottomSheet<SceltaGeneratore>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _FoglioGeneratore(
      etichettaAzione: etichettaAzione,
      mostraCreaVoce: mostraCreaVoce,
    ),
  );
}

class _FoglioGeneratore extends StatefulWidget {
  final String etichettaAzione;
  final bool mostraCreaVoce;

  const _FoglioGeneratore({
    required this.etichettaAzione,
    required this.mostraCreaVoce,
  });

  @override
  State<_FoglioGeneratore> createState() => _FoglioGeneratoreState();
}

class _FoglioGeneratoreState extends State<_FoglioGeneratore> {
  late int _lunghezza;
  late bool _simboli;
  bool _maiuscole = true;
  bool _minuscole = true;
  bool _cifre = true;
  String _password = '';

  @override
  void initState() {
    super.initState();
    // Lunghezza e simboli si ricordano fra un uso e l'altro: chi ha deciso che
    // le vuole da 28 non lo rifà ogni volta. Le altre tre classi no — spegnere
    // le cifre è una deroga per un sito che non le accetta, e non deve
    // diventare la regola senza che nessuno se ne accorga.
    _lunghezza = impostazioni.value.genLunghezza;
    _simboli = impostazioni.value.genSimboli;
    _rigenera();
  }

  void _rigenera() {
    setState(() {
      _password = generaPassword(
        lunghezza: _lunghezza,
        maiuscole: _maiuscole,
        minuscole: _minuscole,
        cifre: _cifre,
        simboli: _simboli,
      );
    });
  }

  /// Ogni ritocco genera una password nuova, e quella nuova viene salvata come
  /// preferenza: se si scrivesse solo alla chiusura, chi tocca il cursore e
  /// poi annulla si ritroverebbe la lunghezza cambiata lo stesso.
  void _cambia(void Function() modifica) {
    modifica();
    _rigenera();
    salvaImpostazioni(impostazioni.value
        .copia(genLunghezza: _lunghezza, genSimboli: _simboli));
  }

  double get _bit => bitDiEntropia(
        lunghezza: _lunghezza,
        maiuscole: _maiuscole,
        minuscole: _minuscole,
        cifre: _cifre,
        simboli: _simboli,
      );

  Color _coloreForza(BuildContext context) {
    final b = _bit;
    if (b < 45) return context.cErrore;
    if (b < 60) return context.cAccento;
    return context.cVerde;
  }

  Future<void> _copia() async {
    await Clipboard.setData(ClipboardData(text: _password));
    svuotaDopo(_password);
    if (!mounted) return;
    Navigator.of(context).pop(SceltaGeneratore(_password));
  }

  @override
  Widget build(BuildContext context) {
    final vuota = _password.isEmpty;

    return Container(
      decoration: BoxDecoration(
        color: context.cPannello,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: context.cBordo),
      ),
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 10,
        // Senza, la tastiera o la barra di navigazione coprono il pulsante.
        bottom: MediaQuery.of(context).viewInsets.bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: context.cBordo,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                IconaVM(Icone.dado, size: 20, color: context.cAccento),
                const SizedBox(width: 8),
                Text('Genera una password',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.cTesto)),
              ],
            ),
            const SizedBox(height: 14),

            _riquadroPassword(context, vuota),
            const SizedBox(height: 10),
            if (!vuota) _forza(context),

            const SizedBox(height: 18),
            Row(
              children: [
                Text('Lunghezza',
                    style: TextStyle(fontSize: 13, color: context.cTenue)),
                Expanded(
                  child: Slider(
                    value: _lunghezza.toDouble(),
                    min: lunghezzaMinima.toDouble(),
                    max: lunghezzaMassima.toDouble(),
                    divisions: lunghezzaMassima - lunghezzaMinima,
                    activeColor: context.cAccento,
                    onChanged: (v) =>
                        _cambia(() => _lunghezza = v.round()),
                  ),
                ),
                SizedBox(
                  width: 26,
                  child: Text('$_lunghezza',
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          fontSize: 14,
                          fontFamily: 'JetBrains Mono',
                          color: context.cTesto)),
                ),
              ],
            ),

            // Quattro pastiglie invece di quattro righe con interruttore: sono
            // scelte brevi e vicine, e in verticale occuperebbero mezzo
            // schermo per dire "A-Z".
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Classe(
                    etichetta: 'A-Z',
                    attiva: _maiuscole,
                    onTap: () => _cambia(() => _maiuscole = !_maiuscole)),
                _Classe(
                    etichetta: 'a-z',
                    attiva: _minuscole,
                    onTap: () => _cambia(() => _minuscole = !_minuscole)),
                _Classe(
                    etichetta: '0-9',
                    attiva: _cifre,
                    onTap: () => _cambia(() => _cifre = !_cifre)),
                _Classe(
                    etichetta: '!@#',
                    attiva: _simboli,
                    onTap: () => _cambia(() => _simboli = !_simboli)),
              ],
            ),
            if (vuota)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Accendi almeno un tipo di carattere.',
                  style: TextStyle(fontSize: 12.5, color: context.cErrore),
                ),
              ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: vuota
                    ? null
                    : () => Navigator.of(context)
                        .pop(SceltaGeneratore(_password)),
                style: FilledButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(widget.etichettaAzione,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            if (widget.mostraCreaVoce) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: vuota
                      ? null
                      : () => Navigator.of(context).pop(
                          SceltaGeneratore(_password, creaVoce: true)),
                  icon: IconaVM(Icone.piu, size: 18, color: context.cAccento),
                  label: Text('Salvala in una voce nuova',
                      style: TextStyle(fontSize: 13, color: context.cAccento)),
                ),
              ),
              // Una password generata e mai salvata è una password persa: il
              // sito la accetta, e al prossimo accesso non ce l'ha nessuno.
              Text(
                'Copiarla e basta va bene solo se la salvi subito da qualche parte.',
                style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _riquadroPassword(BuildContext context, bool vuota) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: context.cFondo,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.cBordo),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                vuota ? '—' : _password,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.35,
                  fontFamily: 'JetBrains Mono',
                  color: vuota ? context.cTenue : context.cTesto,
                ),
              ),
            ),
            IconButton(
              iconSize: 20,
              tooltip: 'Copia',
              icon: IconaVM(Icone.copia, color: context.cTenue),
              onPressed: vuota ? null : _copia,
            ),
            IconButton(
              iconSize: 20,
              tooltip: 'Rigenera',
              icon: IconaVM(Icone.aggiorna, color: context.cAccento),
              onPressed: vuota ? null : _rigenera,
            ),
          ],
        ),
      );

  Widget _forza(BuildContext context) {
    final bit = _bit;
    final colore = _coloreForza(context);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              // 128 bit come fondo scala: oltre non c'è niente da guadagnare,
              // e una barra che non si riempie mai non dice niente a nessuno.
              value: (bit / 128).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: context.cBordo,
              valueColor: AlwaysStoppedAnimation(colore),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text('${giudizio(bit)} · ${bit.round()} bit',
            style: TextStyle(fontSize: 12, color: colore)),
      ],
    );
  }
}

/// Una delle quattro classi di caratteri, accesa o spenta.
class _Classe extends StatelessWidget {
  final String etichetta;
  final bool attiva;
  final VoidCallback onTap;

  const _Classe({
    required this.etichetta,
    required this.attiva,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: attiva
              ? context.cAccento.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: attiva ? context.cAccento : context.cBordo),
        ),
        child: Text(
          etichetta,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'JetBrains Mono',
            // Spenta resta `cTenue` e non un grigio più chiaro: è il colore
            // che in tutti e tre i temi supera 4,5:1 sul pannello.
            color: attiva ? context.cAccento : context.cTenue,
          ),
        ),
      ),
    );
  }
}
