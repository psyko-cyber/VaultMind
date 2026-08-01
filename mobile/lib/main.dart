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
import 'schermate/sblocco.dart';

void main() => runApp(const AppVaultMind());

/// Palette "Notte e oro", la stessa dell'app Windows.
const coloreFondo = Color(0xFF070C1A);
const colorePannello = Color(0xFF0E1730);
const coloreBordo = Color(0xFF1E2C4C);
const coloreAccento = Color(0xFFE3B341);
const coloreTesto = Color(0xFFE8ECF6);
const coloreTenue = Color(0xFF8FA0C0);

class AppVaultMind extends StatelessWidget {
  const AppVaultMind({super.key});

  @override
  Widget build(BuildContext context) {
    // Barra di sistema in tinta: una striscia chiara in cima romperebbe il
    // tema scuro su cui è costruita tutta l'app.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: coloreFondo,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    return MaterialApp(
      title: 'VaultMind',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: coloreFondo,
        colorScheme: const ColorScheme.dark(
          primary: coloreAccento,
          surface: colorePannello,
          onSurface: coloreTesto,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colorePannello,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: coloreBordo),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: coloreBordo),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: coloreAccento),
          ),
        ),
      ),
      home: const _Avvio(),
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: coloreAccento)),
      );
    }
    return SchermataSblocco(vaultPresente: _esiste!);
  }
}
