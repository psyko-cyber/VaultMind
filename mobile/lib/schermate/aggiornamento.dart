/// «C'è la versione nuova»: la domanda, il download, l'installer di Android.
///
/// Tre regole, e sono tutte e tre il motivo per cui questo file esiste invece
/// di una riga nelle Impostazioni:
///
/// 1. **Si chiede, non si fa.** Un gestore di password che si aggiorna da solo
///    mentre guardi una credenziale è l'ultima cosa che vuoi vedere.
/// 2. **«Più tardi» vale 20 ore**, non dieci minuti: altrimenti chi l'ha detto
///    se lo sente richiedere al prossimo sblocco.
/// 3. **Niente può restare in mezzo.** Se il download non riesce, la via a mano
///    (la pagina delle release) è sempre a un tocco: è la stessa logica del
///    «Apri con» per i backup — una strada che funziona anche quando quella
///    comoda non funziona.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../aggiornamenti.dart';
import '../ponte_file.dart';
import '../tema.dart';
import '../versione.dart';

/// Propone la [novita]. Con [chiedi] falso scarica subito (si arriva già da un
/// pulsante toccato in Impostazioni: chiedere due volte la stessa cosa).
Future<void> offriAggiornamento(BuildContext context, Novita novita,
    {bool chiedi = true}) async {
  if (chiedi) {
    final note = notePulite(novita.note);
    final vai = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('VaultMind ${novita.versione}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Hai la $versioneApp. Si installa sopra quella attuale: '
                'il vault, le impostazioni e i dispositivi abbinati restano dove sono.',
                style: const TextStyle(height: 1.5),
              ),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(note,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.45, color: context.cTenue)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Più tardi', style: TextStyle(color: context.cTenue)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(novita.scaricabile ? 'Aggiorna' : 'Apri la pagina',
                style: TextStyle(color: context.cAccento)),
          ),
        ],
      ),
    );
    if (vai != true) {
      await rinvia(novita);
      avvisoAggiornamento.value = null;
      return;
    }
  }
  if (!context.mounted) return;
  // Release senza APK allegato (o senza SHA256SUMS.txt): si manda alla pagina
  // invece di fingere che un pulsante possa funzionare.
  if (!novita.scaricabile) {
    await apriNelBrowser(novita.pagina);
    return;
  }
  await _scaricaEInstalla(context, novita);
}

Future<void> _scaricaEInstalla(BuildContext context, Novita novita) async {
  final avanzamento = ValueNotifier<double>(0);
  var annullato = false;
  final navigatore = Navigator.of(context, rootNavigator: true);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      // Niente uscita col tasto indietro: il download sta scrivendo un file, e
      // "Annulla" lo ferma per davvero (cancellando quello che c'era).
      canPop: false,
      child: AlertDialog(
        title: Text('Scarico la ${novita.versione}'),
        content: ValueListenableBuilder<double>(
          valueListenable: avanzamento,
          builder: (c2, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Senza Content-Length la barra gira senza percentuale: dire
              // "0%" quando non lo sappiamo sarebbe una bugia piccola e
              // fastidiosa.
              LinearProgressIndicator(
                  value: v > 0 ? v : null, color: c2.cAccento),
              const SizedBox(height: 12),
              Text(v > 0 ? '${(v * 100).round()}%' : 'Avvio del download…',
                  style: TextStyle(fontSize: 12.5, color: c2.cTenue)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => annullato = true,
            child: Text('Annulla', style: TextStyle(color: c.cTenue)),
          ),
        ],
      ),
    ),
  );

  String? percorso;
  String? errore;
  try {
    percorso = await scarica(
      novita,
      suProgresso: (v) => avanzamento.value = v,
      annullato: () => annullato,
    );
  } on FormatException catch (e) {
    errore = e.message;
  } catch (_) {
    errore = 'Download non riuscito: controlla la connessione.';
  } finally {
    avanzamento.dispose();
  }
  navigatore.pop();
  if (annullato || !context.mounted) return;

  if (percorso != null) {
    try {
      await installa(percorso);
      return;   // da qui parla Android: la sua schermata chiede conferma
    } on PlatformException catch (e) {
      // Il caso vero: «installa app sconosciute» negato per VaultMind. Il
      // messaggio dice cosa è successo, non cosa ci aspettavamo.
      errore = 'Android non ha aperto l\'installazione'
          '${e.message == null ? '' : ' (${e.message})'}. '
          'Puoi installare l\'APK a mano dalla pagina delle release.';
    }
  }

  if (!context.mounted) return;
  final apri = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Aggiornamento non riuscito'),
      content: Text(errore ?? 'Qualcosa non è andato.',
          style: const TextStyle(height: 1.5)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: Text('Chiudi', style: TextStyle(color: context.cTenue)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child:
              Text('Apri la pagina', style: TextStyle(color: context.cAccento)),
        ),
      ],
    ),
  );
  if (apri == true) await apriNelBrowser(novita.pagina);
}
