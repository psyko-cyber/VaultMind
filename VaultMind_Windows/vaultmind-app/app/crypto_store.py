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

    def public(self) -> dict:
        """Versione senza valori, per liste/ambiguità."""
        return {"id": self.id, "title": self.title, "tags": self.tags,
                "field_labels": [f.label for f in self.fields]}

    def to_dict(self) -> dict:
        return {"id": self.id, "title": self.title, "tags": self.tags,
                "fields": [asdict(f) for f in self.fields]}

    @staticmethod
    def from_dict(d: dict) -> "Credential":
        return Credential(
            id=d["id"], title=d["title"], tags=d.get("tags", []),
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
        """Apre un vault esistente. Solleva WrongPassword se la chiave non torna."""
        with open(self.path, "r", encoding="utf-8") as f:
            blob = json.load(f)
        self._salt = _b64d(blob["kdf"]["salt"])
        key = derive_key(master, self._salt)
        aes = AESGCM(key)
        try:
            plaintext = aes.decrypt(_b64d(blob["nonce"]), _b64d(blob["ciphertext"]), b"vaultmind")
        except Exception as exc:  # tag GCM non valido => password errata o file corrotto
            raise WrongPassword("Master password errata o vault corrotto.") from exc
        data = json.loads(plaintext.decode("utf-8"))
        self._key = key
        self._entries = [Credential.from_dict(c) for c in data.get("credentials", [])]

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
        with open(self.path, "r", encoding="utf-8") as f:
            blob = json.load(f)
        salt = _b64d(blob["kdf"]["salt"])
        try:
            AESGCM(derive_key(old, salt)).decrypt(
                _b64d(blob["nonce"]), _b64d(blob["ciphertext"]), b"vaultmind")
        except Exception as exc:
            raise WrongPassword("La master password attuale non è corretta.") from exc
        # nuova chiave con nuovo salt, poi riscrive
        self._salt = os.urandom(16)
        self._key = derive_key(new, self._salt)
        self._flush()

    # ---------- mutazioni ----------
    def add(self, title: str, fields: List[dict], tags: List[str]) -> Credential:
        """`fields` è una lista di {"label": ..., "value": ...}, in ordine libero."""
        self._require_unlocked()
        new_id = (max((c.id for c in self._entries), default=0)) + 1
        clean_fields = [Field(label=str(f.get("label", "")).strip(), value=str(f.get("value", "")))
                        for f in fields if str(f.get("label", "")).strip() or str(f.get("value", "")).strip()]
        cred = Credential(id=new_id, title=title, fields=clean_fields, tags=tags)
        self._entries.insert(0, cred)
        self._flush()
        return cred

    def delete(self, cred_id: int) -> None:
        self._require_unlocked()
        self._entries = [c for c in self._entries if c.id != cred_id]
        self._flush()

    def clear(self) -> None:
        """Svuota tutte le voci (mantiene il vault e la chiave: resta sbloccato)."""
        self._require_unlocked()
        self._entries = []
        self._flush()

    def update(self, cred_id: int, title: str, fields: List[dict], tags: List[str]) -> Optional[Credential]:
        """Sostituisce titolo/campi/tag di una voce esistente (mantiene id e posizione)."""
        self._require_unlocked()
        cred = self.get(cred_id)
        if cred is None:
            return None
        clean_fields = [Field(label=str(f.get("label", "")).strip(), value=str(f.get("value", "")))
                        for f in fields if str(f.get("label", "")).strip() or str(f.get("value", "")).strip()]
        cred.title = title
        cred.fields = clean_fields
        cred.tags = tags
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


# Credenziali d'esempio (dati volutamente "disordinati") per popolare un vault demo.
# Ogni voce: (titolo, [{"label":..., "value":...}, ...], tag)
SEED = [
    ("amzn prime", [{"label": "Email", "value": "marco.paolo@gmail.com"}, {"label": "Password", "value": "Fr@nco2024!"}],
     ["amazon", "prime", "acquisti", "shopping", "spedizioni"]),
    ("AWS console lavoro", [{"label": "Email", "value": "l.giordano@neten.it"}, {"label": "Password", "value": "kP9$mxQ2vL!a"}],
     ["amazon", "aws", "cloud", "console", "server"]),
    ("quella roba della posta", [{"label": "Email", "value": "marco.paolo@gmail.com"}, {"label": "Password", "value": "Estate!2023"}],
     ["gmail", "email", "posta", "mail", "google"]),
    # Secondo account Google + esempio di 2FA (TOTP): mostra sia il raggruppamento
    # "google account" sia il codice OTP generato in locale. Il secret è di test.
    ("Google lavoro", [{"label": "Email", "value": "l.giordano@gmail.com"},
                       {"label": "Password", "value": "Lavoro#G2025"},
                       {"label": "OTP (2FA)", "value": "JBSWY3DPEHPK3PXP"}],
     ["google", "gmail", "lavoro", "workspace"]),
    ("wifi sala riunioni", [{"label": "SSID", "value": "Neten-Guest"}, {"label": "Password", "value": "Neten2024Guest"}],
     ["rete", "internet", "wireless", "ufficio", "wlan"]),
    ("home banking", [{"label": "Utente", "value": "GIORDANOLU"}, {"label": "Password", "value": "8472-conto-!Q"}],
     ["banca", "conto", "bonifici", "homebanking"]),
    ("netflix famiglia", [{"label": "Email", "value": "famiglia.giordano@gmail.com"}, {"label": "Password", "value": "SerieTV#2022"}],
     ["streaming", "serie", "film", "tv"]),
    ("spotify", [{"label": "Email", "value": "marco.paolo@gmail.com"}, {"label": "Password", "value": "m3l0d1a$$"}],
     ["musica", "premium", "playlist"]),
    ("router di casa (admin)", [{"label": "Utente", "value": "admin"}, {"label": "Password", "value": "adminFastweb!9"}],
     ["rete", "modem", "fastweb", "wifi", "amministrazione"]),
    # Esempio con piu' di due campi: documento d'identità digitale italiano (CIE).
    ("CIE — Carta d'identità elettronica",
     [{"label": "Numero ID", "value": "CA00112233"},
      {"label": "PIN", "value": "4821"},
      {"label": "PUC", "value": "987654321012"},
      {"label": "Telefono associato", "value": "+39 333 1234567"}],
     ["cie", "identita", "documento", "spid", "carta"]),
]


def seed_into(store: "VaultStore") -> None:
    for title, fields, tags in reversed(SEED):
        store.add(title, fields, tags)
