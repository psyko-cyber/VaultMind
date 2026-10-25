/// Un vault che nasce sul telefono, senza un PC.
///
/// Fino al 16/09/2026 un vault nasceva solo sul PC: il telefono sapeva
/// riceverlo (dalla rete, da un file di backup) ma non crearlo. Luca ha dato l'APK a un
/// amico, e l'amico si è fermato alla prima schermata — senza un PC l'app non
/// serviva a niente.
///
/// ## È lo stesso vault del PC
///
/// Non c'è un formato "da telefono": salt di 16 byte, Argon2id coi parametri
/// di sempre, AES-256-GCM — quello che fa `crypto_store.create()`.
///
/// ## Col PC
///
/// Dal 25/10/2026 un vault nato qui si collega al PC col QR, e al primo sync
/// le voci dei due si uniscono (`merge.py`, «Due vault diversi»): le master
/// password possono anche essere diverse, ognuno tiene la sua. È anche la
/// strada di chi il PC ce l'ha già ([SchermataNuovoVault.collegaPc]): si crea
/// qui, poi si inquadra il QR.
///
/// Come sul PC, la password si scrive due volte: un refuso qui renderebbe il
/// vault inapribile, e non esiste un modo di recuperarlo.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../archivio.dart';
import '../icone.dart';
import '../sessione.dart';
import '../tema.dart';
import '../vault.dart';
import 'casa.dart';
import 'dialoghi.dart';

class SchermataNuovoVault extends StatefulWidget {
  /// Dopo la creazione, apri subito il collegamento col PC.
  final bool collegaPc;

  const SchermataNuovoVault({super.key, this.collegaPc = false});

  @override
  State<SchermataNuovoVault> createState() => _SchermataNuovoVaultState();
}

class _SchermataNuovoVaultState extends State<SchermataNuovoVault> {
  final _password = TextEditingController();
  final _conferma = TextEditingController();
  bool _occupato = false;
  String? _errore;

  @override
  void dispose() {
    _password.dispose();
    _conferma.dispose();
    super.dispose();
  }

  Future<void> _crea() async {
    final master = _password.text;
    if (master.runes.length < kMasterMinima) {
      setState(() => _errore =
          'Almeno $kMasterMinima caratteri: è l\'unica chiave del vault.');
      return;
    }
    if (master != _conferma.text) {
      setState(() => _errore = 'Le due password non coincidono.');
      return;
    }

    setState(() {
      _occupato = true;
      _errore = null;
    });
    try {
      // Controllo prima di Argon2, che costa quasi un secondo: se il vault
      // c'è già non serve farlo aspettare. creaVault() lo ricontrolla comunque.
      if (await esisteVault()) {
        setState(() => _errore = 'Su questo telefono c\'è già un vault: '
            'torna indietro e sbloccalo.');
        return;
      }
      final nuovo = await nuovoVault(master);
      await creaVault(await cifraVault(nuovo.vault, nuovo.chiave));
      _password.clear();
      _conferma.clear();
      if (!mounted) return;
      await proponiImpronta(context, nuovo.chiave);
      if (!mounted) return;
      // Via tutto quello che c'era sotto: tornare indietro dalla casa verso
      // una schermata che dice "non c'è ancora nessun vault" sarebbe falso.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => SchermataCasa(
                sessione: Sessione(nuovo.vault, nuovo.chiave),
                collegaPc: widget.collegaPc)),
        (_) => false,
      );
    } on FormatException catch (e) {
      setState(() => _errore = e.message);
    } catch (e) {
      setState(() => _errore = 'Non è stato possibile creare il vault.');
    } finally {
      if (mounted) setState(() => _occupato = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tenue = TextStyle(fontSize: 12.5, color: context.cTenue, height: 1.55);
    return Scaffold(
      appBar: AppBar(title: const Text('Crea un vault nuovo')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Scegli la master password. Da lei si ricava la chiave che '
                'cifra il vault: non viene salvata da nessuna parte e non '
                'lascia il telefono.',
                style: tenue,
              ),
              const SizedBox(height: 22),
              TextField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                enabled: !_occupato,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Master password',
                  hintText: 'almeno $kMasterMinima caratteri',
                  prefixIcon: IconaVM(Icone.lucchetto, color: context.cTenue),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _conferma,
                obscureText: true,
                enabled: !_occupato,
                onSubmitted: (_) => _crea(),
                decoration: InputDecoration(
                  labelText: 'Riscrivila',
                  prefixIcon: IconaVM(Icone.lucchetto, color: context.cTenue),
                ),
              ),
              const SizedBox(height: 16),
              Text.rich(
                TextSpan(children: [
                  const TextSpan(
                      text: 'Se la dimentichi, il vault non si recupera: ',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const TextSpan(
                      text: 'nessuno, nemmeno chi ha scritto l\'app, può aprirlo '
                          'al posto tuo.'),
                ]),
                style: TextStyle(fontSize: 12.5, color: context.cErrore, height: 1.55),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _occupato ? null : _crea,
                style: FilledButton.styleFrom(
                  backgroundColor: context.cAccento,
                  foregroundColor: context.cSuAccento,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                child: _occupato
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: context.cAccento))
                    : const Text('Crea il vault',
                        style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (_errore != null) ...[
                const SizedBox(height: 16),
                Text(_errore!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: context.cErrore, fontSize: 13, height: 1.5)),
              ],
              // Il rischio che solo la versione browser ha: il vault sta nella
              // memoria dell'icona sulla Home. Detto qui, prima di metterci
              // dentro la prima password, e non dopo averla persa.
              if (kIsWeb) ...[
                const SizedBox(height: 22),
                Text(
                  'Il vault resterà dentro VaultMind sulla schermata Home: se '
                  'togli l\'icona, se ne va con lei. Quando hai inserito le '
                  'prime voci, salva un backup da Impostazioni.',
                  style: TextStyle(fontSize: 12.5, color: context.cErrore, height: 1.55),
                ),
              ],
              const SizedBox(height: 28),
              // Nel browser il sync non c'è: col PC resta il backup.
              Text(
                kIsWeb
                    ? 'Se un giorno usi VaultMind anche sul PC: Impostazioni › '
                        '«Salva un backup» qui, e sul PC «Ripristina da backup».'
                    : widget.collegaPc
                        ? 'Appena creato, si apre la fotocamera: inquadra il QR '
                            'che mostra il PC in Sincronizza › «Collega un '
                            'telefono». Le voci del PC arrivano da sole.'
                        : 'Hai VaultMind anche su un PC? Dopo, collegali da '
                            'Impostazioni › Sincronizza: le voci dei due si '
                            'uniscono.',
                style: tenue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
