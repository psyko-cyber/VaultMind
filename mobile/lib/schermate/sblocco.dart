/// Sblocco del vault, e import del backup quando non c'è ancora.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../archivio.dart';
import '../tema.dart';
import '../ponte_file.dart';
import '../vault.dart';
import 'elenco.dart';

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
      final vault = await apriVaultConChiave(contenuto, base64.decode(chiaveBase64));
      if (!mounted) return;
      _vaiAllElenco(vault);
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

  void _vaiAllElenco(Vault vault) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => SchermataElenco(vault: vault)),
    );
  }

  /// Dopo uno sblocco riuscito propone l'impronta, una volta sola: è il solo
  /// momento in cui la chiave è disponibile per essere messa al sicuro.
  Future<void> _proponiImpronta(String contenuto, String master) async {
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
                backgroundColor: context.cAccento, foregroundColor: const Color(0xFF141414)),
            child: const Text('Attiva'),
          ),
        ],
      ),
    );
    if (vuole != true) return;
    try {
      final chiave = await chiaveDelVault(contenuto, master);
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
      final vault = await apriVault(contenuto, master);
      if (!mounted) return;
      await _proponiImpronta(contenuto, master);
      if (!mounted) return;
      // La password esce dalla memoria appena non serve più. Resta comunque
      // in RAM finché il campo di testo vive, ma non la si tiene un istante
      // più del necessario.
      _password.clear();
      _vaiAllElenco(vault);
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
                        Icon(Icons.shield, size: 88, color: context.cAccento)),
                const SizedBox(height: 18),
                const Text('VAULTMIND',
                    style: TextStyle(
                        fontSize: 26, letterSpacing: 6, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('LOCALE · OFFLINE · AES-256',
                    style: TextStyle(fontSize: 11, letterSpacing: 2, color: context.cTenue)),
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
            prefixIcon: Icon(Icons.lock_outline, color: context.cTenue),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _occupato ? null : _sblocca,
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccento,
              foregroundColor: const Color(0xFF141414),
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            child: _occupato
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF141414)))
                : const Text('Sblocca vault',
                    style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        if (_impronta) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _occupato ? null : _sbloccaConImpronta,
            icon: Icon(Icons.fingerprint, color: context.cAccento),
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

  List<Widget> _invitoImport() => [
        const Text(
          'Su questo telefono non c\'è ancora nessun vault.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 10),
        Text(
          'Dal PC premi 💾 per salvare un backup, mandatelo (anche su WhatsApp: '
          'è cifrato, chi lo intercetta non ci fa niente) e aprilo qui.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.55),
        ),
        const SizedBox(height: 26),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _importa,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Scegli il file di backup',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: context.cAccento,
              foregroundColor: const Color(0xFF141414),
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
      ];
}
