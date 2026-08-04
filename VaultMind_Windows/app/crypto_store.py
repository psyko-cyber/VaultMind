"""
crypto_store.py — Vault cifrato locale.

Modello di sicurezza:
  - La master password NON viene mai salvata.
  - Dalla master password si deriva una chiave a 256 bit con Argon2id.
  - Le credenziali sono serializzate in JSON e cifrate con AES-256-GCM.
  - Il file su disco contiene solo: salt KDF, nonce e ciphertext (più tag GCM).
  - In RAM teniamo solo la chiave derivata per la durata della sessione.

Nessun dato lascia il dispositivo: questo modulo scrive/legge un singolo file.
"""

from __future__ import annotations
import os
import json
import base64
import tempfile
import time
import uuid
from dataclasses import dataclass, field, asdict
from typing import List, Optional

from argon2.low_level import hash_secret_raw, Type
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Parametri Argon2id (bilanciati per un'app desktop; alzabili in produzione)
ARGON2_TIME = 3
ARGON2_MEMORY = 64 * 1024  # 64 MB
ARGON2_PARALLELISM = 2
KEY_LEN = 32  # 256 bit


def _b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def _b64d(s: str) -> bytes:
    return base64.b64decode(s.encode("ascii"))


def _norm_category(name: str) -> str:
    """Nome di categoria ripulito: spazi normalizzati, maiuscole com'è stato
    scritto. Il confronto è senza maiuscole (vedi _find_category), la resa a
    schermo no: chi scrive «Banche» vuole leggere «Banche»."""
    return " ".join(str(name or "").split())


def _clean_tombstones(raw) -> List[dict]:
    """Normalizza le lapidi lette dal file: `uid` obbligatorio, il resto con un
    valore di ripiego. Una lapide malformata si scarta invece di far fallire
    l'apertura: una riga rotta qui non vale il vault intero."""
    out: List[dict] = []
    visti = set()
    for t in (raw or []):
        if not isinstance(t, dict):
            continue
        uid = str(t.get("uid") or "").strip()
        if not uid or uid in visti:
            continue
        visti.add(uid)
        out.append({"uid": uid,
                    "rev": int(t.get("rev") or 1),
                    "mod": int(t.get("mod") or 0)})
    return out


def _clean_categories(raw) -> List[str]:
    """Normalizza la lista letta dal file: via i vuoti e i doppioni, l'ordine
    è quello scelto dall'utente e va conservato."""
    out: List[str] = []
    viste = set()
    for c in (raw or []):
        nome = _norm_category(c)
        if nome and nome.casefold() not in viste:
            viste.add(nome.casefold())
            out.append(nome)
    return out


@dataclass
class Field:
    """Un campo libero: etichetta + valore (es. {label:'PUC', value:'123456'})."""
    label: str
    value: str


# Le chiavi di una voce che QUESTA versione conosce. Tutto il resto viene
# ricopiato tale e quale: da quando anche il telefono scrive il vault, una
# versione più vecchia che incontra un campo aggiunto dopo lo cancellerebbe in
# silenzio al primo salvataggio. È il modo in cui il sync (TODO §2) perderebbe
# i timestamp appena introdotti.
_CRED_KEYS = {"id", "title", "fields", "tags", "critical", "category",
              "uid", "rev", "mod"}

# Quanto si conservano le lapidi delle voci cancellate. Un dispositivo rimasto
# staccato più a lungo di così si ripresenterebbe con la voce ancora viva e la
# farebbe resuscitare: sei mesi sono un compromesso fra questo e una lista che
# cresce per sempre.
TOMBSTONE_DAYS = 180


def now_ms() -> int:
    """Ora vera in millisecondi.

    Serve a MOSTRARE quando una voce è cambiata e come spareggio estremo, non
    a decidere chi vince: due dispositivi con l'orologio sfasato deciderebbero
    male. Per quello c'è `rev`, che è un contatore e non un orologio.
    """
    return int(time.time() * 1000)


def uid_derivato(cred_id: int) -> str:
    """L'identificativo di una voce che esisteva PRIMA che gli uid esistessero.

    Non può essere casuale: il PC e il telefono lo genererebbero diverso per la
    stessa identica voce, e al primo sync quella voce diventerebbe due voci.
    Si ricava invece dal numero che la voce ha già — che è lo stesso su tutte le
    copie dello stesso vault, perché gli id non cambiano mai dopo l'inserimento.

    (Due vault *diversi* avrebbero uid derivati che si scontrano, ma due vault
    diversi non si sincronizzano: hanno master password diverse e non
    superano nemmeno l'abbinamento.)
    """
    return f"#{cred_id}"


@dataclass
class Credential:
    id: int
    title: str
    fields: List[Field] = field(default_factory=list)
    tags: List[str] = field(default_factory=list)
    # Account da cui si può rimettere le mani su tutto il resto (banca, email
    # principale). Serve a segnalare quando password e secondo fattore finiscono
    # nello stesso posto: da quel momento il 2FA non è più un fattore separato.
    critical: bool = False
    # Categoria scelta A MANO, una sola per voce: assegnarne un'altra la sposta.
    # Vuota = nessuna categoria. Non viene mai dedotta dai tag: i tag di un
    # import sono spesso parole ricavate dal titolo, e raggrupparci sopra
    # produrrebbe centinaia di sezioni da una voce sola.
    category: str = ""
    # ---- identità e storia della voce, per il sync (TODO §2) ----
    # Identificativo stabile e unico, che sopravvive alla copia del vault da un
    # dispositivo all'altro. Vuoto = si ricava da `id` (vedi uid_derivato).
    uid: str = ""
    # Contatore logico: cresce di uno a ogni modifica di QUESTA voce. È lui a
    # dire chi è più avanti, non l'orologio.
    rev: int = 1
    # Ora dell'ultima modifica, in millisecondi. Da mostrare all'utente.
    mod: int = 0
    # Chiavi lette dal file ma sconosciute a questa versione (vedi _CRED_KEYS).
    extra: dict = field(default_factory=dict)

    def __post_init__(self):
        if not self.uid:
            self.uid = uid_derivato(self.id)

    def tocca(self) -> None:
        """Segna la voce come modificata adesso. Da chiamare a ogni cambiamento
        del suo contenuto, altrimenti il sync non si accorge che è cambiata."""
        self.rev += 1
        self.mod = now_ms()

    def public(self) -> dict:
        """Versione senza valori, per liste/ambiguità."""
        return {"id": self.id, "title": self.title, "tags": self.tags,
                "critical": self.critical, "category": self.category,
                "field_labels": [f.label for f in self.fields]}

    def to_dict(self) -> dict:
        d = dict(self.extra)  # gli sconosciuti per primi: le chiavi note vincono
        d.update({"id": self.id, "title": self.title, "tags": self.tags,
                  "critical": self.critical,
                  "fields": [asdict(f) for f in self.fields]})
        # I campi opzionali si scrivono solo se dicono qualcosa. Così un vault
        # mai toccato dopo l'aggiornamento resta byte per byte quello di prima,
        # e il vettore di prova continua a valere senza rigenerarlo.
        if self.category:
            d["category"] = self.category
        if self.uid != uid_derivato(self.id):
            d["uid"] = self.uid
        if self.rev != 1:
            d["rev"] = self.rev
        if self.mod:
            d["mod"] = self.mod
        return d

    @staticmethod
    def from_dict(d: dict) -> "Credential":
        # I campi aggiunti nel tempo mancano nei vault creati prima: assenti
        # valgono il loro valore predefinito, mai un errore. `uid` assente si
        # ricava dall'id (vedi uid_derivato), `rev` assente vale 1.
        return Credential(
            id=d["id"], title=d["title"], tags=d.get("tags", []),
            critical=bool(d.get("critical", False)),
            category=str(d.get("category") or "").strip(),
            uid=str(d.get("uid") or ""),
            rev=int(d.get("rev") or 1),
            mod=int(d.get("mod") or 0),
            fields=[Field(label=f.get("label", ""), value=f.get("value", "")) for f in d.get("fields", [])],
            extra={k: v for k, v in d.items() if k not in _CRED_KEYS},
        )


def derive_key(master: str, salt: bytes) -> bytes:
    return hash_secret_raw(
        secret=master.encode("utf-8"),
        salt=salt,
        time_cost=ARGON2_TIME,
        memory_cost=ARGON2_MEMORY,
        parallelism=ARGON2_PARALLELISM,
        hash_len=KEY_LEN,
        type=Type.ID,
    )


class WrongPassword(Exception):
    pass


class VaultCorrupted(Exception):
    """Il file non è un vault leggibile: JSON rotto, troncato, campi mancanti.

    Distinto da WrongPassword perché le due cose chiedono all'utente azioni
    OPPOSTE: con la password sbagliata si riprova, con un file danneggiato si
    ripristina un backup — e riprovare la password all'infinito su un file
    rotto è il modo peggiore di scoprirlo.

    Attenzione: un fallimento del tag GCM resta `WrongPassword`, perché
    password sbagliata e ciphertext manomesso sono crittograficamente
    indistinguibili. Qui finisce solo ciò che si vede PRIMA di decifrare.
    """
    pass


def _leggi_blob(path: str) -> dict:
    """Legge il file del vault e verifica che abbia la forma attesa."""
    # Cattura larga di proposito: un file danneggiato può avere QUALSIASI forma
    # (chiavi mancanti, `null`, numeri al posto di stringhe, base64 invalido) e
    # ognuna solleva un'eccezione diversa. Da qualunque di esse la conclusione
    # per l'utente è una sola: "questo file non è un vault utilizzabile".
    # Elencare i tipi uno per uno ha già lasciato passare un AttributeError.
    try:
        with open(path, "r", encoding="utf-8") as f:
            blob = json.load(f)
        salt = _b64d(blob["kdf"]["salt"])
        nonce = _b64d(blob["nonce"])
        ciphertext = _b64d(blob["ciphertext"])
    except OSError:
        raise                       # file assente o illeggibile: non è corruzione
    except Exception as exc:
        raise VaultCorrupted(
            "Il file del vault non è leggibile (danneggiato o incompleto)."
        ) from exc
    return {"salt": salt, "nonce": nonce, "ciphertext": ciphertext}


def apri_blob(testo: str, chiave: bytes) -> dict:
    """Apre un vault **ricevuto da un altro dispositivo**, con la chiave che
    abbiamo già in memoria.

    Serve al sync: quello che viaggia sulla rete è il file cifrato tale e quale,
    e chi lo riceve lo apre come aprirebbe il proprio. In chiaro non passa mai
    niente, nemmeno dentro un canale autenticato.

    Solleva `WrongPassword` se la chiave non torna — nel sync vuol dire che i
    due vault hanno master password diverse — e `VaultCorrupted` se non è
    nemmeno un vault.
    """
    try:
        blob = json.loads(testo)
        salt = _b64d(blob["kdf"]["salt"])  # letto ma non usato: la chiave è la nostra
        nonce = _b64d(blob["nonce"])
        ciphertext = _b64d(blob["ciphertext"])
        del salt
    except Exception as exc:
        raise VaultCorrupted("Il vault ricevuto non è leggibile.") from exc
    try:
        chiaro = AESGCM(chiave).decrypt(nonce, ciphertext, b"vaultmind")
    except Exception as exc:
        raise WrongPassword("Il vault ricevuto è cifrato con un'altra chiave.") from exc
    try:
        dati = json.loads(chiaro.decode("utf-8"))
        if not isinstance(dati, dict):
            raise ValueError("non è un oggetto")
    except Exception as exc:
        raise VaultCorrupted("Il contenuto del vault ricevuto non è leggibile.") from exc
    return dati


class VaultStore:
    """Gestisce un file vault cifrato. Tiene la chiave in RAM dopo unlock()."""

    def __init__(self, path: str):
        self.path = path
        self._key: Optional[bytes] = None
        self._salt: Optional[bytes] = None
        self._entries: List[Credential] = []
        self._categories: List[str] = []
        # Lapidi: cosa è stato cancellato e quando. Senza, una voce cancellata
        # qui verrebbe rimandata indietro dall'altro dispositivo — che ce l'ha
        # ancora — e resusciterebbe al primo sync.
        self._tombstones: List[dict] = []
        # Chiavi del contenuto in chiaro che questa versione non conosce:
        # stessa ragione di Credential.extra, un piano più su.
        self._root_extra: dict = {}

    # ---------- stato ----------
    def exists(self) -> bool:
        return os.path.exists(self.path)

    @property
    def unlocked(self) -> bool:
        return self._key is not None

    @property
    def entries(self) -> List[Credential]:
        return list(self._entries)

    @property
    def categories(self) -> List[str]:
        return list(self._categories)

    @property
    def tombstones(self) -> List[dict]:
        return [dict(t) for t in self._tombstones]

    # ---------- creazione / apertura ----------
    def create(self, master: str) -> None:
        """Crea un vault nuovo (vuoto) cifrato con la master password."""
        self._salt = os.urandom(16)
        self._key = derive_key(master, self._salt)
        self._entries = []
        self._categories = []
        self._tombstones = []
        self._root_extra = {}
        self._flush()

    def unlock(self, master: str) -> None:
        """Apre un vault esistente.

        Solleva WrongPassword se la chiave non torna, VaultCorrupted se il file
        non è nemmeno un vault leggibile. Non scrive MAI: un tentativo fallito
        non deve poter danneggiare l'unica copia delle password.
        """
        blob = _leggi_blob(self.path)
        salt = blob["salt"]
        key = derive_key(master, salt)
        try:
            plaintext = AESGCM(key).decrypt(blob["nonce"], blob["ciphertext"], b"vaultmind")
        except Exception as exc:  # tag GCM non valido => password errata o file manomesso
            raise WrongPassword("Master password errata o vault corrotto.") from exc
        try:
            data = json.loads(plaintext.decode("utf-8"))
            entries = [Credential.from_dict(c) for c in data.get("credentials", [])]
            # Le categorie stanno nel vault, e non si deducono dalle voci: una
            # appena creata è ancora vuota, e dedurla la farebbe sparire fra il
            # momento in cui la crei e quello in cui la riempi.
            categories = _clean_categories(data.get("categories", []))
            tombstones = _clean_tombstones(data.get("deleted", []))
        except Exception as exc:
            # Il tag GCM è tornato ma il contenuto non ha la forma attesa: non è
            # un file di qualcun altro, è un vault nostro scritto male. Non si
            # tocca niente e non si apre a metà.
            #
            # Cattura larga per la stessa ragione di _leggi_blob(): elencare i
            # tipi uno per uno aveva già lasciato passare un AttributeError.
            # Qui succede con un contenuto che è JSON valido ma non un oggetto
            # (`[]`, `"ciao"`): `.get()` non esiste e l'errore usciva grezzo.
            raise VaultCorrupted("Il contenuto del vault non è leggibile.") from exc
        self._salt = salt
        self._key = key
        self._entries = entries
        self._categories = categories
        self._tombstones = tombstones
        self._root_extra = {k: v for k, v in data.items()
                            if k not in ("credentials", "categories", "deleted")}

    def lock(self) -> None:
        self._key = None
        self._salt = None
        self._entries = []
        self._categories = []
        self._tombstones = []
        self._root_extra = {}

    def change_master(self, old: str, new: str) -> None:
        """Cambia la master password: verifica la vecchia, ri-deriva una nuova
        chiave con un nuovo salt e riscrive il vault. Le voci restano identiche.
        Solleva WrongPassword se la vecchia password non è corretta."""
        if not self.unlocked:
            raise WrongPassword("Vault bloccato.")
        # verifica la vecchia rileggendo il file con essa
        blob = _leggi_blob(self.path)
        try:
            AESGCM(derive_key(old, blob["salt"])).decrypt(
                blob["nonce"], blob["ciphertext"], b"vaultmind")
        except Exception as exc:
            raise WrongPassword("La master password attuale non è corretta.") from exc
        # nuova chiave con nuovo salt, poi riscrive
        self._salt = os.urandom(16)
        self._key = derive_key(new, self._salt)
        self._flush()

    # ---------- mutazioni ----------
    @staticmethod
    def _clean_fields(fields: List[dict]) -> List[Field]:
        """Scarta i campi del tutto vuoti e normalizza etichetta/valore."""
        return [Field(label=str(f.get("label", "")).strip(), value=str(f.get("value", "")))
                for f in fields if str(f.get("label", "")).strip() or str(f.get("value", "")).strip()]

    def _resolve_category(self, name: str) -> str:
        """Il nome della categoria come è registrato, o "" se non se ne vuole una.

        Una categoria dev'essere già stata creata per poterci mettere dentro
        qualcosa: se assegnarne una inesistente la creasse, un errore di
        battitura produrrebbe una categoria nuova invece di un errore — ed è
        proprio l'automatismo che qui non vogliamo.
        """
        if not _norm_category(name):
            return ""
        esistente = self._find_category(name)
        if esistente is None:
            raise ValueError(f"La categoria «{_norm_category(name)}» non esiste.")
        return esistente

    def add(self, title: str, fields: List[dict], tags: List[str],
            critical: bool = False, category: str = "") -> Credential:
        """`fields` è una lista di {"label": ..., "value": ...}, in ordine libero.
        L'ordine dei campi è quello scelto dall'utente e viene conservato."""
        self._require_unlocked()
        cat = self._resolve_category(category)
        new_id = (max((c.id for c in self._entries), default=0)) + 1
        # uid casuale, non ricavato dall'id: due dispositivi scollegati che
        # aggiungono una voce prendono ENTRAMBI lo stesso `id` (max+1), e senza
        # un identificativo davvero unico al primo sync una delle due sparirebbe.
        cred = Credential(id=new_id, title=title, fields=self._clean_fields(fields),
                          tags=tags, critical=critical, category=cat,
                          uid=uuid.uuid4().hex, mod=now_ms())
        self._entries.insert(0, cred)
        self._flush()
        return cred

    def add_many(self, items: List[dict]) -> List[Credential]:
        """Inserisce più voci con UNA sola riscrittura del vault.

        Perché esiste: _flush() ri-serializza e ri-cifra l'INTERO vault a ogni
        chiamata. Importando un CSV voce per voce il costo diventa quadratico
        (800 voci = 800 cifrature di un file che nel frattempo cresce), ed è la
        ragione per cui l'import di un export Bitwarden impiegava minuti.
        Qui cifratura e scrittura su disco avvengono una volta sola.

        `items` = [{"title":…, "fields":[{"label","value"}…], "tags":[…]}, …]
        L'ordine finale è identico a quello di add() chiamata in sequenza.
        """
        self._require_unlocked()
        next_id = (max((c.id for c in self._entries), default=0)) + 1
        adesso = now_ms()
        creds: List[Credential] = []
        for it in items:
            creds.append(Credential(
                id=next_id,
                title=str(it.get("title", "")),
                fields=self._clean_fields(it.get("fields") or []),
                tags=list(it.get("tags") or []),
                critical=bool(it.get("critical", False)),
                category=self._resolve_category(it.get("category", "")),
                uid=uuid.uuid4().hex,
                mod=adesso,
            ))
            next_id += 1
        # ogni voce entrerebbe in testa una alla volta: il risultato è l'inverso
        self._entries[0:0] = list(reversed(creds))
        self._flush()
        return creds

    def _seppellisci(self, cred: Credential) -> None:
        """Registra la lapide di una voce cancellata.

        `rev` della lapide è quello della voce **più uno**: la cancellazione è
        essa stessa una modifica, e deve battere la copia ancora viva
        sull'altro dispositivo — altrimenti il sync la rimanderebbe indietro e
        la voce resusciterebbe.
        """
        self._tombstones = [t for t in self._tombstones if t["uid"] != cred.uid]
        self._tombstones.append(
            {"uid": cred.uid, "rev": cred.rev + 1, "mod": now_ms()})

    def delete(self, cred_id: int) -> None:
        self._require_unlocked()
        voce = self.get(cred_id)
        self._entries = [c for c in self._entries if c.id != cred_id]
        if voce is not None:
            self._seppellisci(voce)
        self._flush()

    def clear(self) -> None:
        """Svuota tutte le voci (mantiene il vault e la chiave: resta sbloccato)."""
        self._require_unlocked()
        for c in self._entries:
            self._seppellisci(c)
        self._entries = []
        self._flush()

    def update(self, cred_id: int, title: str, fields: List[dict], tags: List[str],
               critical: bool = False, category: str = "") -> Optional[Credential]:
        """Sostituisce titolo/campi/tag di una voce esistente (mantiene id e posizione)."""
        self._require_unlocked()
        cred = self.get(cred_id)
        if cred is None:
            return None
        cat = self._resolve_category(category)
        cred.title = title
        cred.fields = self._clean_fields(fields)
        cred.tags = tags
        cred.critical = critical
        cred.category = cat
        cred.tocca()
        self._flush()
        return cred

    def get(self, cred_id: int) -> Optional[Credential]:
        return next((c for c in self._entries if c.id == cred_id), None)

    # ---------- categorie ----------
    # Raggruppamenti scelti a mano dall'utente. Vivono nel vault, non nelle
    # preferenze, perché sono lavoro suo e devono viaggiare col backup: chi
    # riordina 800 voci sul PC se le ritrova già in ordine sul telefono.

    def _find_category(self, name: str) -> Optional[str]:
        """La categoria registrata che corrisponde a `name`, senza guardare le
        maiuscole: chi cerca «banche» deve ritrovare la sua «Banche»."""
        n = _norm_category(name).casefold()
        if not n:
            return None
        return next((c for c in self._categories if c.casefold() == n), None)

    def add_category(self, name: str) -> str:
        """Crea una categoria vuota e ne restituisce il nome registrato.

        Se esiste già (anche scritta con altre maiuscole) non la duplica: torna
        quella. Serve poterla creare vuota, perché la si riempie dopo.
        """
        self._require_unlocked()
        nome = _norm_category(name)
        if not nome:
            raise ValueError("Il nome della categoria non può essere vuoto.")
        esistente = self._find_category(nome)
        if esistente is not None:
            return esistente
        self._categories.append(nome)
        self._flush()
        return nome

    def rename_category(self, old: str, new: str) -> Optional[str]:
        """Rinomina la categoria e tutte le voci che la portano, con UNA sola
        riscrittura del vault. Torna None se `old` non esiste."""
        self._require_unlocked()
        vecchia = self._find_category(old)
        if vecchia is None:
            return None
        nuova = _norm_category(new)
        if not nuova:
            raise ValueError("Il nome della categoria non può essere vuoto.")
        altra = self._find_category(nuova)
        if altra is not None and altra != vecchia:
            raise ValueError(f"Esiste già una categoria «{altra}».")
        self._categories = [nuova if c == vecchia else c for c in self._categories]
        for c in self._entries:
            if c.category == vecchia:
                c.category = nuova
                c.tocca()
        self._flush()
        return nuova

    def delete_category(self, name: str) -> int:
        """Elimina la categoria e restituisce quante voci ne sono uscite.

        Le voci NON si toccano: restano nel vault senza categoria. Cancellare
        un raggruppamento non può cancellare le password che raggruppava — è
        l'errore che l'utente non può permettersi di fare per sbaglio.
        """
        self._require_unlocked()
        vecchia = self._find_category(name)
        if vecchia is None:
            return 0
        self._categories = [c for c in self._categories if c != vecchia]
        liberate = 0
        for c in self._entries:
            if c.category == vecchia:
                c.category = ""
                c.tocca()
                liberate += 1
        self._flush()
        return liberate

    def set_category(self, cred_ids: List[int], name: str) -> int:
        """Assegna la categoria a più voci in un colpo solo; `name` vuoto la
        toglie. Torna quante voci sono cambiate davvero.

        Una sola riscrittura per la stessa ragione di add_many(): _flush()
        ri-cifra l'INTERO vault, e assegnare 200 voci una per una vorrebbe dire
        200 cifrature di un file che le contiene tutte.
        """
        self._require_unlocked()
        cat = self._resolve_category(name)
        voluti = set(cred_ids)
        toccate = 0
        for c in self._entries:
            if c.id in voluti and c.category != cat:
                c.category = cat
                c.tocca()
                toccate += 1
        # Niente da cambiare, niente da riscrivere: ri-cifrare l'intero vault
        # per un'assegnazione che non sposta nulla è puro spreco.
        if toccate:
            self._flush()
        return toccate

    # ---------- sync ----------

    @property
    def chiave(self) -> Optional[bytes]:
        """La chiave in RAM. La usa il sync per aprire il vault che arriva
        dall'altro dispositivo — mai per mandarla in giro."""
        return self._key

    @property
    def salt(self) -> Optional[bytes]:
        """Il salt del file. Non è segreto: si manda a un dispositivo nuovo
        perché possa derivare la chiave dalla master password."""
        return self._salt

    def applica_fusione(self, entries: List[Credential], tombstones: List[dict],
                        categories: List[str]) -> None:
        """Sostituisce il contenuto col risultato di una fusione, in **una sola
        riscrittura**. Il metodo esiste apposta perché non ci sia un momento in
        cui il vault è mezzo fuso: o c'è tutto il nuovo, o è rimasto il vecchio.
        """
        self._require_unlocked()
        self._entries = list(entries)
        self._tombstones = [dict(t) for t in tombstones]
        self._categories = _clean_categories(categories)
        self._flush()

    def count_by_category(self) -> dict:
        """Quante voci per categoria, comprese quelle vuote (che devono
        comparire lo stesso: una categoria appena creata è vuota per
        definizione). La chiave "" conta le voci senza categoria."""
        conteggio = {c: 0 for c in self._categories}
        conteggio[""] = 0
        for c in self._entries:
            conteggio[c.category] = conteggio.get(c.category, 0) + 1
        return conteggio

    # ---------- persistenza ----------
    def _require_unlocked(self):
        if not self.unlocked:
            raise RuntimeError("Vault bloccato: serve unlock() o create().")

    def _pota_lapidi(self) -> None:
        """Butta via le lapidi troppo vecchie. Qui e non a ogni cancellazione:
        svuotando un vault da 800 voci si potrebbe una volta sola invece di 800.

        Una lapide senza `mod` (arrivata da un file scritto male) si tiene: nel
        dubbio è meglio una lapide di troppo che una voce che resuscita.
        """
        limite = now_ms() - TOMBSTONE_DAYS * 24 * 60 * 60 * 1000
        self._tombstones = [t for t in self._tombstones
                            if not t["mod"] or t["mod"] >= limite]

    def _flush(self) -> None:
        self._require_unlocked()
        self._pota_lapidi()
        contenuto = dict(self._root_extra)  # prima gli sconosciuti, poi i nostri
        contenuto["credentials"] = [c.to_dict() for c in self._entries]
        # Come per `category` sulla voce: le liste si scrivono solo se ci sono,
        # così un vault che non le usa resta identico a prima che esistessero.
        if self._categories:
            contenuto["categories"] = list(self._categories)
        if self._tombstones:
            contenuto["deleted"] = list(self._tombstones)
        payload = json.dumps(contenuto).encode("utf-8")
        nonce = os.urandom(12)
        aes = AESGCM(self._key)
        ciphertext = aes.encrypt(nonce, payload, b"vaultmind")
        blob = {
            "version": 1,
            "kdf": {
                "alg": "argon2id",
                "salt": _b64e(self._salt),
                "time_cost": ARGON2_TIME,
                "memory_cost": ARGON2_MEMORY,
                "parallelism": ARGON2_PARALLELISM,
            },
            "cipher": "aes-256-gcm",
            "nonce": _b64e(nonce),
            "ciphertext": _b64e(ciphertext),
        }
        # scrittura atomica: tmp file + rename
        d = os.path.dirname(os.path.abspath(self.path)) or "."
        fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(blob, f)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)


# Nessun dato di esempio: un vault appena creato deve essere VUOTO.
# Le vecchie 10 voci demo (password inventate, indirizzi verosimili) erano utili
# per le dimostrazioni, ma chi installa l'app per la prima volta si trovava il
# database gia' sporco e doveva ripulirlo a mano.
