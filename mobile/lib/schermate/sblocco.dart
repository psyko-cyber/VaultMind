/// Sblocco del vault, e import del backup quando non c'è ancora.
library;

import 'package:flutter/material.dart';

import '../archivio.dart';
import '../main.dart';
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

  @override
  void initState() {
    super.initState();
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

  Future<void> _sblocca() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _occupato = true;
      _errore = null;
    });
    try {
      final contenuto = await leggiVault();
      final vault = await apriVault(contenuto, _password.text);
      if (!mounted) return;
      // La password esce dalla memoria appena non serve più. Resta comunque
      // in RAM finché il campo di testo vive, ma non la si tiene un istante
      // più del necessario.
      _password.clear();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => SchermataElenco(vault: vault)),
      );
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
                        const Icon(Icons.shield, size: 88, color: coloreAccento)),
                const SizedBox(height: 18),
                const Text('VAULTMIND',
                    style: TextStyle(
                        fontSize: 26, letterSpacing: 6, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text('LOCALE · OFFLINE · AES-256',
                    style: TextStyle(fontSize: 11, letterSpacing: 2, color: coloreTenue)),
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
          decoration: const InputDecoration(
            labelText: 'Master password',
            prefixIcon: Icon(Icons.lock_outline, color: coloreTenue),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _occupato ? null : _sblocca,
            style: FilledButton.styleFrom(
              backgroundColor: coloreAccento,
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
        const SizedBox(height: 14),
        const Text(
          'La master password è la stessa del PC: da lei si deriva la chiave, '
          'e non viene salvata da nessuna parte.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: coloreTenue, height: 1.5),
        ),
        const SizedBox(height: 18),
        TextButton(
          onPressed: _occupato ? null : _importa,
          child: const Text('Importa un altro backup',
              style: TextStyle(color: coloreTenue, fontSize: 12.5)),
        ),
      ];

  List<Widget> _invitoImport() => [
        const Text(
          'Su questo telefono non c\'è ancora nessun vault.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 10),
        const Text(
          'Dal PC premi 💾 per salvare un backup, mandatelo (anche su WhatsApp: '
          'è cifrato, chi lo intercetta non ci fa niente) e aprilo qui.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: coloreTenue, height: 1.55),
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
              backgroundColor: coloreAccento,
              foregroundColor: const Color(0xFF141414),
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
          ),
        ),
      ];
}
