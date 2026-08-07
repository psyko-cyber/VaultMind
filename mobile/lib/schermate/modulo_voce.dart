/// Aggiunta e modifica di una credenziale, dal telefono.
///
/// Esiste dal 04/08/2026, insieme alla scrittura del vault. Prima le voci si
/// creavano solo sul PC, perché il telefono non poteva scrivere.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../sessione.dart';
import '../tema.dart';
import '../totp.dart';
import '../vault.dart';
import '../icone.dart';
import '../interruttore.dart';
import 'foglio_2fa.dart';
import 'foglio_generatore.dart';

/// Le etichette proposte quando si aggiunge un campo: sono quelle che ricorrono
/// nel 90% delle voci, e sceglierle da un elenco evita che la stessa cosa si
/// chiami "utente" in una voce e "username" in un'altra — cosa che peggiora
/// anche la ricerca, che indicizza le etichette.
const _etichetteComuni = [
  'Utente', 'Email', 'Password', 'URL', 'OTP (2FA)', 'PIN', 'Note',
];

class ModuloVoce extends StatefulWidget {
  final Sessione sessione;

  /// Assente = nuova voce.
  final Credenziale? voce;

  /// Categoria proposta: serve al "+" dentro una categoria, che deve creare
  /// la voce già dentro quella.
  final String categoriaIniziale;

  /// Password già pronta per il campo Password.
  ///
  /// La passa il generatore aperto da fuori da qui, con «Salvala in una voce
  /// nuova»: una password generata e mai salvata è una password persa.
  final String? passwordIniziale;

  const ModuloVoce({
    super.key,
    required this.sessione,
    this.voce,
    this.categoriaIniziale = '',
    this.passwordIniziale,
  });

  @override
  State<ModuloVoce> createState() => _ModuloVoceState();
}

class _ModuloVoceState extends State<ModuloVoce> {
  late final TextEditingController _titolo;
  late final TextEditingController _tags;
  late List<({TextEditingController label, TextEditingController value})> _campi;
  late bool _critica;
  late String _categoria;
  bool _occupato = false;
  String? _errore;
  Timer? _orologio;

  bool get _nuova => widget.voce == null;

  @override
  void initState() {
    super.initState();
    final v = widget.voce;
    _titolo = TextEditingController(text: v?.title ?? '');
    _tags = TextEditingController(text: (v?.tags ?? const []).join(', '));
    _critica = v?.critical ?? false;
    _categoria = v?.categoria ?? widget.categoriaIniziale;
    _campi = [
      for (final c in v?.fields ?? const <Campo>[])
        (
          label: TextEditingController(text: c.label),
          value: TextEditingController(text: c.value)
        ),
    ];
    if (_campi.isEmpty) _aggiungiCampo('Utente');
    if (_campi.length == 1 && _nuova) _aggiungiCampo('Password');
    final pw = widget.passwordIniziale;
    if (pw != null && pw.isNotEmpty) _mettiPassword(pw);

    // Il codice 2FA sotto il campo si aggiorna da sé: serve a rispondere alla
    // sola domanda che conta subito dopo aver inquadrato un QR — «ho letto la
    // cosa giusta?». Un numero fermo non risponde, perché non si distingue da
    // uno calcolato male.
    _orologio = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _secretOtp != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _orologio?.cancel();
    _titolo.dispose();
    _tags.dispose();
    for (final c in _campi) {
      c.label.dispose();
      c.value.dispose();
    }
    super.dispose();
  }

  void _aggiungiCampo([String etichetta = '', String valore = '']) {
    _campi.add((
      label: TextEditingController(text: etichetta),
      value: TextEditingController(text: valore)
    ));
    if (mounted) setState(() {});
  }

  void _togliCampo(int i) {
    final c = _campi.removeAt(i);
    c.label.dispose();
    c.value.dispose();
    setState(() {});
  }

  // ------------------------------------------------------- generatore

  /// Dove finisce una password generata, nell'ordine: il primo campo Password
  /// **vuoto**, altrimenti il primo campo Password, altrimenti un campo nuovo.
  ///
  /// Stessa scala di priorità del PC (`genUse`), e per la stessa ragione: chi
  /// genera una password mentre modifica una voce quasi sempre la sta
  /// cambiando, e sovrascrivere quella vecchia è ciò che vuole. Ma se ha già
  /// aggiunto un campo Password vuoto, quello viene prima — l'ha aperto lui.
  void _mettiPassword(String password) {
    int? bersaglio;
    for (var i = 0; i < _campi.length; i++) {
      if (!RegExp(r'pass', caseSensitive: false).hasMatch(_campi[i].label.text)) {
        continue;
      }
      if (_campi[i].value.text.isEmpty) {
        bersaglio = i;
        break;
      }
      bersaglio ??= i;
    }
    if (bersaglio == null) {
      _aggiungiCampo('Password', password);
    } else {
      _campi[bersaglio].value.text = password;
      if (mounted) setState(() {});
    }
  }

  Future<void> _generaPassword() async {
    final scelta = await mostraGeneratore(context);
    if (scelta != null) _mettiPassword(scelta.password);
  }

  // ------------------------------------------------------------- 2FA

  /// Il secret 2FA già presente nella voce, se c'è.
  ///
  /// Si legge dai campi e non da uno stato a parte: nel vault la 2FA **è** un
  /// campo, e tenerne una copia qui vorrebbe dire due verità che possono
  /// divergere appena qualcuno modifica il campo a mano.
  String? get _secretOtp {
    for (final c in _campi) {
      if (etichettaSembraOtp(c.label.text) && c.value.text.trim().isNotEmpty) {
        return c.value.text.trim();
      }
    }
    return null;
  }

  Future<void> _aggiungi2FA() async {
    final dati = await mostraFoglio2FA(context);
    if (dati == null || !mounted) return;

    // Se un campo OTP c'è già lo si riempie, invece di aggiungerne un secondo:
    // due secret nella stessa voce vorrebbero dire due codici diversi e nessun
    // modo di sapere quale sia quello buono.
    for (final c in _campi) {
      if (etichettaSembraOtp(c.label.text)) {
        c.value.text = dati.secret;
        setState(() {});
        return;
      }
    }
    _aggiungiCampo('OTP (2FA)', dati.secret);

    // Il titolo lo propone il QR solo se non c'è già: quello scritto a mano
    // vince sempre su quello dedotto.
    if (_titolo.text.trim().isEmpty && dati.titoloProposto.isNotEmpty) {
      _titolo.text = dati.titoloProposto;
    }
  }

  /// Password e secret 2FA nella stessa voce: da quel momento il secondo
  /// fattore non è più un fattore separato, perché chi apre il vault ha
  /// entrambi. Si avvisa e basta — bloccare il salvataggio significherebbe
  /// decidere al posto di chi usa l'app, e a volte è una scelta consapevole.
  bool get _duefattoriInsieme {
    final etichette = _campi.map((c) => c.label.text).toList();
    final haPassword = etichette.any((l) =>
        RegExp(r'pass', caseSensitive: false).hasMatch(l));
    final haOtp = etichette.any(etichettaSembraOtp);
    return haPassword && haOtp;
  }

  Future<void> _salva() async {
    setState(() {
      _occupato = true;
      _errore = null;
    });
    try {
      final campi = [
        for (final c in _campi) Campo(c.label.text, c.value.text),
      ];
      final tags = _tags.text.split(',');
      if (_nuova) {
        await widget.sessione.aggiungiVoce(
          titolo: _titolo.text,
          campi: campi,
          tags: tags,
          critica: _critica,
          categoria: _categoria,
        );
      } else {
        await widget.sessione.modificaVoce(
          widget.voce!.id,
          titolo: _titolo.text,
          campi: campi,
          tags: tags,
          critica: _critica,
          categoria: _categoria,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ModificaRifiutata catch (e) {
      setState(() => _errore = e.messaggio);
    } catch (e) {
      // Se il salvataggio non riesce, la voce NON risulta salvata: la sessione
      // aggiorna la memoria solo a disco a posto.
      setState(() => _errore = 'Non è stato possibile salvare la voce.');
    } finally {
      if (mounted) setState(() => _occupato = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categorie = widget.sessione.vault.categorie;

    return Scaffold(
      appBar: AppBar(
        title: Text(_nuova ? 'Nuova voce' : 'Modifica voce'),
        actions: [
          TextButton(
            onPressed: _occupato ? null : _salva,
            child: Text('Salva',
                style: TextStyle(
                    color: context.cAccento, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          TextField(
            controller: _titolo,
            autofocus: _nuova,
            decoration: const InputDecoration(labelText: 'Titolo'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 18),

          Text('CAMPI',
              style: TextStyle(
                  fontSize: 10, letterSpacing: 1.5, color: context.cTenue)),
          const SizedBox(height: 8),
          for (var i = 0; i < _campi.length; i++) _rigaCampo(i),
          // I due pulsanti stanno affiancati perché sono due modi di riempire
          // la stessa cosa. Il generatore in fondo alla lista e non accanto al
          // campo Password: l'etichetta di un campo si scrive a mano, e un
          // pulsante che compare e sparisce mentre si digita è peggio di uno
          // fermo.
          Wrap(
            children: [
              TextButton.icon(
                onPressed: () => _aggiungiCampo(),
                icon: IconaVM(Icone.piu, size: 18, color: context.cAccento),
                label: Text('Aggiungi campo',
                    style: TextStyle(color: context.cAccento, fontSize: 13)),
              ),
              TextButton.icon(
                onPressed: _generaPassword,
                icon: IconaVM(Icone.dado, size: 18, color: context.cAccento),
                label: Text('Genera password',
                    style: TextStyle(color: context.cAccento, fontSize: 13)),
              ),
            ],
          ),

          const SizedBox(height: 16),
          _blocco2FA(context),

          const SizedBox(height: 20),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tag (separati da virgola)',
              helperText: 'Servono alla ricerca, non al raggruppamento',
            ),
          ),
          const SizedBox(height: 20),

          DropdownButtonFormField<String>(
            initialValue: categorie.contains(_categoria) ? _categoria : '',
            decoration: const InputDecoration(labelText: 'Categoria'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Nessuna categoria')),
              for (final c in categorie)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() => _categoria = v ?? ''),
          ),
          if (categorie.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Nessuna categoria ancora: si creano nella sezione Categorie.',
                style: TextStyle(fontSize: 11.5, color: context.cTenue),
              ),
            ),

          const SizedBox(height: 12),
          RigaInterruttore(
            acceso: _critica,
            onChanged: (v) => setState(() => _critica = v),
            icona: const IconaVM(Icone.avviso, size: 20),
            titolo: 'Voce critica',
            descrizione:
                'Account da cui si rimette le mani su tutto il resto: banca, email principale.',
          ),

          if (_critica && _duefattoriInsieme) _avviso2FA(context),

          if (_errore != null) ...[
            const SizedBox(height: 16),
            Text(_errore!,
                style: TextStyle(color: context.cErrore, fontSize: 13)),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _occupato ? null : _salva,
              style: FilledButton.styleFrom(
                backgroundColor: context.cAccento,
                foregroundColor: context.cSuAccento,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              child: _occupato
                  // Niente const: il colore viene dal tema, e in Flutter un
                  // const non può leggere il context.
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.cSuAccento))
                  : Text(_nuova ? 'Aggiungi al vault' : 'Salva le modifiche',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rigaCampo(int i) {
    final c = _campi[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: c.label.text),
              optionsBuilder: (t) => t.text.isEmpty
                  ? _etichetteComuni
                  : _etichetteComuni.where((e) =>
                      e.toLowerCase().contains(t.text.toLowerCase())),
              onSelected: (v) => setState(() => c.label.text = v),
              fieldViewBuilder: (context, controller, focus, _) {
                // Il controller lo gestisce Autocomplete: si tiene allineato
                // quello vero della riga a ogni battuta.
                controller.addListener(() => c.label.text = controller.text);
                return TextField(
                  controller: controller,
                  focusNode: focus,
                  decoration: const InputDecoration(
                      labelText: 'Etichetta', isDense: true),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: c.value,
              decoration: const InputDecoration(labelText: 'Valore', isDense: true),
              maxLines: null,
            ),
          ),
          IconButton(
            iconSize: 18,
            tooltip: 'Togli il campo',
            icon: IconaVM(Icone.chiudi, color: context.cTenue),
            onPressed: () => _togliCampo(i),
          ),
        ],
      ),
    );
  }

  /// Il blocco della 2FA: un invito quando non c'è, la conferma quando c'è.
  ///
  /// **La conferma è la parte importante.** Subito dopo aver inquadrato un QR
  /// l'unica domanda è «ho letto la cosa giusta?», e l'unico modo di
  /// rispondere è vedere il codice che scorre: se corrisponde a quello che il
  /// sito chiede di confermare, il secret è quello. Senza, si salva un segreto
  /// di cui si scopre fra un mese che non funziona.
  Widget _blocco2FA(BuildContext context) {
    final secret = _secretOtp;

    if (secret == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _aggiungi2FA,
          icon: IconaVM(Icone.qr, size: 18, color: context.cAccento),
          label: Text('Aggiungi la 2FA',
              style: TextStyle(color: context.cAccento, fontSize: 13)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.cAccento.withValues(alpha: 0.55)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
        ),
      );
    }

    CodiceOtp? codice;
    try {
      codice = generaOtp(secret);
    } catch (_) {
      codice = null;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: context.cFondo,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.cBordo),
      ),
      child: Row(
        children: [
          IconaVM(Icone.qr, size: 20, color: context.cTenue),
          const SizedBox(width: 12),
          Expanded(
            child: codice == null
                ? Text(
                    'Il secret 2FA salvato non è base32: nessun codice si può '
                    'calcolare da questo.',
                    style: TextStyle(fontSize: 12, color: context.cErrore, height: 1.4),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${codice.code.substring(0, 3)} ${codice.code.substring(3)}',
                        style: TextStyle(
                          fontSize: 21,
                          letterSpacing: 3,
                          fontFamily: 'JetBrains Mono',
                          color: context.cVerde,
                        ),
                      ),
                      Text(
                        'Cambia fra ${codice.remaining}s — deve corrispondere a '
                        'quello che il sito chiede di confermare',
                        style: TextStyle(
                            fontSize: 11, color: context.cTenue, height: 1.4),
                      ),
                    ],
                  ),
          ),
          TextButton(
            onPressed: _aggiungi2FA,
            child: Text('Sostituisci',
                style: TextStyle(fontSize: 12, color: context.cAccento)),
          ),
        ],
      ),
    );
  }

  Widget _avviso2FA(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.cAccento.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.cAccento.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconaVM(Icone.info, size: 18, color: context.cAccento),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Password e secret 2FA sono nella stessa voce: chi apre il vault '
                'ha entrambi, e il secondo fattore smette di essere separato. '
                'Su una voce critica vale la pena saperlo — non impedisce di salvare.',
                style: TextStyle(fontSize: 11.5, color: context.cTesto, height: 1.45),
              ),
            ),
          ],
        ),
      );
}
