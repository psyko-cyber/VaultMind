/// VaultMind per Android — v1: si consulta, non si modifica.
///
/// Perché sola lettura: se il telefono potesse anche modificare, due
/// dispositivi produrrebbero versioni diverse della stessa voce, cioè il
/// problema difficile del sync (TODO §3), senza avere ancora il motore per
/// risolverlo. Meglio un vault che sul telefono si consulta e basta, finché
/// la sincronizzazione non esiste davvero.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'archivio.dart';
import 'impostazioni.dart';
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

  @override
  void initState() {
    super.initState();
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
    return SchermataSblocco(vaultPresente: _esiste!);
  }
}
