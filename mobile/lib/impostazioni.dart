/// Le preferenze dell'app: tema e auto-blocco.
///
/// Stanno in un file JSON accanto al vault (`deposito.dart`), non in un
/// pacchetto di impostazioni: sono due valori, e una dipendenza in più è una
/// dipendenza che può rompersi al prossimo aggiornamento di Android.
///
/// Qui dentro **non finisce niente di segreto**: né password, né chiavi.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'deposito.dart';
import 'sync_protocollo.dart';
import 'tema.dart';

class Impostazioni {
  /// Il predefinito è **Scuro**, blu con l'accento azzurro: lo stesso del PC.
  /// Fino al 16/09/2026 sul telefono era «Notte e oro», e le due app
  /// sembravano due prodotti.
  TemaId tema;

  /// L'utente ha scelto il tema dalle Impostazioni?
  ///
  /// Serve perché fino al 16/09/2026 il tema si salvava **sempre**, anche
  /// quando nessuno l'aveva toccato: «Notte e oro» nel file non distingue chi
  /// l'ha voluto da chi l'ha solo ricevuto come predefinito. Senza questa
  /// voce, il nuovo predefinito non sarebbe mai arrivato a chi aveva già
  /// aperto l'app una volta.
  bool temaScelto;

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

  /// Lunghezza e simboli dell'ultima password generata.
  ///
  /// Si ricordano solo questi due, come sul PC (`gen_length`, `gen_symbols`):
  /// sono le due scelte che una persona fa una volta e poi tiene. Maiuscole,
  /// minuscole e cifre no — si spengono per un sito che non le accetta, e
  /// quella è una deroga, non una preferenza.
  int genLunghezza;
  bool genSimboli;

  // ---- sincronizzazione ----
  // Qui dentro **non finisce nessun segreto**, nemmeno adesso: le chiavi verso
  // ogni dispositivo si ricavano dalla chiave del vault (`chiaveVerso`), non si
  // salvano. Restano un identificativo, dei nomi e dei contatori.

  /// Identificativo di QUESTO telefono. Casuale: il MAC address si falsifica e
  /// Android lo randomizza per rete, quindi come serratura non regge — e come
  /// etichetta un numero a caso va benissimo, senza dire niente su di te.
  String idDispositivo;

  /// Come si presenta agli altri dispositivi.
  String nomeDispositivo;

  /// Sync acceso? Da spento non si apre nessuna porta e non si risponde a nessuno.
  bool syncAcceso;

  /// {idPeer: nome} dei dispositivi abbinati. È un elenco di **autorizzazione**:
  /// revocare qui chiude la porta anche a chi conosce la master password.
  Map<String, String> fidati;

  /// {idPeer: {uid: rev}} allo scorso sync riuscito con quel dispositivo.
  ///
  /// È ciò che permette di distinguere «sono più avanti di te» da «siamo
  /// divergiti»: senza, ogni differenza sarebbe un conflitto. Sta qui e non nel
  /// vault perché è un dato **derivato**, e non deve viaggiare col backup.
  Map<String, Map<String, int>> basi;

  /// {idPeer: "indirizzo:porta"} dell'ultima volta che quel dispositivo ha
  /// risposto.
  ///
  /// È il pezzo che fa funzionare il sync **fuori casa**. La scoperta è in
  /// broadcast, e un tunnel VPN è un collegamento punto-punto instradato: i
  /// broadcast non ci passano, quindi da fuori la domanda non arriva a
  /// nessuno. L'indirizzo imparato in casa però resta valido *attraverso* il
  /// tunnel — il PC è `192.168.5.53` sia dal divano sia dall'altra parte del
  /// mondo — e ricordarlo fa ripartire il sync da solo.
  ///
  /// Non è un segreto: è un indirizzo di rete privata, che non dice niente a
  /// chi non è già dentro quella rete.
  Map<String, String> indirizzi;

  Impostazioni({
    this.tema = TemaId.scuro,
    this.temaScelto = false,
    this.autoBlocco = 5,
    List<int>? pinnate,
    this.genLunghezza = 20,
    this.genSimboli = true,
    this.idDispositivo = '',
    this.nomeDispositivo = '',
    this.syncAcceso = true,
    Map<String, String>? fidati,
    Map<String, Map<String, int>>? basi,
    Map<String, String>? indirizzi,
  })  : pinnate = pinnate ?? [],
        fidati = fidati ?? {},
        basi = basi ?? {},
        indirizzi = indirizzi ?? {};

  Map<String, dynamic> toJson() => {
        'tema': tema.name,
        if (temaScelto) 'temaScelto': true,
        'autoBlocco': autoBlocco,
        'pinnate': pinnate,
        'genLunghezza': genLunghezza,
        'genSimboli': genSimboli,
        'idDispositivo': idDispositivo,
        'nomeDispositivo': nomeDispositivo,
        'syncAcceso': syncAcceso,
        'fidati': fidati,
        'basi': basi,
        'indirizzi': indirizzi,
      };

  static Impostazioni fromJson(Map<String, dynamic> j) {
    final scelto = j['temaScelto'] == true;
    final letto = TemaId.values.firstWhere(
      (t) => t.name == j['tema'],
      orElse: () => TemaId.scuro,
    );
    return Impostazioni(
        // «Notte e oro» mai scelto era il vecchio predefinito: passa al nuovo.
        // Il chiaro invece non era predefinito, quindi qualcuno l'ha voluto.
        tema: !scelto && letto == TemaId.notteOro ? TemaId.scuro : letto,
        temaScelto: scelto,
        autoBlocco: (j['autoBlocco'] as num?)?.toInt() ?? 5,
        pinnate: ((j['pinnate'] ?? const []) as List)
            .map((x) => (x as num).toInt())
            .toList(),
        genLunghezza: (j['genLunghezza'] as num?)?.toInt() ?? 20,
        genSimboli: j['genSimboli'] != false,
        idDispositivo: '${j['idDispositivo'] ?? ''}',
        nomeDispositivo: '${j['nomeDispositivo'] ?? ''}',
        syncAcceso: j['syncAcceso'] != false,
        fidati: {
          for (final e in ((j['fidati'] ?? const {}) as Map).entries)
            '${e.key}': '${e.value}'
        },
        basi: {
          for (final e in ((j['basi'] ?? const {}) as Map).entries)
            '${e.key}': {
              for (final b in (e.value as Map).entries)
                '${b.key}': (b.value as num).toInt()
            }
        },
        indirizzi: {
          for (final e in ((j['indirizzi'] ?? const {}) as Map).entries)
            '${e.key}': '${e.value}'
        },
      );
  }

  Impostazioni copia({
    TemaId? tema,
    bool? temaScelto,
    int? autoBlocco,
    List<int>? pinnate,
    int? genLunghezza,
    bool? genSimboli,
    String? idDispositivo,
    String? nomeDispositivo,
    bool? syncAcceso,
    Map<String, String>? fidati,
    Map<String, Map<String, int>>? basi,
    Map<String, String>? indirizzi,
  }) =>
      Impostazioni(
        tema: tema ?? this.tema,
        temaScelto: temaScelto ?? this.temaScelto,
        autoBlocco: autoBlocco ?? this.autoBlocco,
        pinnate: pinnate ?? this.pinnate,
        genLunghezza: genLunghezza ?? this.genLunghezza,
        genSimboli: genSimboli ?? this.genSimboli,
        idDispositivo: idDispositivo ?? this.idDispositivo,
        nomeDispositivo: nomeDispositivo ?? this.nomeDispositivo,
        syncAcceso: syncAcceso ?? this.syncAcceso,
        fidati: fidati ?? this.fidati,
        basi: basi ?? this.basi,
        indirizzi: indirizzi ?? this.indirizzi,
      );
}

/// Le impostazioni vive, osservate dall'app: cambiando questo valore l'intera
/// interfaccia si ridipinge da sola.
final impostazioni = ValueNotifier<Impostazioni>(Impostazioni());

const _nome = 'impostazioni.json';

Future<void> caricaImpostazioni() async {
  try {
    final testo = await leggiDeposito(_nome);
    if (testo != null) {
      impostazioni.value =
          Impostazioni.fromJson(jsonDecode(testo) as Map<String, dynamic>);
    }
  } catch (_) {
    // Un file di preferenze illeggibile non deve impedire di aprire il vault:
    // si riparte dai valori predefiniti.
  }
  // L'identità del dispositivo si crea una volta sola e poi non cambia più: se
  // cambiasse, gli altri dispositivi lo vedrebbero come uno nuovo e l'elenco
  // dei fidati si riempirebbe di fantasmi.
  final i = impostazioni.value;
  if (i.idDispositivo.isEmpty || i.nomeDispositivo.isEmpty) {
    await salvaImpostazioni(i.copia(
      idDispositivo: i.idDispositivo.isEmpty ? idDispositivo() : i.idDispositivo,
      nomeDispositivo:
          i.nomeDispositivo.isEmpty ? 'Telefono' : i.nomeDispositivo,
    ));
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
    await scriviDeposito(_nome, jsonEncode(nuove.toJson()));
  } catch (_) {
    // Se non si salva, la scelta vale per questa sessione: fastidioso, non grave.
  }
}
