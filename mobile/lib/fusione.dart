/// Fusione di due copie dello stesso vault, voce per voce.
///
/// È il cuore del sync, e l'unica parte del progetto che può **distruggere**
/// dati invece di limitarsi a non funzionare. Per questo:
///
///   - è una **funzione pura**: nessun file, nessuna rete, nessuno stato;
///   - esiste identica in Python (`VaultMind_Windows/app/merge.py`), perché
///     entrambi i lati possono ricevere e fondere. Le due implementazioni sono
///     tenute allineate dal vettore di casi `tests/vettore/fusione.json`, che
///     le due suite eseguono a ogni esecuzione: divergere in silenzio è
///     esattamente il modo in cui un sync perde le password;
///   - **non risolve mai un conflitto da sola.** Quando due dispositivi hanno
///     cambiato la stessa voce, la mette da parte e la fa decidere all'utente.
///
/// ## Il punto difficile: capire chi è più avanti
///
/// Un contatore per voce (`rev`) dice quante volte quella voce è stata
/// modificata, ma **non** basta a distinguere due situazioni molto diverse:
///
///     io rev 3, tu rev 2  →  sono più avanti di te?   (prendo la mia)
///                         →  oppure siamo divergiti?  (è un conflitto)
///
/// Quello che lo dice è la **base**: cosa i due dispositivi si erano detti
/// l'ultima volta che hanno sincronizzato. Con quella, "cambiato da me" e
/// "cambiato da te" diventano due fatti indipendenti, e il conflitto è
/// esattamente il caso in cui valgono entrambi.
///
/// La base è una mappa `{uid: rev}`, sta nelle preferenze locali (una per
/// dispositivo abbinato) e **non** nel vault: è un dato derivato.
///
/// Senza base — al primissimo sync fra due dispositivi — si è prudenti: due
/// versioni diverse della stessa voce sono un conflitto, e si chiede.
library;

import 'dart:convert';

import 'vault.dart';

/// Entrambi hanno modificato la stessa voce, in modi diversi.
const String entrambiModificata = 'entrambi-modificata';

/// Qui è stata modificata, di là cancellata.
const String modificataQuiCancellataLa = 'modificata-qui-cancellata-la';

/// Qui è stata cancellata, di là modificata.
const String cancellataQuiModificataLa = 'cancellata-qui-modificata-la';

/// Una voce che il motore si RIFIUTA di risolvere da solo.
class Conflitto {
  final String uid;
  final String motivo;

  /// La versione locale. `null` se qui è stata cancellata.
  final Credenziale? mia;

  /// La versione remota. `null` se di là è stata cancellata.
  final Credenziale? sua;

  /// I due contatori, anche quando una delle due versioni non c'è più (in quel
  /// caso è il `rev` della lapide). Servono a chi risolve: registrare nella
  /// base il `rev` dell'altro è ciò che fa **convergere** la scelta, invece di
  /// far ripresentare la stessa domanda a ogni sync.
  final int revMia, revSua;

  const Conflitto(this.uid, this.motivo,
      {this.mia, this.sua, this.revMia = 0, this.revSua = 0});

  /// Come chiamarla parlando all'utente, anche se una parte non c'è.
  String get titolo {
    for (final c in [mia, sua]) {
      if (c != null && c.title.isNotEmpty) return c.title;
    }
    return uid;
  }
}

/// Lo stato di un vault nel momento della fusione. Volutamente senza chiave e
/// senza file: la fusione non deve poter toccare il disco.
class Istantanea {
  final List<Credenziale> voci;
  final List<Lapide> lapidi;
  final List<String> categorie;

  const Istantanea({
    this.voci = const [],
    this.lapidi = const [],
    this.categorie = const [],
  });

  /// L'istantanea di un vault aperto.
  factory Istantanea.da(Vault v) =>
      Istantanea(voci: v.credenziali, lapidi: v.lapidi, categorie: v.categorie);
}

/// Il risultato. Le voci in conflitto restano com'erano **in locale**:
/// applicare una fusione senza aver deciso i conflitti non cambia nulla di
/// quelle voci, e non c'è un momento in cui il vault è a metà.
class Fusione {
  final List<Credenziale> voci;
  final List<Lapide> lapidi;
  final List<String> categorie;
  final List<Conflitto> conflitti;

  /// Quante voci sono arrivate, cambiate, sparite, rimaste uguali.
  final int aggiunte, aggiornate, cancellate, invariate;

  const Fusione({
    required this.voci,
    required this.lapidi,
    required this.categorie,
    required this.conflitti,
    this.aggiunte = 0,
    this.aggiornate = 0,
    this.cancellate = 0,
    this.invariate = 0,
  });

  bool get qualcosaDaFare =>
      conflitti.isNotEmpty || aggiunte > 0 || aggiornate > 0 || cancellate > 0;

  /// Come raccontarlo in una riga.
  String get riassunto {
    final pezzi = <String>[
      if (aggiunte > 0) '$aggiunte in arrivo',
      if (aggiornate > 0) '$aggiornate aggiornate',
      if (cancellate > 0) '$cancellate rimosse',
      if (conflitti.isNotEmpty) '${conflitti.length} da decidere',
    ];
    return pezzi.isEmpty ? 'Già allineati' : pezzi.join(' · ');
  }
}

/// Il CONTENUTO di una voce, senza le sue coordinate.
///
/// Fuori restano `id` (è un numero locale: la stessa voce può averne uno
/// diverso sui due dispositivi), `rev` e `mod` (dicono *quando*, non *cosa*).
/// Due voci con la stessa impronta sono la stessa cosa, anche se i contatori
/// non coincidono — e allora non c'è niente da fondere.
String impronta(Credenziale c) {
  final chiaviExtra = c.extra.keys.toList()..sort();
  return jsonEncode([
    c.title,
    c.tags,
    c.critical,
    c.categoria,
    c.fields.map((f) => [f.label, f.value]).toList(),
    {for (final k in chiaviExtra) k: c.extra[k]},
  ]);
}

/// La base da conservare dopo un sync riuscito: cosa i due si sono detti.
/// Al prossimo giro è lei a dire chi ha cambiato cosa.
Map<String, int> baseDa(Iterable<Credenziale> voci) =>
    {for (final c in voci) c.uid: c.rev};

// stato di una voce da un lato
enum _Tipo { viva, morta, assente }

class _Stato {
  final _Tipo tipo;
  final Credenziale? voce;
  final int rev;
  const _Stato(this.tipo, {this.voce, this.rev = 0});
}

_Stato _statoDi(String uid, Map<String, Credenziale> vive, Map<String, Lapide> morte) {
  final v = vive[uid];
  if (v != null) return _Stato(_Tipo.viva, voce: v, rev: v.rev);
  final m = morte[uid];
  if (m != null) return _Stato(_Tipo.morta, rev: m.rev);
  return const _Stato(_Tipo.assente);
}

/// Questo lato ha toccato la voce dall'ultimo sync?
///
/// Senza base non si può sapere, e si risponde di sì: è la risposta prudente,
/// perché porta a chiedere invece che a scegliere al posto dell'utente.
bool _cambiato(_Stato s, Map<String, int>? base, String uid) {
  if (base == null) return true;
  switch (s.tipo) {
    case _Tipo.viva:
      return base[uid] != s.rev;
    case _Tipo.morta:
      // Una lapide è sempre una modifica da propagare. Se la cancellazione era
      // già stata scambiata all'ultimo sync, anche l'altro lato ce l'ha.
      return true;
    case _Tipo.assente:
      // Nessuna informazione. Non si cancella mai per assenza: una lapide
      // potata da tempo farebbe sparire la voce dall'altro dispositivo.
      return false;
  }
}

/// Fonde [sua] dentro [mia]. [base] è la fotografia dell'ultimo sync **con
/// quel dispositivo**; senza, la fusione è prudente e chiede più spesso.
Fusione fondi(Istantanea mia, Istantanea sua, [Map<String, int>? base]) {
  final mieVive = {for (final c in mia.voci) c.uid: c};
  final sueVive = {for (final c in sua.voci) c.uid: c};
  final mieMorte = {for (final l in mia.lapidi) l.uid: l};
  final sueMorte = {for (final l in sua.lapidi) l.uid: l};

  final uids = <String>[];
  for (final u in [...mieVive.keys, ...mieMorte.keys, ...sueVive.keys, ...sueMorte.keys]) {
    if (!uids.contains(u)) uids.add(u);
  }

  final tenute = <String, Credenziale>{};
  final lapidi = <String, Lapide>{};
  final conflitti = <Conflitto>[];
  var aggiunte = 0, aggiornate = 0, cancellate = 0, invariate = 0;

  for (final uid in uids) {
    final a = _statoDi(uid, mieVive, mieMorte);
    final b = _statoDi(uid, sueVive, sueMorte);

    if (a.tipo == _Tipo.morta || b.tipo == _Tipo.morta) {
      // si tiene la lapide più avanti fra le due: serve a non farsi rimandare
      // indietro la voce da un terzo dispositivo
      final revs = [
        if (a.tipo == _Tipo.morta) a.rev,
        if (b.tipo == _Tipo.morta) b.rev,
      ];
      final mods = [
        if (mieMorte[uid] != null) mieMorte[uid]!.mod,
        if (sueMorte[uid] != null) sueMorte[uid]!.mod,
      ];
      lapidi[uid] = Lapide(uid,
          rev: revs.reduce((x, y) => x > y ? x : y),
          mod: mods.isEmpty ? 0 : mods.reduce((x, y) => x > y ? x : y));
    }

    final quiCambiata = _cambiato(a, base, uid);
    final laCambiata = _cambiato(b, base, uid);

    if (!quiCambiata && !laCambiata) {
      if (a.tipo == _Tipo.viva) {
        tenute[uid] = a.voce!;
        invariate++;
      }
      continue;
    }

    if (quiCambiata && !laCambiata) {
      if (a.tipo == _Tipo.viva) tenute[uid] = a.voce!;
      continue;
    }
    if (laCambiata && !quiCambiata) {
      if (b.tipo == _Tipo.viva) {
        tenute[uid] = b.voce!;
        if (a.tipo == _Tipo.viva) {
          aggiornate++;
        } else {
          aggiunte++;
        }
      } else if (a.tipo == _Tipo.viva) {
        cancellate++;
      }
      continue;
    }

    // --- l'hanno toccata entrambi ---
    if (a.tipo == _Tipo.viva && b.tipo == _Tipo.viva) {
      if (impronta(a.voce!) == impronta(b.voce!)) {
        // stessa identica cosa scritta due volte: si tiene quella col
        // contatore più avanti, per non tornare indietro
        tenute[uid] = a.rev >= b.rev ? a.voce! : b.voce!;
        invariate++;
      } else if (a.rev == 1 && b.rev > 1) {
        // Una copia ferma a `rev` 1 non è mai stata toccata da quando i due
        // vault si sono separati: è l'originale, e l'altra ne discende. Non è
        // un conflitto, è un aggiornamento — e senza questa regola il PRIMO
        // sync di un vault appena riordinato farebbe una domanda per ognuna
        // delle 800 voci.
        tenute[uid] = b.voce!;
        aggiornate++;
      } else if (b.rev == 1 && a.rev > 1) {
        tenute[uid] = a.voce!;
        invariate++;
      } else {
        tenute[uid] = a.voce!; // per ora resta la mia
        conflitti.add(Conflitto(uid, entrambiModificata,
            mia: a.voce, sua: b.voce, revMia: a.rev, revSua: b.rev));
      }
      continue;
    }

    if (a.tipo == _Tipo.viva && b.tipo == _Tipo.morta) {
      // La lapide vince SOLO se è provabilmente più recente della mia copia:
      // `rev` cresce solo modificando, quindi se la mia versione è più
      // indietro del momento in cui l'hanno cancellata, la mia è vecchia.
      // Altrimenti ho modifiche che il cancellatore non ha mai visto.
      if (b.rev > a.rev) {
        cancellate++;
      } else {
        tenute[uid] = a.voce!;
        conflitti.add(Conflitto(uid, modificataQuiCancellataLa,
            mia: a.voce, revMia: a.rev, revSua: b.rev));
      }
      continue;
    }

    if (a.tipo == _Tipo.morta && b.tipo == _Tipo.viva) {
      if (a.rev <= b.rev) {
        conflitti.add(Conflitto(uid, cancellataQuiModificataLa,
            sua: b.voce, revMia: a.rev, revSua: b.rev));
      }
      continue;
    }

    if (a.tipo == _Tipo.assente && b.tipo == _Tipo.viva) {
      tenute[uid] = b.voce!;
      aggiunte++;
      continue;
    }
    if (a.tipo == _Tipo.viva && b.tipo == _Tipo.assente) {
      tenute[uid] = a.voce!;
    }
  }

  // Una voce che sopravvive alla fusione non può portarsi dietro la propria
  // lapide: succede quando la cancellazione perde (è più vecchia della
  // modifica) o quando resta in sospeso come conflitto. Se la si lasciasse, il
  // vault direbbe due cose opposte sulla stessa voce.
  lapidi.removeWhere((u, _) => tenute.containsKey(u));

  // ordine: prima le mie com'erano, poi quelle arrivate da lui
  final finali = <Credenziale>[];
  final viste = <String>{};
  for (final uid in [...mia.voci.map((c) => c.uid), ...sua.voci.map((c) => c.uid)]) {
    final c = tenute[uid];
    if (c != null && viste.add(uid)) finali.add(c);
  }

  final chiaviLapidi = lapidi.keys.toList()..sort();
  return Fusione(
    voci: _idUnici(finali),
    lapidi: [for (final k in chiaviLapidi) lapidi[k]!],
    categorie: _unisciCategorie(mia.categorie, sua.categorie),
    conflitti: conflitti,
    aggiunte: aggiunte,
    aggiornate: aggiornate,
    cancellate: cancellate,
    invariate: invariate,
  );
}

/// Unione, con le mie davanti nell'ordine che avevano.
///
/// Nota onesta: una categoria rinominata su un dispositivo e non sull'altro
/// ricompare qui col vecchio nome, vuota. Non si può distinguere una rinomina
/// da "cancellata di qua, creata di là" guardando due liste di stringhe, e fra
/// il rischio di far ricomparire un nome e quello di far sparire una categoria
/// creata dall'utente si sceglie il primo.
List<String> _unisciCategorie(List<String> mie, List<String> sue) {
  final fuori = <String>[];
  final viste = <String>{};
  for (final c in [...mie, ...sue]) {
    if (c.isNotEmpty && viste.add(c.toLowerCase())) fuori.add(c);
  }
  return fuori;
}

/// Dopo la fusione due voci possono ritrovarsi con lo stesso `id`: è un numero
/// locale, e due dispositivi scollegati assegnano lo stesso `max+1`.
///
/// Chi lo cede è **sempre** quella con un uid casuale, mai quella con un uid
/// ricavato dall'id: per quelle il numero *è* l'identità, e cambiarlo
/// significherebbe farle diventare un'altra voce al prossimo sync.
List<Credenziale> _idUnici(List<Credenziale> voci) {
  final usati = <int>{
    for (final c in voci)
      if (c.uid == uidDerivato(c.id)) c.id
  };
  var prossimo = voci.isEmpty
      ? 1
      : voci.map((c) => c.id).reduce((a, b) => a > b ? a : b) + 1;

  final fuori = <Credenziale>[];
  for (var c in voci) {
    if (c.uid == uidDerivato(c.id)) {
      fuori.add(c);
      continue;
    }
    if (usati.contains(c.id)) {
      while (usati.contains(prossimo)) {
        prossimo++;
      }
      c = c.conId(prossimo);
    }
    usati.add(c.id);
    fuori.add(c);
  }
  return fuori;
}
