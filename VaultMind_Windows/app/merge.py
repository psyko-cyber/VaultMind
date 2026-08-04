"""
merge.py — Fusione di due copie dello stesso vault, voce per voce.

È il cuore del sync (TODO §2), e l'unica parte del progetto che può
**distruggere** dati invece di limitarsi a non funzionare. Per questo:

  - è una **funzione pura**: nessun file, nessuna rete, nessuno stato. Si può
    provare con centinaia di casi in un secondo;
  - esiste identica in Dart (`mobile/lib/fusione.dart`), perché entrambi i lati
    possono ricevere e fondere. Le due implementazioni sono tenute allineate
    dal vettore di casi `tests/vettore/fusione.json`, che le due suite eseguono
    a ogni esecuzione — divergere in silenzio è esattamente il modo in cui un
    sync perde le password;
  - **non risolve mai un conflitto da sola.** Quando due dispositivi hanno
    cambiato la stessa voce, la mette da parte e la fa decidere all'utente. Su
    un gestore di password una versione persa in silenzio è inaccettabile.

## Il punto difficile: capire chi è più avanti

Un contatore per voce (`rev`) dice quante volte quella voce è stata modificata,
ma **non** basta a distinguere due situazioni molto diverse:

    io rev 3, tu rev 2   →  sono più avanti di te?   (allora prendo la mia)
                         →  oppure siamo divergiti?  (allora è un conflitto)

Dal solo confronto dei numeri non si può sapere. Quello che lo dice è la
**base**: cosa i due dispositivi si erano detti l'ultima volta che hanno
sincronizzato. Con quella, "cambiato da me" e "cambiato da te" diventano due
fatti indipendenti, e il conflitto è esattamente il caso in cui valgono
entrambi.

La base è un dizionario `{uid: rev}`, sta nelle preferenze locali (una per
dispositivo abbinato) e **non** nel vault: è un dato derivato, si rigenera al
prossimo sync e non deve viaggiare.

Senza base — cioè al primissimo sync fra due dispositivi — si è prudenti: due
versioni diverse della stessa voce sono un conflitto, e si chiede.
"""

from __future__ import annotations
import json
from dataclasses import dataclass, field, replace
from typing import Dict, List, Optional, Tuple

from .crypto_store import Credential, uid_derivato

# ---------------------------------------------------------------- i conflitti

#: Entrambi hanno modificato la stessa voce, in modi diversi.
ENTRAMBI_MODIFICATA = "entrambi-modificata"
#: Qui è stata modificata, di là cancellata.
MODIFICATA_QUI_CANCELLATA_LA = "modificata-qui-cancellata-la"
#: Qui è stata cancellata, di là modificata.
CANCELLATA_QUI_MODIFICATA_LA = "cancellata-qui-modificata-la"


@dataclass
class Conflitto:
    """Una voce che il motore si RIFIUTA di risolvere da solo."""
    uid: str
    motivo: str
    #: La versione locale. `None` se qui è stata cancellata.
    mia: Optional[Credential] = None
    #: La versione remota. `None` se di là è stata cancellata.
    sua: Optional[Credential] = None
    #: I due contatori, anche quando una delle due versioni non c'è più (in quel
    #: caso è il `rev` della lapide). Servono a chi risolve: registrare nella
    #: base il `rev` dell'altro è ciò che fa **convergere** la scelta, invece di
    #: far ripresentare la stessa domanda a ogni sync.
    rev_mia: int = 0
    rev_sua: int = 0

    @property
    def titolo(self) -> str:
        """Come chiamarla parlando all'utente, anche se una parte non c'è."""
        for c in (self.mia, self.sua):
            if c is not None and c.title:
                return c.title
        return self.uid


@dataclass
class Istantanea:
    """Lo stato di un vault nel momento della fusione. Volutamente senza
    chiave e senza file: la fusione non deve poter toccare il disco."""
    entries: List[Credential] = field(default_factory=list)
    tombstones: List[dict] = field(default_factory=list)
    categories: List[str] = field(default_factory=list)


@dataclass
class Fusione:
    """Il risultato. Le voci in conflitto restano com'erano **in locale**:
    applicare una fusione senza aver deciso i conflitti non cambia nulla di
    quelle voci, e non c'è un momento in cui il vault è a metà."""
    entries: List[Credential] = field(default_factory=list)
    tombstones: List[dict] = field(default_factory=list)
    categories: List[str] = field(default_factory=list)
    conflitti: List[Conflitto] = field(default_factory=list)
    #: Quante voci sono arrivate, cambiate, sparite, rimaste uguali.
    riepilogo: dict = field(default_factory=dict)

    @property
    def qualcosa_da_fare(self) -> bool:
        r = self.riepilogo
        return bool(self.conflitti or r.get("aggiunte") or r.get("aggiornate")
                    or r.get("cancellate"))


# ------------------------------------------------------------------- utilità

def impronta(c: Credential) -> str:
    """Il CONTENUTO di una voce, senza le sue coordinate.

    Fuori restano `id` (è un numero locale: la stessa voce può averne uno
    diverso sui due dispositivi), `rev` e `mod` (dicono *quando*, non *cosa*).
    Due voci con la stessa impronta sono la stessa cosa, anche se i contatori
    non coincidono — e allora non c'è niente da fondere.
    """
    return json.dumps([
        c.title,
        list(c.tags),
        bool(c.critical),
        c.category,
        [[f.label, f.value] for f in c.fields],
        {k: c.extra[k] for k in sorted(c.extra)},
    ], ensure_ascii=False, sort_keys=True)


def base_da(entries: List[Credential]) -> Dict[str, int]:
    """La base da conservare dopo un sync riuscito: cosa i due si sono detti.
    Al prossimo giro è lei a dire chi ha cambiato cosa."""
    return {c.uid: c.rev for c in entries}


def _per_uid(entries: List[Credential]) -> Dict[str, Credential]:
    return {c.uid: c for c in entries}


def _lapidi_per_uid(tombstones: List[dict]) -> Dict[str, dict]:
    return {str(t.get("uid")): t for t in tombstones if t.get("uid")}


# stato di una voce da un lato: ("viva", cred) | ("morta", rev) | ("assente", None)
def _stato(uid: str, vive: Dict[str, Credential], morte: Dict[str, dict]) -> Tuple[str, object]:
    if uid in vive:
        return ("viva", vive[uid])
    if uid in morte:
        return ("morta", int(morte[uid].get("rev") or 1))
    return ("assente", None)


def _cambiato(stato: Tuple[str, object], base: Optional[Dict[str, int]], uid: str) -> bool:
    """Questo lato ha toccato la voce dall'ultimo sync?

    Senza base non si può sapere, e si risponde di sì: è la risposta prudente,
    perché porta a chiedere invece che a scegliere al posto dell'utente.
    """
    if base is None:
        return True
    tipo, dato = stato
    if tipo == "viva":
        return base.get(uid) != dato.rev
    if tipo == "morta":
        # Una lapide è sempre una modifica da propagare. Se la cancellazione
        # era già stata scambiata all'ultimo sync, anche l'altro lato ce l'ha e
        # sono d'accordo: dirlo di nuovo non fa danni.
        return True
    # Assente: nessuna informazione. Non si cancella mai per assenza — una
    # lapide potata da tempo farebbe sparire la voce dall'altro dispositivo.
    return False


def _lapide(uid: str, rev: int, mod: int) -> dict:
    return {"uid": uid, "rev": rev, "mod": mod}


# ------------------------------------------------------------------ la fusione

def fondi(mia: Istantanea, sua: Istantanea,
          base: Optional[Dict[str, int]] = None) -> Fusione:
    """Fonde `sua` dentro `mia` e restituisce il risultato coi conflitti.

    `base` è la fotografia dell'ultimo sync **con quel dispositivo**
    (`{uid: rev}`). Senza, la fusione è prudente e chiede più spesso.
    """
    mie_vive, mie_morte = _per_uid(mia.entries), _lapidi_per_uid(mia.tombstones)
    sue_vive, sue_morte = _per_uid(sua.entries), _lapidi_per_uid(sua.tombstones)

    uids = list(mie_vive) + list(mie_morte)
    for u in list(sue_vive) + list(sue_morte):
        if u not in uids:
            uids.append(u)

    tenute: Dict[str, Credential] = {}
    lapidi: Dict[str, dict] = {}
    conflitti: List[Conflitto] = []
    conti = {"aggiunte": 0, "aggiornate": 0, "cancellate": 0, "invariate": 0}

    for uid in uids:
        a = _stato(uid, mie_vive, mie_morte)
        b = _stato(uid, sue_vive, sue_morte)

        # --- la voce non esiste più da nessuna delle due parti ---
        if a[0] == "morta" or b[0] == "morta":
            # si tiene comunque la lapide più avanti fra le due: serve a non
            # farsi rimandare indietro la voce da un terzo dispositivo
            revs = [x[1] for x in (a, b) if x[0] == "morta"]
            mods = [int((m.get(uid) or {}).get("mod") or 0)
                    for m in (mie_morte, sue_morte) if uid in m]
            lapidi[uid] = _lapide(uid, max(revs), max(mods) if mods else 0)

        cambiata_qui = _cambiato(a, base, uid)
        cambiata_la = _cambiato(b, base, uid)

        # --- nessuno l'ha toccata ---
        if not cambiata_qui and not cambiata_la:
            if a[0] == "viva":
                tenute[uid] = a[1]
                conti["invariate"] += 1
            continue

        # --- l'ha toccata uno solo: si prende la sua versione ---
        if cambiata_qui and not cambiata_la:
            if a[0] == "viva":
                tenute[uid] = a[1]
            continue
        if cambiata_la and not cambiata_qui:
            if b[0] == "viva":
                tenute[uid] = b[1]
                conti["aggiornate" if a[0] == "viva" else "aggiunte"] += 1
            elif a[0] == "viva":
                conti["cancellate"] += 1
            continue

        # --- l'hanno toccata entrambi ---
        if a[0] == "viva" and b[0] == "viva":
            if impronta(a[1]) == impronta(b[1]):
                # stessa identica cosa scritta due volte: niente da decidere,
                # si tiene quella col contatore più avanti per non tornare indietro
                tenute[uid] = a[1] if a[1].rev >= b[1].rev else b[1]
                conti["invariate"] += 1
            elif a[1].rev == 1 and b[1].rev > 1:
                # Una copia ferma a `rev` 1 non è mai stata toccata da quando i
                # due vault si sono separati: è l'originale, e l'altra ne
                # discende. Non è un conflitto, è un aggiornamento — e senza
                # questa regola il PRIMO sync di un vault appena riordinato
                # farebbe una domanda per ognuna delle 800 voci.
                tenute[uid] = b[1]
                conti["aggiornate"] += 1
            elif b[1].rev == 1 and a[1].rev > 1:
                tenute[uid] = a[1]
                conti["invariate"] += 1
            else:
                tenute[uid] = a[1]          # per ora resta la mia
                conflitti.append(Conflitto(uid, ENTRAMBI_MODIFICATA, a[1], b[1],
                                           rev_mia=a[1].rev, rev_sua=b[1].rev))
            continue

        if a[0] == "viva" and b[0] == "morta":
            # La lapide vince SOLO se è provabilmente più recente della mia
            # copia: `rev` cresce solo modificando, quindi se la mia versione è
            # più indietro del momento in cui l'hanno cancellata, la mia è
            # semplicemente vecchia. Altrimenti ho modifiche che il cancellatore
            # non ha mai visto, e la decisione non è mia da prendere.
            if b[1] > a[1].rev:
                conti["cancellate"] += 1
            else:
                tenute[uid] = a[1]
                conflitti.append(Conflitto(uid, MODIFICATA_QUI_CANCELLATA_LA, a[1], None,
                                           rev_mia=a[1].rev, rev_sua=b[1]))
            continue

        if a[0] == "morta" and b[0] == "viva":
            if a[1] > b[1].rev:
                pass                        # cancellata qui, e di là è più vecchia
            else:
                conflitti.append(Conflitto(uid, CANCELLATA_QUI_MODIFICATA_LA, None, b[1],
                                           rev_mia=a[1], rev_sua=b[1].rev))
            continue

        if a[0] == "assente" and b[0] == "viva":
            tenute[uid] = b[1]
            conti["aggiunte"] += 1
            continue
        if a[0] == "viva" and b[0] == "assente":
            tenute[uid] = a[1]

    # Una voce che sopravvive alla fusione non può portarsi dietro la propria
    # lapide: succede quando la cancellazione perde (è più vecchia della
    # modifica) o quando resta in sospeso come conflitto. Se la si lasciasse,
    # il vault direbbe due cose opposte sulla stessa voce.
    lapidi = {u: t for u, t in lapidi.items() if u not in tenute}

    # ordine: prima le mie com'erano, poi quelle arrivate da lui
    ordine = [c.uid for c in mia.entries] + [c.uid for c in sua.entries]
    viste = set()
    finali: List[Credential] = []
    for uid in ordine:
        if uid in tenute and uid not in viste:
            viste.add(uid)
            finali.append(tenute[uid])

    return Fusione(
        entries=_id_unici(finali),
        tombstones=[lapidi[u] for u in sorted(lapidi)],
        categories=_unisci_categorie(mia.categories, sua.categories),
        conflitti=conflitti,
        riepilogo=conti,
    )


def _unisci_categorie(mie: List[str], sue: List[str]) -> List[str]:
    """Unione, con le mie davanti nell'ordine che avevano.

    Nota onesta: una categoria rinominata su un dispositivo e non sull'altro
    ricompare qui col vecchio nome, vuota. Non si può distinguere una rinomina
    da "cancellata di qua, creata di là" guardando solo due liste di stringhe,
    e fra il rischio di far ricomparire un nome e quello di far sparire una
    categoria creata dall'utente, si sceglie il primo.
    """
    fuori: List[str] = []
    viste = set()
    for c in list(mie) + list(sue):
        k = c.casefold()
        if c and k not in viste:
            viste.add(k)
            fuori.append(c)
    return fuori


def _id_unici(entries: List[Credential]) -> List[Credential]:
    """Dopo la fusione due voci possono ritrovarsi con lo stesso `id`: è un
    numero locale, e due dispositivi scollegati assegnano lo stesso `max+1`.

    Chi lo cede è **sempre** quella con un uid casuale, mai quella con un uid
    ricavato dall'id: per quelle il numero *è* l'identità, e cambiarlo
    significherebbe farle diventare un'altra voce al prossimo sync.
    """
    usati = {c.id for c in entries if c.uid == uid_derivato(c.id)}
    prossimo = max([c.id for c in entries], default=0) + 1
    fuori: List[Credential] = []
    for c in entries:
        if c.uid == uid_derivato(c.id):
            fuori.append(c)
            continue
        if c.id in usati:
            while prossimo in usati:
                prossimo += 1
            # replace() e non c.id = …: la fusione è una funzione pura, e
            # cambiare le voci ricevute in ingresso vorrebbe dire modificare il
            # vault di chi l'ha chiamata prima ancora che decida se applicarla.
            c = replace(c, id=prossimo)
        usati.add(c.id)
        fuori.append(c)
    return fuori
