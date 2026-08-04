/// Le preferenze dell'app: tema e auto-blocco.
///
/// Stanno in un file JSON accanto al vault, non in un pacchetto di
/// impostazioni: sono due valori, e una dipendenza in più è una dipendenza
/// che può rompersi al prossimo aggiornamento di Android.
///
/// Qui dentro **non finisce niente di segreto**: né password, né chiavi.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'tema.dart';

class Impostazioni {
  TemaId tema;

  /// Minuti di inattività dopo i quali il vault si richiude. 0 = mai.
  int autoBlocco;

  /// Gli `id` delle voci tenute in cima all'elenco, nell'ordine in cui sono
  /// state fissate.
  ///
  /// Stanno **qui e non nel vault** di proposito: un pin dice "questa mi serve
  /// spesso *su questo dispositivo*", e non è la stessa voce sul telefono e
  /// sul PC. Restando fuori dal vault sopravvivono anche al reimport di un
  /// backup, e non fanno divergere il file condiviso fra le piattaforme.
  /// Un pin che punta a una voce cancellata altrove si ignora in silenzio.
  List<int> pinnate;

  Impostazioni({
    this.tema = TemaId.notteOro,
    this.autoBlocco = 5,
    List<int>? pinnate,
  }) : pinnate = pinnate ?? [];

  Map<String, dynamic> toJson() =>
      {'tema': tema.name, 'autoBlocco': autoBlocco, 'pinnate': pinnate};

  static Impostazioni fromJson(Map<String, dynamic> j) => Impostazioni(
        tema: TemaId.values.firstWhere(
          (t) => t.name == j['tema'],
          orElse: () => TemaId.notteOro,
        ),
        autoBlocco: (j['autoBlocco'] as num?)?.toInt() ?? 5,
        pinnate: ((j['pinnate'] ?? const []) as List)
            .map((x) => (x as num).toInt())
            .toList(),
      );

  Impostazioni copia({TemaId? tema, int? autoBlocco, List<int>? pinnate}) =>
      Impostazioni(
        tema: tema ?? this.tema,
        autoBlocco: autoBlocco ?? this.autoBlocco,
        pinnate: pinnate ?? this.pinnate,
      );
}

/// Le impostazioni vive, osservate dall'app: cambiando questo valore l'intera
/// interfaccia si ridipinge da sola.
final impostazioni = ValueNotifier<Impostazioni>(Impostazioni());

Future<File> _file() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/impostazioni.json');
}

Future<void> caricaImpostazioni() async {
  try {
    final f = await _file();
    if (!await f.exists()) return;
    impostazioni.value =
        Impostazioni.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  } catch (_) {
    // Un file di preferenze illeggibile non deve impedire di aprire il vault:
    // si riparte dai valori predefiniti.
  }
}

bool eFissata(int id) => impostazioni.value.pinnate.contains(id);

/// Fissa la voce in cima, o la libera se c'era già.
Future<void> cambiaFissata(int id) async {
  final attuali = [...impostazioni.value.pinnate];
  if (!attuali.remove(id)) attuali.add(id);
  await salvaImpostazioni(impostazioni.value.copia(pinnate: attuali));
}

Future<void> salvaImpostazioni(Impostazioni nuove) async {
  impostazioni.value = nuove;
  try {
    (await _file()).writeAsString(jsonEncode(nuove.toJson()), flush: true);
  } catch (_) {
    // Se non si salva, la scelta vale per questa sessione: fastidioso, non grave.
  }
}
