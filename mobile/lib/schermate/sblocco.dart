/// Sblocco del vault, e import del backup quando non c'è ancora.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../archivio.dart';
import '../sessione.dart';
import '../tema.dart';
import '../ponte_file.dart';
import '../vault.dart';
import 'casa.dart';
import 'dialoghi.dart';
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

  /// Dopo uno sblocco riuscito propone l'impronta, una volta sola: è il solo
  /// momento in cui la chiave è disponibile per essere messa al sicuro.
  ///
  /// Riceve la chiave già derivata. Prima se la ri-derivava da sé, e questa
  /// schermata faceva Argon2 **due volte** a ogni sblocco: coi parametri veri
  /// (64 MB, time cost 3) è quasi un secondo di attesa regalato.
  Future<void> _proponiImpronta(Uint8List chiave) async {
    if (!await impresaDisponibile() || await improntaAttiva()) return;
    if (!mounted) return;
    final vuole = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: context.cPannello,
        title: const Text('Sbloccare con l\'impronta?'),
        content: const Text(
          'La prossima volta ti basterà il dito, senza riscrivere la master password.\n\n'
          'La password non viene salvata: viene messa al sicuro la chiave del vault, '
          'e il telefono la restituisce solo dopo aver riconosciuto la tua impronta.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('No, grazie', style: TextStyle(color: context.cTenue)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
                backgroundColor: context.cAccento, foregroundColor: context.cSuAccento),
            child: const Text('Attiva'),
          ),
        ],
      ),
    );
    if (vuole != true) return;
    try {
      await improntaAttivaConChiave(base64.encode(chiave));
    } catch (e) {
      // Se non riesce non è grave: si continua con la master password.
    }
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
      await _proponiImpronta(chiave);
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
        content: Text('Backup importato. Sbloccalo con la master password del PC.'),
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
                Image.asset('assets/logo.png', width: 96, height: 96,
                    errorBuilder: (_, _, _) =>
                        IconaVM(Icone.scudo, size: 88, color: context.cAccento)),
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
          'La master password è la stessa del PC: da lei si deriva la chiave, '
          'e non viene salvata da nessuna parte.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: context.cTenue, height: 1.5),
        ),
        const SizedBox(height: 18),
        TextButton(
          onPressed: _occupato ? null : _importa,
          child: Text('Importa un altro backup',
              style: TextStyle(color: context.cTenue, fontSize: 12.5)),
        ),
      ];

  /// Il travaso via rete è il primo pulsante e il file è il secondo, non per
  /// gusto: passare da WhatsApp funziona ma è un passaggio da spiegare, e
  /// ogni passaggio da spiegare è qualcuno che si ferma. Il file resta perché
  /// fuori casa è l'unica strada: il salt arriva dalla scoperta, che è in
  /// broadcast e in una VPN non passa.
  List<Widget> _invitoImport() => [
        const Text(
          'Su questo telefono non c\'è ancora nessun vault.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 10),
        Text(
          'Se il PC è acceso sulla stessa WiFi, il vault arriva da lì: '
          'niente file da mandarsi.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.55),
        ),
        const SizedBox(height: 26),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SchermataTravaso())),
            icon: const IconaVM(Icone.rete),
            label: const Text('Ricevi il vault dal PC',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccento,
              foregroundColor: context.cSuAccento,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _importa,
          icon: IconaVM(Icone.documento, color: context.cAccento),
          label: Text('Ho un file di backup',
              style: TextStyle(color: context.cAccento)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.cBordo),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
        ),
      ];
}
