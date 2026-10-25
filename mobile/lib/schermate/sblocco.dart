/// Sblocco del vault e, quando non c'è ancora, le tre strade per averne uno:
/// crearlo, riceverlo dal PC, importare un backup.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../archivio.dart';
import '../impostazioni.dart';
import '../sessione.dart';
import '../sfondo.dart';
import '../tema.dart';
import '../ponte_file.dart';
import '../vault.dart';
import 'casa.dart';
import 'dialoghi.dart';
import 'nuovo_vault.dart';
import '../icone.dart';

class SchermataSblocco extends StatefulWidget {
  final bool vaultPresente;
  const SchermataSblocco({super.key, required this.vaultPresente});

  @override
  State<SchermataSblocco> createState() => _SchermataSbloccoState();
}

class _SchermataSbloccoState extends State<SchermataSblocco> {
  final _password = TextEditingController();
  final _fuoco = FocusNode();
  late bool _presente = widget.vaultPresente;
  bool _occupato = false;
  String? _errore;
  bool _impronta = false;

  @override
  void initState() {
    super.initState();
    _controllaImpronta();
    // L'app può essere stata aperta proprio toccando l'allegato in chat:
    // in quel caso il backup è già qui e si importa da solo, senza che
    // l'utente debba cercare niente.
    fileDaApertura().then((c) {
      if (c != null && mounted) _salva(c);
    });
    // E può arrivarne uno mentre l'app è già aperta.
    inAscoltoDiFile((c) {
      if (mounted) _salva(c);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _fuoco.dispose();
    super.dispose();
  }

  Future<void> _controllaImpronta() async {
    // Il pulsante compare solo se l'impronta è stata davvero attivata: farlo
    // vedere e poi dire "non è attivo" sarebbe una promessa non mantenuta.
    final attiva = await improntaAttiva();
    if (!mounted || !_presente) return;
    if (attiva) {
      setState(() => _impronta = true);
      _sbloccaConImpronta(); // si prova subito: è il gesto che ci si aspetta
    } else {
      // La tastiera solo quando l'impronta non c'è: aperta subito, copriva
      // proprio il cerchio dell'impronta.
      _fuoco.requestFocus();
    }
  }

  Future<void> _sbloccaConImpronta() async {
    setState(() => _errore = null);
    try {
      final chiaveBase64 = await improntaSblocca();
      if (chiaveBase64 == null) return; // annullato
      final contenuto = await leggiVault();
      final chiave = base64.decode(chiaveBase64);
      final vault = await apriVaultConChiave(contenuto, chiave);
      if (!mounted) return;
      _vaiACasa(Sessione(vault, chiave));
    } on PlatformException catch (e) {
      setState(() => _errore = e.message ?? 'Sblocco con impronta non riuscito.');
      setState(() => _impronta = false);
    } on WrongPassword {
      // La chiave conservata non apre più questo vault: succede se è stato
      // importato un backup con una master password diversa.
      await improntaDisattiva();
      setState(() {
        _impronta = false;
        _errore = 'Questo vault ha una password diversa: sbloccalo a mano e riattiva l\'impronta.';
      });
    } catch (e) {
      setState(() => _errore = 'Sblocco con impronta non riuscito.');
    }
  }

  void _vaiACasa(Sessione sessione) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => SchermataCasa(sessione: sessione)),
    );
  }

  Future<void> _sblocca() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _occupato = true;
      _errore = null;
    });
    try {
      final contenuto = await leggiVault();
      final master = _password.text;
      // Una sola derivazione, poi si riusa: la chiave serve ad aprire, a
      // proporre l'impronta e — da quando il telefono scrive — a risalvare.
      final chiave = await chiaveDelVault(contenuto, master);
      final vault = await apriVaultConChiave(contenuto, chiave);
      if (!mounted) return;
      await proponiImpronta(context, chiave);
      if (!mounted) return;
      // La password esce dalla memoria appena non serve più. Resta comunque
      // in RAM finché il campo di testo vive, ma non la si tiene un istante
      // più del necessario.
      _password.clear();
      _vaiACasa(Sessione(vault, chiave));
    } on WrongPassword {
      setState(() => _errore = 'Master password errata.');
    } on VaultCorrupted {
      // Errore diverso perché l'azione da fare è opposta: qui riprovare la
      // password non serve a niente.
      setState(() => _errore =
          'Il file del vault è danneggiato. La password non c\'entra: importa di nuovo un backup.');
    } catch (e) {
      setState(() => _errore = 'Non è stato possibile aprire il vault.');
    } finally {
      if (mounted) setState(() => _occupato = false);
    }
  }

  Future<void> _importa() async {
    setState(() => _errore = null);
    final contenuto = await scegliFile();
    if (contenuto == null) return; // annullato: non è un errore
    await _salva(contenuto);
  }

  Future<void> _salva(String contenuto) async {
    // Da quando il telefono scrive nel vault, un backup che arriva dal PC può
    // cancellare del lavoro fatto qui — categorie assegnate, voci aggiunte.
    // È l'unico modo di perdere dati finché il sync non esiste, quindi si
    // chiede invece di sovrascrivere e basta.
    if (await modificatoInLocale()) {
      if (!mounted) return;
      final procedi = await confermaSovrascrittura(context);
      if (procedi != true) return;
    }
    try {
      await importaVault(contenuto);
      if (!mounted) return;
      setState(() {
        _presente = true;
        _errore = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Backup importato. Sbloccalo con la master password del '
            'dispositivo da cui arriva.'),
      ));
    } on FormatException catch (e) {
      setState(() => _errore = e.message);
    } catch (e) {
      setState(() => _errore = 'Import non riuscito.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.cristallo;
    // Lo sfondo sta dietro allo Scaffold per la stessa ragione della casa:
    // all'apertura della tastiera il corpo si accorcia, e il cielo, se ci
    // stesse dentro, salterebbe in alto proprio mentre si scrive.
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<Impostazioni>(
          valueListenable: impostazioni,
          builder: (context, imp, _) =>
              SfondoCristallo(tipo: imp.sfondoSblocco, posa: posaSblocco),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Solo nel browser, e solo quando serve: una versione nuova è
                    // già attiva ma questa pagina è la vecchia. Qui e non dentro
                    // il vault aperto, perché ricaricare chiude la sessione — e
                    // mai da solo, perché qualcuno potrebbe star scrivendo.
                    ValueListenableBuilder<bool>(
                      valueListenable: aggiornamentoWeb,
                      builder: (context, pronto, _) => !pronto
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 24),
                              child: OutlinedButton.icon(
                                onPressed: ricaricaApp,
                                icon: IconaVM(Icone.aggiorna,
                                    size: 18, color: context.cAccento),
                                label: Text(
                                    'È pronta una versione nuova: tocca per aggiornare',
                                    style: TextStyle(
                                        color: context.cAccento, fontSize: 13)),
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: context.cAccento)),
                              ),
                            ),
                    ),
                    // Il logo come una gemma: due aloni, uno per neon, al posto
                    // della luce che sul PC gli gira intorno. Un'ombra e non
                    // un'animazione: questa schermata è quella che si guarda di
                    // più, e deve costare poco.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                              color: k.neon1.withValues(alpha: .42),
                              blurRadius: 34,
                              spreadRadius: -6),
                          BoxShadow(
                              color: k.neon2.withValues(alpha: .20),
                              blurRadius: 60,
                              offset: const Offset(0, 10)),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset('assets/logo.png', width: 96, height: 96,
                            errorBuilder: (_, _, _) => IconaVM(Icone.scudo,
                                size: 88, color: context.cAccento)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Il nome scritto come si scrive, non in maiuscolo spaziato,
                    // e sotto una frase vera al posto della sigla tecnica.
                    const Text('VaultMind',
                        style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 32,
                            letterSpacing: 0.2,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(
                        _presente
                            ? (kIsWeb
                                ? 'Il vault è cifrato in questo browser.'
                                : 'Il vault è cifrato su questo telefono.')
                            : (kIsWeb
                                ? 'Le password restano in questo browser, cifrate.'
                                : 'Le password restano su questo telefono, cifrate.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: context.cTenue)),
                    const SizedBox(height: 30),
                    // Lo sblocco senza scheda intorno, come nella bozza: sono
                    // un campo e un pulsante, e la scheda li faceva sembrare
                    // un modulo da compilare. Le tre strade per avere un vault
                    // invece restano dentro al vetro: lì c'è da leggere.
                    if (_presente)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                            children: [..._formSblocco(), ..._erroreSotto()]),
                      )
                    else
                      _Vetro(
                        bordo: k.prisma,
                        child: Column(
                            children: [..._invitoImport(), ..._erroreSotto()]),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _erroreSotto() => [
        if (_errore != null) ...[
          const SizedBox(height: 16),
          // Dal tema: il rosso unico di prima sul Ghiaccio valeva 3,3:1.
          Text(_errore!,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.cErrore, fontSize: 13)),
        ],
      ];

  /// L'impronta per prima, la password sotto: con l'impronta attiva è il
  /// gesto di tutti i giorni, e la password diventa la riserva.
  List<Widget> _formSblocco() => [
        if (_impronta) ...[
          _CerchioImpronta(onTocco: _occupato ? null : _sbloccaConImpronta),
          const SizedBox(height: 14),
          Text("Tocca per usare l'impronta",
              style: TextStyle(fontSize: 13.5, color: context.cTesto)),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: Divider(color: context.cristallo.bordoForte)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('oppure',
                    style: TextStyle(fontSize: 12.5, color: context.cTenue)),
              ),
              Expanded(child: Divider(color: context.cristallo.bordoForte)),
            ],
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _password,
          focusNode: _fuoco,
          obscureText: true,
          enabled: !_occupato,
          onSubmitted: (_) => _sblocca(),
          decoration: InputDecoration(
            labelText: 'Master password',
            prefixIcon: IconaVM(Icone.lucchetto, color: context.cTenue),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _occupato ? null : _sblocca,
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccento,
              foregroundColor: context.cSuAccento,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            child: _occupato
                // Niente const: il colore viene dal tema, e in Flutter un
                // const non può leggere il context. Accento e non «su
                // accento»: mentre lavora il pulsante è spento, quindi grigio,
                // e un cerchio scuro lì sopra non si vedeva.
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: context.cAccento))
                : const Text('Sblocca',
                    style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Da lei si deriva la chiave del vault, e non viene salvata da nessuna '
          'parte. Se il vault arriva da un PC, è la stessa del PC.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.5),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _occupato ? null : _importa,
          icon: IconaVM(Icone.documentoSu, size: 18, color: context.cTenue),
          label: Text('Importa un altro backup',
              style: TextStyle(color: context.cTenue, fontSize: 13)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.cBordo),
            padding: const EdgeInsets.symmetric(vertical: 12),
            minimumSize: const Size.fromHeight(0),
          ),
        ),
      ];

  /// Tre strade, e l'ordine conta.
  ///
  /// **Creare** viene prima dal 16/09/2026: il telefono deve bastare da solo.
  /// Prima c'erano solo le due strade dal PC, e chi aveva ricevuto l'APK senza
  /// avere un PC si fermava qui.
  ///
  /// Le due strade dal PC stanno sotto una domanda che le separa. Dal
  /// 25/10/2026 la prima è «collegati al PC»: si crea un vault qui e si
  /// inquadra il QR del PC, e al primo sync le voci dei due si uniscono — un
  /// vault nato qui e uno nato sul PC si sincronizzano, cosa che col sync di
  /// prima non si poteva. Prima c'era il «travaso», che passava dalla
  /// scoperta in broadcast e sul PC di Luca non trovava mai niente. Il file
  /// resta per chi non ha il PC sulla stessa WiFi.
  List<Widget> _invitoImport() => [
        const Text(
          'Su questo telefono non c\'è ancora nessun vault.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SchermataNuovoVault())),
            icon: const IconaVM(Icone.piu),
            label: const Text('Crea un vault nuovo',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccento,
              foregroundColor: context.cSuAccento,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
        const SizedBox(height: 30),
        const Text(
          'Hai già VaultMind su un PC?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          // Nel browser il sync non c'è (`sync_rete_web.dart`): resta il
          // file, e il testo dice dove prenderlo sul PC.
          kIsWeb
              ? 'Sul PC apri il menu › «Backup del vault», manda il file a '
                  'questo telefono e sceglilo qui sotto.'
              : 'Crea qui un vault (anche con la stessa password del PC) e '
                  'collegalo col QR che mostra il PC: le voci arrivano da sole.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.55),
        ),
        const SizedBox(height: 14),
        if (!kIsWeb) ...[
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SchermataNuovoVault(collegaPc: true))),
            icon: IconaVM(Icone.qr, color: context.cAccento),
            label: Text('Collegati al PC',
                style: TextStyle(color: context.cAccento)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.cBordo),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _importa,
          icon: IconaVM(Icone.documentoSu, color: context.cAccento),
          label: Text('Ho un file di backup',
              style: TextStyle(color: context.cAccento)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.cBordo),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
        ),
      ];
}

/// La scheda dello sblocco: un pannello pieno dentro un filo prismatico.
///
/// Pieno e non sfocato: dietro gira la costellazione, e una sfocatura vera
/// andrebbe ricalcolata a ogni suo fotogramma. Il testo sta così su un colore
/// fermo, e il contrasto si può calcolare una volta per tutte.
class _Vetro extends StatelessWidget {
  final Gradient bordo;
  final Widget child;
  const _Vetro({required this.bordo, required this.child});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: bordo,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [
            BoxShadow(
                color: Color(0x59000000), blurRadius: 40, offset: Offset(0, 18)),
          ],
        ),
        child: Container(
          margin: const EdgeInsets.all(1.2),
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(25),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Il cerchio dell'impronta, al centro dello sblocco. Un alone fermo e non
/// il respiro della bozza: questa schermata è quella che si guarda di più,
/// e un'animazione continua qui costerebbe batteria a ogni sblocco.
class _CerchioImpronta extends StatelessWidget {
  final VoidCallback? onTocco;
  const _CerchioImpronta({required this.onTocco});

  @override
  Widget build(BuildContext context) {
    final n = context.cristallo.neon2;
    return Semantics(
      button: true,
      label: "Sblocca con l'impronta",
      excludeSemantics: true,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: context.cPannello,
          border: Border.all(color: n.withValues(alpha: .55)),
          boxShadow: [
            BoxShadow(color: n.withValues(alpha: .08), spreadRadius: 6),
            BoxShadow(
                color: n.withValues(alpha: .5), blurRadius: 40, spreadRadius: -6),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTocco,
            child: Center(child: IconaVM(Icone.impronta, size: 38, color: n)),
          ),
        ),
      ),
    );
  }
}
