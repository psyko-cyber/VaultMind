"""
merge.py — Fusione del vault del PC con quello di un telefono.

**Vince l'ultima modifica**, voce per voce. È la regola scelta da Luca il
25/10/2026, al posto dei conflitti da decidere a mano: chi ha due dispositivi in
casa e cambia una password su uno si aspetta di ritrovarla cambiata sull'altro,
non una domanda. È anche quella di Tigert, che funziona.

Funzione pura (niente file, niente rete): si prova con i casi di
`tests/vettore/fusione.json`. La esegue **solo il PC**: il telefono manda il
suo contenuto e riceve il risultato da adottare così com'è. Prima la fusione
esisteva uguale in due lingue, e tenerle allineate era un lavoro in più senza
un vantaggio per chi usa l'app.

## Chi vince

Per ogni `uid`, fra la voce viva e la lapide di ciascun lato, vince quella con
`mod` più grande; a parità `rev`, poi la lapide (nel dubbio la cancellazione
voluta resta tale), poi il contenuto, solo per essere deterministici. `mod` lo
scrive `crypto_store.dopo()`: mai meno di un millisecondo dopo la versione
precedente, così una correzione fatta *dopo* aver visto la voce vince anche se
l'altro orologio è avanti.

Una voce che c'è da una parte sola, senza lapide dall'altra, si tiene: l'assenza
non è una cancellazione.

## Due vault diversi

Da quando il collegamento passa dal QR, si possono collegare due vault nati
separati. Le voci che esistevano prima degli uid hanno un uid ricavato dal
numero (`#5`), e la voce 5 dell'uno non è la voce 5 dell'altro. Al **primo**
sync con un telefono (`primo=True`), quindi:

  - due voci con lo stesso `#n` e titolo diverso si tengono **tutte e due**
    (quella del telefono prende un uid nuovo);
  - una lapide con un `#n` non cancella la voce viva dell'altro lato.

Un doppione si cancella a mano; una password sparita non torna.

## Le categorie

La lista delle categorie si confronta con la **base**, la lista concordata
all'ultimo sync con quel telefono: se è cambiata da una parte sola vince quella
(così una categoria cancellata resta cancellata), se è cambiata da tutte e due
si uniscono. In più ogni categoria usata da una voce entra nella lista, perché
una voce non può stare in una categoria che non esiste.
"""

from __future__ import annotations
import json
import uuid
from dataclasses import dataclass, field, replace
from typing import Dict, List, Optional, Tuple

from .crypto_store import Credential, pota_lapidi, uid_derivato


@dataclass
class Istantanea:
    entries: List[Credential]
    tombstones: List[dict] = field(default_factory=list)
    categories: List[str] = field(default_factory=list)


@dataclass
class Fusione:
    entries: List[Credential]
    tombstones: List[dict]
    categories: List[str]
    #: Cosa cambia sul PC e cosa sul telefono: {"aggiunte", "aggiornate",
    #: "cancellate"} ciascuno. È ciò che le due app raccontano all'utente.
    sul_pc: Dict[str, int]
    sul_telefono: Dict[str, int]


def _numerata(uid: str) -> bool:
    """Un uid ricavato dal numero della voce (vedi `uid_derivato`)."""
    return uid.startswith("#")


def contenuto(c: Credential) -> str:
    """La voce senza `id`, in una forma confrontabile: l'id è un numero locale
    e lo stesso contenuto può averne due diversi su due dispositivi."""
    d = c.to_dict()
    d.pop("id", None)
    d["uid"] = c.uid
    return json.dumps(d, sort_keys=True, ensure_ascii=False, default=str)


def _lapide(t: dict) -> dict:
    return {"uid": str(t.get("uid") or ""), "rev": int(t.get("rev") or 1),
            "mod": int(t.get("mod") or 0)}


def fondi(pc: Istantanea, tel: Istantanea,
          base_categorie: Optional[List[str]] = None,
          primo: bool = False) -> Fusione:
    pc_vive: Dict[str, Credential] = {c.uid: c for c in pc.entries}
    tel_lista: List[Credential] = []
    for c in tel.entries:
        altra = pc_vive.get(c.uid)
        if primo and _numerata(c.uid) and altra is not None and altra.title != c.title:
            c = replace(c, uid=uuid.uuid4().hex)   # vedi «Due vault diversi»
        tel_lista.append(c)
    tel_vive: Dict[str, Credential] = {c.uid: c for c in tel_lista}
    pc_morte = {t["uid"]: t for t in map(_lapide, pc.tombstones) if t["uid"]}
    tel_morte = {t["uid"]: t for t in map(_lapide, tel.tombstones) if t["uid"]}

    def candidati(uid: str) -> List[Tuple[tuple, str, object]]:
        out = []
        for lato, vive, morte, vive_altro in (("pc", pc_vive, pc_morte, tel_vive),
                                              ("tel", tel_vive, tel_morte, pc_vive)):
            c = vive.get(uid)
            if c is not None:
                out.append(((c.mod, c.rev, 0, contenuto(c)), lato, c))
            t = morte.get(uid)
            if t is not None:
                if primo and _numerata(uid) and uid in vive_altro:
                    continue   # vedi «Due vault diversi» nel docstring
                out.append(((t["mod"], t["rev"], 1, ""), lato, t))
        return out

    vincitori: Dict[str, object] = {}
    for uid in set(pc_vive) | set(tel_vive) | set(pc_morte) | set(tel_morte):
        cand = candidati(uid)
        if cand:
            vincitori[uid] = max(cand, key=lambda x: x[0])[2]

    voci: List[Credential] = []
    lapidi: List[dict] = []
    # Prima le voci nuove arrivate dal telefono, nell'ordine che hanno là; poi
    # quelle del PC nel loro ordine. È l'ordine di `add()`: l'ultima aggiunta
    # in testa, che è quella che si cerca.
    for c in tel_lista:
        if c.uid in pc_vive:
            continue
        v = vincitori.get(c.uid)
        if isinstance(v, Credential):
            voci.append(v)
    for c in pc.entries:
        v = vincitori.get(c.uid)
        if isinstance(v, Credential):
            # L'id resta quello del PC: è quello che usano l'indice della
            # ricerca e la pagina aperta.
            voci.append(v if v.id == c.id else replace(v, id=c.id))
    for uid, v in vincitori.items():
        if isinstance(v, dict):
            lapidi.append(dict(v))
    lapidi = pota_lapidi(sorted(lapidi, key=lambda t: t["uid"]))
    voci = _id_unici(voci)

    categorie = _categorie(pc.categories, tel.categories, base_categorie, voci)

    return Fusione(entries=voci, tombstones=lapidi, categories=categorie,
                   sul_pc=_differenze(pc.entries, voci),
                   sul_telefono=_differenze(tel_lista, voci))


def _differenze(prima: List[Credential], dopo: List[Credential]) -> Dict[str, int]:
    a = {c.uid: contenuto(c) for c in prima}
    b = {c.uid: contenuto(c) for c in dopo}
    return {"aggiunte": sum(1 for u in b if u not in a),
            "aggiornate": sum(1 for u in b if u in a and a[u] != b[u]),
            "cancellate": sum(1 for u in a if u not in b)}


def _stesse(a: List[str], b: List[str]) -> bool:
    return [x.casefold() for x in a] == [x.casefold() for x in b]


def _unione(*liste: List[str]) -> List[str]:
    fuori: List[str] = []
    viste = set()
    for lista in liste:
        for c in lista:
            k = c.casefold()
            if c and k not in viste:
                viste.add(k)
                fuori.append(c)
    return fuori


def _categorie(pc: List[str], tel: List[str], base: Optional[List[str]],
               voci: List[Credential]) -> List[str]:
    if base is not None and _stesse(tel, base):
        scelte = list(pc)
    elif base is not None and _stesse(pc, base):
        scelte = list(tel)
    else:
        scelte = _unione(pc, tel)
    return _unione(scelte, [c.category for c in voci if c.category])


def uguali(a: Istantanea, b: Istantanea) -> bool:
    """Stesso contenuto, a meno di `id` e dell'ordine. Serve a non riscrivere
    né mandare niente quando non c'è niente di nuovo: il sync parte spesso, e
    ogni scrittura ri-cifra l'intero vault."""
    return _forma(a) == _forma(b)


def _forma(s: Istantanea) -> str:
    return json.dumps({
        "e": sorted(contenuto(c) for c in s.entries),
        "t": sorted(json.dumps(_lapide(t), sort_keys=True) for t in s.tombstones),
        "c": list(s.categories),
    }, ensure_ascii=False)


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
