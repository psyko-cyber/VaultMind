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


@dataclass
class Field:
    """Un campo libero: etichetta + valore (es. {label:'PUC', value:'123456'})."""
    label: str
    value: str


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

    def public(self) -> dict:
        """Versione senza valori, per liste/ambiguità."""
        return {"id": self.id, "title": self.title, "tags": self.tags,
                "critical": self.critical,
                "field_labels": [f.label for f in self.fields]}

    def to_dict(self) -> dict:
        return {"id": self.id, "title": self.title, "tags": self.tags,
                "critical": self.critical,
                "fields": [asdict(f) for f in self.fields]}

    @staticmethod
    def from_dict(d: dict) -> "Credential":
        # `critical` manca nei vault creati prima: assente = non critica
        return Credential(
            id=d["id"], title=d["title"], tags=d.get("tags", []),
            critical=bool(d.get("critical", False)),
            fields=[Field(label=f.get("label", ""), value=f.get("value", "")) for f in d.get("fields", [])],
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


class VaultStore:
    """Gestisce un file vault cifrato. Tiene la chiave in RAM dopo unlock()."""

    def __init__(self, path: str):
        self.path = path
        self._key: Optional[bytes] = None
        self._salt: Optional[bytes] = None
        self._entries: List[Credential] = []

    # ---------- stato ----------
    def exists(self) -> bool:
        return os.path.exists(self.path)

    @property
    def unlocked(self) -> bool:
        return self._key is not None

    @property
    def entries(self) -> List[Credential]:
        return list(self._entries)

    # ---------- creazione / apertura ----------
    def create(self, master: str) -> None:
        """Crea un vault nuovo (vuoto) cifrato con la master password."""
        self._salt = os.urandom(16)
        self._key = derive_key(master, self._salt)
        self._entries = []
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
        except (json.JSONDecodeError, KeyError, TypeError, UnicodeDecodeError) as exc:
            # Il tag GCM è tornato ma il contenuto non ha la forma attesa: non è
            # un file di qualcun altro, è un vault nostro scritto male. Non si
            # tocca niente e non si apre a metà.
            raise VaultCorrupted("Il contenuto del vault non è leggibile.") from exc
        self._salt = salt
        self._key = key
        self._entries = entries

    def lock(self) -> None:
        self._key = None
        self._salt = None
        self._entries = []

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

    def add(self, title: str, fields: List[dict], tags: List[str],
            critical: bool = False) -> Credential:
        """`fields` è una lista di {"label": ..., "value": ...}, in ordine libero.
        L'ordine dei campi è quello scelto dall'utente e viene conservato."""
        self._require_unlocked()
        new_id = (max((c.id for c in self._entries), default=0)) + 1
        cred = Credential(id=new_id, title=title, fields=self._clean_fields(fields),
                          tags=tags, critical=critical)
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
        creds: List[Credential] = []
        for it in items:
            creds.append(Credential(
                id=next_id,
                title=str(it.get("title", "")),
                fields=self._clean_fields(it.get("fields") or []),
                tags=list(it.get("tags") or []),
                critical=bool(it.get("critical", False)),
            ))
            next_id += 1
        # ogni voce entrerebbe in testa una alla volta: il risultato è l'inverso
        self._entries[0:0] = list(reversed(creds))
        self._flush()
        return creds

    def delete(self, cred_id: int) -> None:
        self._require_unlocked()
        self._entries = [c for c in self._entries if c.id != cred_id]
        self._flush()

    def clear(self) -> None:
        """Svuota tutte le voci (mantiene il vault e la chiave: resta sbloccato)."""
        self._require_unlocked()
        self._entries = []
        self._flush()

    def update(self, cred_id: int, title: str, fields: List[dict], tags: List[str],
               critical: bool = False) -> Optional[Credential]:
        """Sostituisce titolo/campi/tag di una voce esistente (mantiene id e posizione)."""
        self._require_unlocked()
        cred = self.get(cred_id)
        if cred is None:
            return None
        cred.title = title
        cred.fields = self._clean_fields(fields)
        cred.tags = tags
        cred.critical = critical
        self._flush()
        return cred

    def get(self, cred_id: int) -> Optional[Credential]:
        return next((c for c in self._entries if c.id == cred_id), None)

    # ---------- persistenza ----------
    def _require_unlocked(self):
        if not self.unlocked:
            raise RuntimeError("Vault bloccato: serve unlock() o create().")

    def _flush(self) -> None:
        self._require_unlocked()
        payload = json.dumps({"credentials": [c.to_dict() for c in self._entries]}).encode("utf-8")
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
