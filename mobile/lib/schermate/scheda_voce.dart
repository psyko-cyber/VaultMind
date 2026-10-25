/// I pezzi di una voce che servono a più schermate: il monogramma, la riga
/// dell'elenco, la scheda trovata dalla chat, la riga di un campo (col suo
/// 2FA) e gli appunti.
///
/// Stanno in un file solo perché la stessa voce compare nel database, nelle
/// categorie, nella chat e nella sua schermata (`voce.dart`): una riga di
/// campo che si comporta in quattro modi a seconda di dove sta è un modo lento
/// di introdurre incoerenze.
///
/// Dal 25/10/2026 (7.1) l'elenco non apre più le voci sul posto: ogni riga
/// porta alla schermata della voce, come il dettaglio accanto all'elenco sul
/// PC. La scheda che si espandeva teneva i campi, le azioni e il 2FA dentro
/// una riga alta come un dito, e Modifica ed Elimina stavano a un centimetro
/// dal pulsante per copiare.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../impostazioni.dart';
import '../ponte_file.dart';
import '../sessione.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';
import '../icone.dart';
import 'voce.dart';

/// Etichette il cui valore è un segreto: si mostrano a pallini finché non si
/// tocca l'occhio. Un vault aperto in metropolitana non deve stampare le
/// password sullo schermo.
///
/// La stessa del PC (`SEGRETO` in index.html): meglio un pallino di troppo
/// che un CVV in chiaro. Prima mancavano cvv, seed e i codici di recupero.
final segreto = RegExp(
    r'pass|pwd|pin|secret|segret|chiave|key|token|codice|code|puk|puc|cvv|cvc|seed|recovery|recupero',
    caseSensitive: false);
final _url = RegExp(r'^(url|sito|link|indirizzo|website|web)$', caseSensitive: false);

/// Il campo che fa da sottotitolo nell'elenco: chi sei su quel servizio.
final _utente = RegExp(r'utente|user|e-?mail|login|account', caseSensitive: false);

/// Qui in cima come le due sopra, e non dentro il metodo che le usa: erano
/// ricostruite a ogni disegno di ogni scheda — per ogni campo, in un ciclo —
/// e scorrere l'elenco significava compilare decine di espressioni regolari
/// per fotogramma. Nel browser dell'iPhone è scorrimento a scatti.
final _iniziaPass = RegExp(r'^pass', caseSensitive: false);
final _indirizzoApribile = RegExp(r'^https?://', caseSensitive: false);
final _primaLettera = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _dice2fa = RegExp(r'2fa|otp|mfa', caseSensitive: false);

/// Su Android gli appunti sono leggibili da altre app: un segreto non ci resta
/// a tempo indefinito.
///
/// Nel browser non si può. Safari scrive negli appunti solo in risposta a un
/// tocco, e per rileggerli mostra la bolla «Incolla»: comparirebbe da sola,
/// 45 secondi dopo, senza che nessuno capisca perché. Meglio non promettere
/// (vedi [avvisoAppunti]) che promettere e non mantenere.
void svuotaDopo(String testo) {
  if (kIsWeb) return;
  Future.delayed(const Duration(seconds: 45), () async {
    final attuale = await Clipboard.getData(Clipboard.kTextPlain);
    if (attuale?.text == testo) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  });
}

/// Copia negli appunti; `false` se il sistema rifiuta.
///
/// Su Android non succede. Nel browser sì: Safari scrive negli appunti solo a
/// ridosso di un tocco, e un'attesa in mezzo (un foglio che si chiude) basta a
/// perdere il permesso. Prima l'errore non era gestito, e il tocco sembrava
/// semplicemente non fare niente — trovato provando la versione web.
Future<bool> copiaNegliAppunti(String testo) async {
  try {
    await Clipboard.setData(ClipboardData(text: testo));
    return true;
  } catch (_) {
    return false;
  }
}

/// Cosa dire quando [copiaNegliAppunti] non riesce: cosa è successo e cosa fare.
const copiaRifiutata = 'Il browser non ha permesso di copiare: tocca di nuovo l\'icona.';

/// La coda del messaggio dopo una copia, vera per dove gira l'app.
const avvisoAppunti = kIsWeb
    ? 'resta negli appunti finché non copi altro'
    : 'gli appunti si svuotano fra 45 secondi';

/// La riga in basso dopo una copia: la spunta se è andata, l'avviso se no.
/// Quella di prima toglieva quella vecchia solo alla scadenza, e tre copie di
/// fila facevano la coda.
void avvisaCopia(BuildContext context, bool ok, String testo) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(
        children: [
          IconaVM(ok ? Icone.spunta : Icone.avviso,
              size: 18, color: ok ? context.cVerde : context.cErrore),
          const SizedBox(width: 10),
          Expanded(child: Text(ok ? testo : copiaRifiutata)),
        ],
      ),
      duration: Duration(seconds: ok ? 3 : 4),
    ));
}

/// La somiglianza come la mostra il PC: fra 0 e 1, con la virgola. La
/// ricerca ci somma un bonus per le parole esatte, e «1,24» non vorrebbe
/// dire niente.
String formatoSomiglianza(double s) =>
    s.clamp(0.0, 1.0).toStringAsFixed(2).replaceAll('.', ',');

/// Il sottotitolo di una voce nell'elenco: l'utente, se ne ha uno leggibile.
/// Mai un campo segreto, nemmeno se si chiama «account».
String utenteDi(Credenziale c) {
  for (final f in c.fields) {
    final v = f.value.trim();
    if (v.isNotEmpty && _utente.hasMatch(f.label) && !segreto.hasMatch(f.label)) {
      return v;
    }
  }
  return '';
}

bool ha2fa(Credenziale c) =>
    c.fields.any((f) => f.value.trim().isNotEmpty && etichettaSembraOtp(f.label));

/// Il campo che si copia con un tocco lungo: la password, o il primo
/// segreto disponibile. È il gesto più frequente, e merita la via corta.
Campo? campoDaCopiare(Credenziale c) {
  for (final f in c.fields) {
    if (f.value.trim().isEmpty) continue;
    if (_iniziaPass.hasMatch(f.label)) return f;
  }
  for (final f in c.fields) {
    if (f.value.trim().isNotEmpty &&
        !etichettaSembraOtp(f.label) &&
        segreto.hasMatch(f.label)) {
      return f;
    }
  }
  return null;
}

/// La tinta del monogramma: la stessa funzione del PC (`tinta()` in
/// index.html), sui code point della categoria, così la stessa voce ha lo
/// stesso colore sui due schermi. I numeri restano sotto i 2^25: nessun
/// problema col browser, dove gli interi sono double.
int tintaCategoria(String categoria) {
  var h = 0;
  for (final cp in categoria.runes) {
    h = (h * 31 + cp) % 1000003;
  }
  return h % 3;
}

/// La prima lettera o cifra del titolo: «(vecchio) Fritz» è una F, non una
/// parentesi.
String inizialeTitolo(String titolo) {
  final m = _primaLettera.firstMatch(titolo);
  return m == null ? '·' : m.group(0)!.toUpperCase();
}

/// Il segno di riconoscimento della voce: l'iniziale su due neon del tema.
///
/// La coppia la sceglie la categoria, quindi le voci di una stessa categoria
/// si somigliano. Tre tinte e non una ruota di colori: è il motivo per cui
/// `coloreCategoria()` è stato tolto il 04/08 (vedi in fondo a `tema.dart`),
/// e qui i colori restano quelli del tema che hai scelto.
///
/// **Non** si scaricano le icone vere dei servizi: bisognerebbe chiederle a
/// Internet, e ogni richiesta direbbe a qualcuno quali servizi usi — cioè
/// esattamente ciò che questo prodotto promette di non fare.
class Monogramma extends StatelessWidget {
  final String titolo;
  final String categoria;
  final double lato;

  const Monogramma(
      {super.key, required this.titolo, this.categoria = '', this.lato = 40});

  Monogramma.voce(Credenziale c, {super.key, this.lato = 40})
      : titolo = c.title,
        categoria = c.categoria;

  @override
  Widget build(BuildContext context) {
    final k = context.cristallo;
    final coppia = switch (tintaCategoria(categoria)) {
      1 => [k.neon2, k.neon3],
      2 => [k.neon3, k.neon1],
      _ => [k.neon1, k.neon2],
    };
    return ExcludeSemantics(
      child: Container(
        width: lato,
        height: lato,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(lato * .3),
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: coppia),
          // L'alone solo sui monogrammi grandi: in un elenco di 800 righe
          // un'ombra sfocata per riga si paga a ogni fotogramma di
          // scorrimento, e nel browser dell'iPhone si vede.
          boxShadow: lato < 56
              ? null
              : [
                  BoxShadow(
                      color: coppia[0].withValues(alpha: .45),
                      blurRadius: lato * .45,
                      offset: Offset(0, lato * .14),
                      spreadRadius: -lato * .16),
                ],
        ),
        child: Text(inizialeTitolo(titolo),
            style: TextStyle(
                fontFamily: 'Space Grotesk',
                fontWeight: FontWeight.w600,
                fontSize: lato * .42,
                height: 1,
                color: k.suNeon)),
      ),
    );
  }
}

/// Una pillola di testo: la categoria, un tag, «2FA».
class Pillola extends StatelessWidget {
  final String testo;
  final Color? colore;
  const Pillola(this.testo, {super.key, this.colore});

  @override
  Widget build(BuildContext context) {
    final c = colore;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: c == null ? context.cFondo.withValues(alpha: .5) : null,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c?.withValues(alpha: .5) ?? context.cBordo),
      ),
      child: Text(testo,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: c == null ? FontWeight.w500 : FontWeight.w600,
              color: c ?? context.cTenue)),
    );
  }
}

/// Apre la schermata della voce. Si passa l'id e non la voce: se mentre è
/// aperta la voce cambia (una modifica, un sync), la schermata la rilegge.
Future<void> apriVoce(BuildContext context, Sessione sessione, int id) =>
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SchermataVoce(sessione: sessione, id: id)));

/// Una voce nell'elenco: monogramma, titolo, utente. Un tocco la apre, un
/// tocco lungo copia la password senza aprire niente.
class RigaVoce extends StatelessWidget {
  final Credenziale credenziale;
  final Sessione sessione;

  /// Un'azione in più a destra (togli dalla categoria).
  final Widget? coda;

  const RigaVoce(
      {super.key, required this.credenziale, required this.sessione, this.coda});

  Future<void> _copiaRapida(BuildContext context, Campo campo) async {
    final ok = await copiaNegliAppunti(campo.value);
    if (!context.mounted) return;
    avvisaCopia(context, ok,
        '${campo.label} di «${credenziale.title}» copiata: $avvisoAppunti');
    if (ok) svuotaDopo(campo.value);
  }

  @override
  Widget build(BuildContext context) {
    final c = credenziale;
    final utente = utenteDi(c);
    final sotto = utente.isNotEmpty ? utente : c.categoria;
    final rapido = campoDaCopiare(c);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => apriVoce(context, sessione, c.id),
        onLongPress: rapido == null ? null : () => _copiaRapida(context, rapido),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Monogramma.voce(c),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (eFissata(c.id))
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: IconaVM(Icone.fissa,
                                size: 13, color: context.cAccento),
                          ),
                        Flexible(
                          child: Text(c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    if (sotto.isNotEmpty)
                      Text(sotto,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: context.cTenue)),
                  ],
                ),
              ),
              if (c.critical)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Semantics(
                    label: 'critica',
                    child: IconaVM(Icone.stella, size: 15, color: context.cAccento),
                  ),
                ),
              if (ha2fa(c))
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Pillola('2FA', colore: context.cAccento),
                ),
              ?coda,
            ],
          ),
        ),
      ),
    );
  }
}

/// La voce trovata dalla chat: chi è, quanto somiglia alla richiesta, i campi.
///
/// La somiglianza è il numero che ha deciso, mostrato com'è: il match si
/// trova, non si inventa, e qui si vede.
class SchedaTrovata extends StatelessWidget {
  final Credenziale credenziale;
  final double? somiglianza;
  final VoidCallback? onApri;

  const SchedaTrovata(
      {super.key, required this.credenziale, this.somiglianza, this.onApri});

  @override
  Widget build(BuildContext context) {
    final c = credenziale;
    final k = context.cristallo;
    final campi = c.fields.where((f) => f.value.trim().isNotEmpty).toList();
    // Un filo prismatico intorno, come la scheda trovata del PC: è la
    // risposta, e deve staccarsi dalle frasi.
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        gradient: k.prisma,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Container(
        margin: const EdgeInsets.all(1.2),
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 6),
        decoration: BoxDecoration(
          color: context.cPannello,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Monogramma.voce(c),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.title,
                          style: const TextStyle(
                              fontFamily: 'Space Grotesk',
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      if (c.categoria.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Pillola(c.categoria),
                      ],
                    ],
                  ),
                ),
                if (somiglianza != null) ...[
                  const SizedBox(width: 8),
                  _Somiglianza(somiglianza!),
                ],
              ],
            ),
            const SizedBox(height: 6),
            for (final f in campi) RigaCampo(campo: f),
            if (onApri != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onApri,
                  icon: IconaVM(Icone.chevronDestra, size: 16, color: context.cAccento),
                  label: Text('Apri la voce',
                      style: TextStyle(color: context.cAccento, fontSize: 13)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Somiglianza extends StatelessWidget {
  final double valore;
  const _Somiglianza(this.valore);

  @override
  Widget build(BuildContext context) {
    final k = context.cristallo;
    return Semantics(
      label: 'Somiglianza ${formatoSomiglianza(valore)}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('Somiglianza', style: TextStyle(fontSize: 11, color: context.cTenue)),
          Text(formatoSomiglianza(valore),
              style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: k.neon2)),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              width: 56,
              height: 3,
              child: LinearProgressIndicator(
                value: valore.clamp(0.0, 1.0),
                backgroundColor: context.cBordo,
                valueColor: AlwaysStoppedAnimation(k.neon2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Una riga di campo: etichetta, valore, azioni. I campi normali si leggono
/// (l'utente di un conto non è un segreto), gli indirizzi si aprono, i
/// segreti restano a pallini finché non li chiedi — e per 15 secondi, come
/// sul PC: un occhio lasciato aperto in tasca è una password in vista.
///
/// [grande] per la schermata della voce, dove c'è posto: caratteri più
/// grandi e il 2FA a tutta larghezza.
class RigaCampo extends StatefulWidget {
  final Campo campo;
  final bool grande;
  const RigaCampo({super.key, required this.campo, this.grande = false});

  @override
  State<RigaCampo> createState() => _RigaCampoState();
}

class _RigaCampoState extends State<RigaCampo> {
  bool _visibile = false;
  CodiceOtp? _otp;
  Timer? _timer;
  Timer? _richiudi;

  bool get _isOtp => etichettaSembraOtp(widget.campo.label);
  bool get _isSegreto => !_isOtp && segreto.hasMatch(widget.campo.label);
  bool get _isUrl => _url.hasMatch(widget.campo.label.trim());

  /// Il valore è davvero un indirizzo apribile? Un campo etichettato "sito"
  /// che contiene "quello vecchio" non deve mostrare un pulsante che non
  /// porta da nessuna parte.
  bool get _sembraIndirizzo =>
      _indirizzoApribile.hasMatch(widget.campo.value.trim());

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
    _richiudi?.cancel();
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

  void _occhio() {
    _richiudi?.cancel();
    setState(() => _visibile = !_visibile);
    if (_visibile) {
      _richiudi = Timer(const Duration(seconds: 15), () {
        if (mounted) setState(() => _visibile = false);
      });
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
    final ok = await copiaNegliAppunti(testo);
    if (!mounted) return;
    avvisaCopia(context, ok,
        _isSegreto || _isOtp ? '$cosa copiato: $avvisoAppunti' : '$cosa copiato.');
    if (ok && (_isSegreto || _isOtp)) svuotaDopo(testo);
  }

  @override
  Widget build(BuildContext context) {
    if (_isOtp) return _rigaOtp();

    final g = widget.grande;
    final mostra = !_isSegreto || _visibile;
    return Padding(
      padding: EdgeInsets.fromLTRB(g ? 0 : 2, g ? 10 : 4, 0, g ? 10 : 4),
      child: Row(
        children: [
          SizedBox(
            width: g ? 100 : 84,
            child: Text(widget.campo.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: g ? 13 : 12, color: context.cTenue)),
          ),
          Expanded(
            child: Text(
              mostra ? widget.campo.value : '••••••••••',
              overflow: g ? null : TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: g ? 15.5 : 13.5,
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
              tooltip: _visibile ? 'Nascondi' : 'Mostra',
              icon: IconaVM(_visibile ? Icone.occhioBarrato : Icone.occhio,
                  color: context.cTenue),
              onPressed: _occhio,
            ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: 'Copia',
            icon: IconaVM(Icone.copia, color: context.cTenue),
            onPressed: () => _copia(widget.campo.value, widget.campo.label),
          ),
        ],
      ),
    );
  }

  /// Il 2FA: il codice e un anello che si consuma, rosso negli ultimi
  /// cinque secondi. L'anello dice quanto manca senza dover leggere un
  /// numero, e un codice copiato a un secondo dalla fine non arriva al sito.
  Widget _rigaOtp() {
    final o = _otp;
    final g = widget.grande;
    final etichetta = widget.campo.label;
    final nome = _dice2fa.hasMatch(etichetta) ? etichetta : '$etichetta · 2FA';
    return Container(
      margin: EdgeInsets.symmetric(vertical: g ? 12 : 6),
      padding: EdgeInsets.fromLTRB(g ? 16 : 12, 12, 6, 12),
      decoration: BoxDecoration(
        color: context.cFondo.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cBordo),
      ),
      child: o == null
          ? Text('Secret 2FA non valido (atteso base32)',
              style: TextStyle(fontSize: 12, color: context.cErrore))
          : Row(
              children: [
                _Anello(resto: o.remaining, lato: g ? 58 : 44),
                SizedBox(width: g ? 16 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nome,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: context.cTenue)),
                      const SizedBox(height: 2),
                      Text(
                        '${o.code.substring(0, 3)} ${o.code.substring(3)}',
                        style: TextStyle(
                            fontSize: g ? 30 : 24,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrains Mono',
                            color: context.cTesto),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copia il codice',
                  icon: IconaVM(Icone.copia, color: context.cTenue),
                  onPressed: () => _copia(o.code, 'Codice 2FA'),
                ),
              ],
            ),
    );
  }
}

class _Anello extends StatelessWidget {
  final int resto;
  final double lato;
  const _Anello({required this.resto, required this.lato});

  @override
  Widget build(BuildContext context) {
    final scade = resto <= 5;
    final colore = scade ? context.cErrore : context.cristallo.neon2;
    return Semantics(
      label: 'cambia fra $resto secondi',
      excludeSemantics: true,
      child: SizedBox(
        width: lato,
        height: lato,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: resto / 30,
                strokeWidth: lato > 50 ? 4 : 3,
                backgroundColor: context.cBordo,
                valueColor: AlwaysStoppedAnimation(colore),
              ),
            ),
            Text('$resto',
                style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: lato > 50 ? 14 : 12,
                    color: scade ? colore : context.cTenue)),
          ],
        ),
      ),
    );
  }
}
