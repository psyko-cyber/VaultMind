/// Le preferenze dell'app: tema, sfondi e auto-blocco.
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
import 'sfondo.dart';
import 'sync_protocollo.dart';
import 'tema.dart';

class Impostazioni {
  /// Il predefinito è **Prisma**, come sul PC e nell'estensione. Fino al
  /// 16/09/2026 sul telefono era «Notte e oro», e le due app sembravano due
  /// prodotti; dal 25/10/2026 i tre temi sono quelli nuovi (vedi [fromJson]).
  TemaId tema;

  /// L'utente ha scelto il tema dalle Impostazioni?
  ///
  /// Serve perché fino al 16/09/2026 il tema si salvava **sempre**, anche
  /// quando nessuno l'aveva toccato: «Notte e oro» nel file non distingue chi
  /// l'ha voluto da chi l'ha solo ricevuto come predefinito. Senza questa
  /// voce, il nuovo predefinito non sarebbe mai arrivato a chi aveva già
  /// aperto l'app una volta.
  bool temaScelto;

  /// Lo sfondo di ognuna delle tre sezioni: costellazione, aurora o tinta
  /// unita. Le Categorie seguono il Database.
  ///
  /// Una scelta per sezione e non una per tutta l'app perché ognuna ha il suo
  /// carattere: lo sblocco è una porta, la chat una conversazione, il database
  /// un archivio. I predefiniti sono gli stessi del PC.
  Sfondo sfondoSblocco;
  Sfondo sfondoChat;
  Sfondo sfondoDatabase;

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
  // Qui dentro **non finisce nessun segreto**: le chiavi dei PC collegati
  // stanno nel vault, cifrate (`sync_gestore.dart`). Restano un
  // identificativo, un nome e un interruttore. Le chiavi del sync di prima
  // (`fidati`, `basi`, `indirizzi`) non si leggono più, e alla prima
  // scrittura spariscono dal file.

  /// Identificativo di QUESTO telefono. Casuale: il MAC address si falsifica e
  /// Android lo randomizza per rete, quindi come serratura non regge — e come
  /// etichetta un numero a caso va benissimo, senza dire niente su di te.
  String idDispositivo;

  /// Come lo vede il PC.
  String nomeDispositivo;

  /// Sync acceso? Da spento non si apre nessuna porta e non si risponde a nessuno.
  bool syncAcceso;

  // ---- aggiornamenti dell'app ----
  // Il perché e i vincoli stanno in `aggiornamenti.dart`. Qui c'è solo quello
  // che va ricordato fra un avvio e l'altro, e non è segreto: un interruttore,
  // un orologio e il numero di versione visto su GitHub.

  /// Controllo degli aggiornamenti acceso? È l'**unica** connessione in uscita
  /// dell'app: da spento non parte nessuna richiesta verso Internet.
  bool aggAttivi;

  /// Quando si è chiesto l'ultima volta (ms). Serve a non chiedere più di una
  /// volta ogni 12 ore, anche a chi apre l'app venti volte al giorno.
  int aggControllo;

  /// L'ultima release vista, come l'ha descritta GitHub (vedi `Novita`).
  ///
  /// Si conserva perché **senza rete resta vera**: chi ha visto l'avviso ieri
  /// in casa lo rivede oggi in metropolitana, invece di vedere l'app
  /// dimenticarsene. Vuota = niente di nuovo.
  Map<String, dynamic> aggTrovata;

  /// La versione su cui si è risposto «più tardi», e quando: non si ripropone
  /// per 20 ore. Senza, chi dice «più tardi» se lo sente richiedere al
  /// prossimo sblocco, cioè fra dieci minuti.
  String aggRinviata;
  int aggRinviataQuando;

  Impostazioni({
    this.tema = TemaId.prisma,
    this.temaScelto = false,
    this.sfondoSblocco = Sfondo.costellazione,
    this.sfondoChat = Sfondo.aurora,
    this.sfondoDatabase = Sfondo.costellazione,
    this.autoBlocco = 5,
    List<int>? pinnate,
    this.genLunghezza = 20,
    this.genSimboli = true,
    this.idDispositivo = '',
    this.nomeDispositivo = '',
    this.syncAcceso = true,
    this.aggAttivi = true,
    this.aggControllo = 0,
    Map<String, dynamic>? aggTrovata,
    this.aggRinviata = '',
    this.aggRinviataQuando = 0,
  })  : pinnate = pinnate ?? [],
        aggTrovata = aggTrovata ?? {};

  Map<String, dynamic> toJson() => {
        'tema': tema.name,
        if (temaScelto) 'temaScelto': true,
        // Gli sfondi si scrivono solo se diversi dal predefinito: così, se un
        // giorno il predefinito cambia, arriva anche a chi non l'ha mai
        // toccato. Col tema si era dovuto inventare `temaScelto` apposta.
        if (sfondoSblocco != Sfondo.costellazione)
          'sfondoSblocco': sfondoSblocco.name,
        if (sfondoChat != Sfondo.aurora) 'sfondoChat': sfondoChat.name,
        if (sfondoDatabase != Sfondo.costellazione)
          'sfondoDatabase': sfondoDatabase.name,
        'autoBlocco': autoBlocco,
        'pinnate': pinnate,
        'genLunghezza': genLunghezza,
        'genSimboli': genSimboli,
        'idDispositivo': idDispositivo,
        'nomeDispositivo': nomeDispositivo,
        'syncAcceso': syncAcceso,
        // Si scrivono solo se dicono qualcosa: un file di preferenze pieno di
        // zeri non aiuta nessuno a capire cosa ci sta dentro.
        if (!aggAttivi) 'aggAttivi': false,
        if (aggControllo > 0) 'aggControllo': aggControllo,
        if (aggTrovata.isNotEmpty) 'aggTrovata': aggTrovata,
        if (aggRinviata.isNotEmpty) 'aggRinviata': aggRinviata,
        if (aggRinviataQuando > 0) 'aggRinviataQuando': aggRinviataQuando,
      };

  /// Il tema salvato, tradotto dai nomi di prima del 25/10/2026.
  ///
  /// Scuro diventa Prisma e Chiaro diventa Ghiaccio: sono i loro posti nella
  /// nuova terna, e chi aveva voluto il chiaro deve ritrovarsi un tema chiaro.
  /// «Notte e oro» mai scelto era il predefinito fino al 16/09/2026, quindi
  /// passa al predefinito di adesso; scelto, resta Notte e oro.
  static TemaId _tema(Object? nome, bool scelto) {
    switch (nome) {
      case 'ghiaccio':
      case 'chiaro':
        return TemaId.ghiaccio;
      case 'oro':
        return TemaId.oro;
      case 'notteOro':
        return scelto ? TemaId.oro : TemaId.prisma;
      default:
        return TemaId.prisma;
    }
  }

  static Sfondo _sfondo(Object? nome, Sfondo predefinito) => Sfondo.values
      .firstWhere((s) => s.name == nome, orElse: () => predefinito);

  static Impostazioni fromJson(Map<String, dynamic> j) {
    final scelto = j['temaScelto'] == true;
    return Impostazioni(
        tema: _tema(j['tema'], scelto),
        temaScelto: scelto,
        sfondoSblocco: _sfondo(j['sfondoSblocco'], Sfondo.costellazione),
        sfondoChat: _sfondo(j['sfondoChat'], Sfondo.aurora),
        sfondoDatabase: _sfondo(j['sfondoDatabase'], Sfondo.costellazione),
        autoBlocco: (j['autoBlocco'] as num?)?.toInt() ?? 5,
        pinnate: ((j['pinnate'] ?? const []) as List)
            .map((x) => (x as num).toInt())
            .toList(),
        genLunghezza: (j['genLunghezza'] as num?)?.toInt() ?? 20,
        genSimboli: j['genSimboli'] != false,
        idDispositivo: '${j['idDispositivo'] ?? ''}',
        nomeDispositivo: '${j['nomeDispositivo'] ?? ''}',
        syncAcceso: j['syncAcceso'] != false,
        aggAttivi: j['aggAttivi'] != false,
        aggControllo: (j['aggControllo'] as num?)?.toInt() ?? 0,
        aggTrovata: {
          for (final e in ((j['aggTrovata'] ?? const {}) as Map).entries)
            '${e.key}': e.value
        },
        aggRinviata: '${j['aggRinviata'] ?? ''}',
        aggRinviataQuando: (j['aggRinviataQuando'] as num?)?.toInt() ?? 0,
      );
  }

  Impostazioni copia({
    TemaId? tema,
    bool? temaScelto,
    Sfondo? sfondoSblocco,
    Sfondo? sfondoChat,
    Sfondo? sfondoDatabase,
    int? autoBlocco,
    List<int>? pinnate,
    int? genLunghezza,
    bool? genSimboli,
    String? idDispositivo,
    String? nomeDispositivo,
    bool? syncAcceso,
    bool? aggAttivi,
    int? aggControllo,
    Map<String, dynamic>? aggTrovata,
    String? aggRinviata,
    int? aggRinviataQuando,
  }) =>
      Impostazioni(
        tema: tema ?? this.tema,
        temaScelto: temaScelto ?? this.temaScelto,
        sfondoSblocco: sfondoSblocco ?? this.sfondoSblocco,
        sfondoChat: sfondoChat ?? this.sfondoChat,
        sfondoDatabase: sfondoDatabase ?? this.sfondoDatabase,
        autoBlocco: autoBlocco ?? this.autoBlocco,
        pinnate: pinnate ?? this.pinnate,
        genLunghezza: genLunghezza ?? this.genLunghezza,
        genSimboli: genSimboli ?? this.genSimboli,
        idDispositivo: idDispositivo ?? this.idDispositivo,
        nomeDispositivo: nomeDispositivo ?? this.nomeDispositivo,
        syncAcceso: syncAcceso ?? this.syncAcceso,
        aggAttivi: aggAttivi ?? this.aggAttivi,
        aggControllo: aggControllo ?? this.aggControllo,
        aggTrovata: aggTrovata ?? this.aggTrovata,
        aggRinviata: aggRinviata ?? this.aggRinviata,
        aggRinviataQuando: aggRinviataQuando ?? this.aggRinviataQuando,
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
  // cambiasse, il PC lo vedrebbe come un telefono nuovo e l'elenco dei
  // telefoni collegati si riempirebbe di fantasmi.
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
