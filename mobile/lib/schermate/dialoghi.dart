/// Finestre di conferma condivise fra più schermate.
library;

import 'package:flutter/material.dart';

import '../tema.dart';

/// Chiede conferma prima di sostituire il vault del telefono con un backup.
///
/// Serve da quando il telefono **scrive**: prima un import poteva solo
/// rimpiazzare una copia di sola consultazione, adesso può cancellare
/// categorie assegnate e voci aggiunte qui. Finché il sync non esiste
/// (TODO §2) è l'unico modo in cui si perde davvero del lavoro, e un avviso
/// costa un tocco.
Future<bool?> confermaSovrascrittura(BuildContext context) => showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: c.cPannello,
        title: const Text('Sostituire il vault di questo telefono?'),
        content: const Text(
          'Il vault qui è stato modificato dopo l\'ultimo import: voci o '
          'categorie che hai sistemato sul telefono e che sul PC non ci sono.\n\n'
          'Importando questo backup vengono sostituite. Una copia di quello '
          'attuale viene comunque conservata sul telefono.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Annulla', style: TextStyle(color: c.cTenue)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
                backgroundColor: c.cErrore, foregroundColor: Colors.white),
            child: const Text('Sostituisci'),
          ),
        ],
      ),
    );

/// Conferma per un'azione che distrugge qualcosa. [dettaglio] spiega cosa
/// succede davvero, non "sei sicuro?".
Future<bool?> confermaDistruttiva(
  BuildContext context, {
  required String titolo,
  required String dettaglio,
  String conferma = 'Elimina',
}) =>
    showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: c.cPannello,
        title: Text(titolo),
        content: Text(dettaglio, style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Annulla', style: TextStyle(color: c.cTenue)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
                backgroundColor: c.cErrore, foregroundColor: Colors.white),
            child: Text(conferma),
          ),
        ],
      ),
    );
