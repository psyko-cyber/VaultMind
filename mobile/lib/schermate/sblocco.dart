/// Sblocco del vault e, quando non c'è ancora, le tre strade per averne uno:
/// crearlo, riceverlo dal PC, importare un backup.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../archivio.dart';
import '../sessione.dart';
import '../tema.dart';
import '../ponte_file.dart';
import '../vault.dart';
import 'casa.dart';
import 'dialoghi.dart';
import 'nuovo_vault.dart';
import 'travaso.dart';
import '../icone.dart';

class SchermataSblocco extends StatefulWidget {
  final bool vaultPresente;
  const SchermataSblocco({super.key, required this.vaultPresente});

  @override
  State<SchermataSblocco> createState() => _SchermataSbloccoState();
}

class _SchermataSbloccoState extends State<SchermataSblocco> {
  final _password = TextEditingController();
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
    super.dispose();
  }

  Future<void> _controllaImpronta() async {
    // Il pulsante compare solo se l'impronta è stata davvero attivata: farlo
    // vedere e poi dire "non è attivo" sarebbe una promessa non mantenuta.
    final attiva = await improntaAttiva();
    if (mounted && attiva && _presente) {
      setState(() => _impronta = true);
      _sbloccaConImpronta(); // si prova subito: è il gesto che ci si aspetta
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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset('assets/logo.png', width: 96, height: 96,
                      errorBuilder: (_, _, _) =>
                          IconaVM(Icone.scudo, size: 88, color: context.cAccento)),
                ),
                const SizedBox(height: 18),
                const Text('VAULTMIND',
                    style: TextStyle(
                        fontFamily: 'Space Grotesk',
                        fontSize: 26,
                        letterSpacing: 6,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('LOCALE · OFFLINE · AES-256',
                    style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 11,
                        letterSpacing: 2,
                        color: context.cTenue)),
                const SizedBox(height: 34),
                if (_presente) ..._formSblocco() else ..._invitoImport(),
                if (_errore != null) ...[
                  const SizedBox(height: 16),
                  Text(_errore!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFE36868), fontSize: 13)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _formSblocco() => [
        TextField(
          controller: _password,
          obscureText: true,
          autofocus: true,
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
                // const non può leggere il context.
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: context.cSuAccento))
                : const Text('Sblocca vault',
                    style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        if (_impronta) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _occupato ? null : _sbloccaConImpronta,
            icon: IconaVM(Icone.impronta, color: context.cAccento),
            label: Text('Sblocca con l\'impronta',
                style: TextStyle(color: context.cAccento)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.cBordo),
              padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
            ),
          ),
        ],
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
  /// Le due strade dal PC stanno sotto una domanda che le separa, perché
  /// premere «Crea» avendo già un PC fa nascere un secondo vault che col primo
  /// non si sincronizza. Fra le due il travaso viene prima del file, non per
  /// gusto: passare da WhatsApp funziona ma è un passaggio da spiegare, e ogni
  /// passaggio da spiegare è qualcuno che si ferma. Il file resta perché fuori
  /// casa è l'unica strada: il salt arriva dalla scoperta, che è in broadcast e
  /// in una VPN non passa.
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
          // Nel browser il travaso via rete non c'è (`sync_rete_web.dart`):
          // resta il file, e il testo dice dove prenderlo sul PC.
          kIsWeb
              ? 'Sul PC apri il menu › «Backup del vault», manda il file a '
                  'questo telefono e sceglilo qui sotto.'
              : 'Se il PC è acceso sulla stessa WiFi, il vault arriva da lì: '
                  'niente file da mandarsi.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.55),
        ),
        const SizedBox(height: 14),
        if (!kIsWeb) ...[
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SchermataTravaso())),
            icon: IconaVM(Icone.rete, color: context.cAccento),
            label: Text('Ricevi il vault dal PC',
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
