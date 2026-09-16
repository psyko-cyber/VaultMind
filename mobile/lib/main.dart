/// VaultMind per Android e, dal 16/09/2026, per il browser: è la versione per
/// iPhone, installata dalla schermata Home (vedi `schermate/installa.dart`).
///
/// Dal 04/08/2026 il telefono **scrive** nel vault: voci, categorie, tutto.
/// Fino a quel giorno era in sola lettura, per non creare due versioni
/// divergenti della stessa voce senza avere il motore per riconciliarle.
///
/// La divergenza resta possibile e non è ancora risolta — è il sync (TODO §2).
/// Nel frattempo la si rende almeno visibile: reimportare un backup dal PC
/// avvisa se qui è stato modificato qualcosa, invece di sovrascriverlo in
/// silenzio.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'archivio.dart';
import 'impostazioni.dart';
import 'ponte_file.dart';
import 'schermate/installa.dart';
import 'schermate/sblocco.dart';
import 'tema.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await caricaImpostazioni();
  runApp(const AppVaultMind());
}

class AppVaultMind extends StatelessWidget {
  const AppVaultMind({super.key});

  @override
  Widget build(BuildContext context) {
    // Si riascolta a ogni cambio di tema: l'intera app si ridipinge, comprese
    // le schermate già aperte.
    return ValueListenableBuilder<Impostazioni>(
      valueListenable: impostazioni,
      builder: (_, imp, _) {
        final dati = temaDati(imp.tema);
        // Barra di sistema in tinta col tema: una striscia di colore diverso
        // in cima tradisce subito che l'app non è "sua".
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              dati.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: dati.colorScheme.surface,
          systemNavigationBarIconBrightness:
              dati.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
        ));
        return MaterialApp(
          title: 'VaultMind',
          debugShowCheckedModeBanner: false,
          theme: dati,
          home: const _Avvio(),
        );
      },
    );
  }
}

/// Decide cosa mostrare al primo fotogramma: se un vault non c'è ancora, la
/// schermata di sblocco propone l'import invece di chiedere una password che
/// non aprirebbe nulla.
class _Avvio extends StatefulWidget {
  const _Avvio();

  @override
  State<_Avvio> createState() => _AvvioState();
}

class _AvvioState extends State<_Avvio> {
  bool? _esiste;

  /// In Safari senza icona sulla Home si chiede prima di installare. Si può
  /// proseguire lo stesso, ma dev'essere una scelta: vedi `installa.dart`.
  bool _restaNelBrowser = false;

  @override
  void initState() {
    super.initState();
    chiediMemoriaPersistente();
    esisteVault().then((v) {
      if (mounted) setState(() => _esiste = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_esiste == null) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator(color: context.cAccento)),
      );
    }
    if (browserIos() && !installataSullaHome() && !_restaNelBrowser) {
      return SchermataInstalla(
          onProsegui: () => setState(() => _restaNelBrowser = true));
    }
    return SchermataSblocco(vaultPresente: _esiste!);
  }
}
