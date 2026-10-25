/// Finestre di conferma condivise fra più schermate.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ponte_file.dart';
import '../tema.dart';

/// Propone l'impronta, una volta sola, subito dopo che la chiave è stata
/// ricavata: è il solo momento in cui c'è, e quindi il solo in cui la si può
/// mettere al sicuro nel Keystore.
///
/// Riceve la chiave già derivata. Prima lo sblocco se la ri-derivava da sé, e
/// faceva Argon2 **due volte**: coi parametri veri (64 MB, time cost 3) è quasi
/// un secondo di attesa regalato.
///
/// Sta qui e non nella schermata di sblocco da quando il vault può nascere sul
/// telefono: chi lo crea deve ricevere la stessa proposta di chi lo sblocca.
Future<void> proponiImpronta(BuildContext context, Uint8List chiave) async {
  if (!await impresaDisponibile() || await improntaAttiva()) return;
  if (!context.mounted) return;
  final vuole = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: c.cPannello,
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
          child: Text('No, grazie', style: TextStyle(color: c.cTenue)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          style: FilledButton.styleFrom(
              backgroundColor: c.cAccento, foregroundColor: c.cSuAccento),
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
          'categorie che hai sistemato sul telefono e che nel backup non ci sono.\n\n'
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
                    backgroundColor: c.cErrore, foregroundColor: Colors.white)
                .copyWith(backgroundBuilder: senzaNeon),
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
                    backgroundColor: c.cErrore, foregroundColor: Colors.white)
                .copyWith(backgroundBuilder: senzaNeon),
            child: Text(conferma),
          ),
        ],
      ),
    );
