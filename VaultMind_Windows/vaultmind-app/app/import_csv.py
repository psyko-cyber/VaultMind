"""
import_csv.py — Import da export CSV di altri password manager.

Supporta gli export "standard" di:
  - Bitwarden  (login_username, login_password, login_uri, login_totp, name, notes)
  - 1Password  (Title, Username, Password, URL, OTPAuth, Notes)  [export CSV legacy]
  - KeePass    (Title, UserName, Password, URL, Notes, TOTP)     [KeePassXC]
  - Generico   (qualsiasi CSV con colonne riconoscibili: name/title, user, password…)

Il rilevamento del formato è basato sui NOMI delle colonne (case-insensitive),
non sull'ordine: gli export reali variano. Se non riconosce un formato noto,
ripiega su una mappatura generica per nome colonna.

Tutto in locale: legge una stringa CSV e ritorna voci {title, fields, tags}
nello stesso schema dell'import intelligente. Niente viene salvato qui:
l'endpoint propone le voci e l'utente conferma (anteprima editabile).
"""

from __future__ import annotations
import csv
import io
from typing import List, Dict


# Mappa: nome-colonna-normalizzato -> (etichetta nel vault, è_secret)
# La chiave è il nome colonna in minuscolo, senza spazi/underscore.
_COLUMN_MAP = {
    # titolo / nome servizio
    "name": ("__title__", False),
    "title": ("__title__", False),
    "account": ("__title__", False),
    # username / email
    "loginusername": ("Utente", False),
    "username": ("Utente", False),
    "user": ("Utente", False),
    "email": ("Email", False),
    "loginemail": ("Email", False),
    # password
    "loginpassword": ("Password", True),
    "password": ("Password", True),
    "pass": ("Password", True),
    # url / sito
    "loginuri": ("URL", False),
    "url": ("URL", False),
    "uri": ("URL", False),
    "website": ("URL", False),
    # 2FA / TOTP (il secret, non il codice)
    "logintotp": ("OTP (2FA)", True),
    "totp": ("OTP (2FA)", True),
    "otpauth": ("OTP (2FA)", True),
    "otp": ("OTP (2FA)", True),
    # note
    "notes": ("Note", False),
    "note": ("Note", False),
    # tag / cartella di origine -> diventano tag
    "folder": ("__tags__", False),
    "group": ("__tags__", False),
    "tags": ("__tags__", False),
    "collection": ("__tags__", False),
}

# Colonne da IGNORARE del tutto (rumore tipico degli export).
_IGNORE = {
    "type", "favorite", "fields", "reprompt", "revision", "created",
    "modified", "icon", "loginuris", "androidapp",
}


def _norm_col(name: str) -> str:
    return "".join(ch for ch in (name or "").lower() if ch.isalnum())


def _looks_like_otpauth_uri(value: str) -> str:
    """Se il valore è un otpauth://totp/...?secret=XXX estrae solo il secret base32.
    Altrimenti ritorna il valore così com'è (potrebbe essere già un secret)."""
    v = (value or "").strip()
    if v.lower().startswith("otpauth://"):
        import re
        m = re.search(r"[?&]secret=([^&]+)", v, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return v


def detect_format(headers: List[str]) -> str:
    """Identifica il PM di origine dai nomi colonna (best-effort, solo informativo)."""
    cols = {_norm_col(h) for h in headers}
    if "loginpassword" in cols or "loginusername" in cols or "loginuri" in cols:
        return "Bitwarden"
    if "otpauth" in cols and "title" in cols:
        return "1Password"
    if "title" in cols and "username" in cols and "url" in cols:
        return "KeePass"
    return "CSV generico"


def parse_csv(text: str) -> Dict:
    """Analizza una stringa CSV e ritorna {source, entries}.
    `entries` = lista di {title, fields:[{label,value}], tags:[...]}."""
    text = (text or "").lstrip("\ufeff")  # toglie eventuale BOM
    if not text.strip():
        return {"source": "vuoto", "entries": []}

    # Sniff del delimitatore (virgola, punto e virgola, tab).
    sample = text[:4096]
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
    except Exception:
        class _D(csv.Dialect):
            delimiter = ","; quotechar = '"'; doublequote = True
            skipinitialspace = True; lineterminator = "\r\n"; quoting = csv.QUOTE_MINIMAL
        dialect = _D()

    reader = csv.DictReader(io.StringIO(text), dialect=dialect)
    headers = reader.fieldnames or []
    if not headers:
        return {"source": "non riconosciuto", "entries": []}

    source = detect_format(headers)
    entries: List[Dict] = []

    for row in reader:
        title = ""
        fields: List[Dict] = []
        tags: List[str] = []

        for raw_col, raw_val in row.items():
            if raw_col is None:
                continue
            col = _norm_col(raw_col)
            val = (raw_val or "").strip()
            if not val or col in _IGNORE:
                continue

            mapping = _COLUMN_MAP.get(col)
            if mapping is None:
                # colonna sconosciuta ma con valore: la conservo come campo
                # con l'etichetta originale (utile per export 1Password con campi custom)
                fields.append({"label": raw_col.strip().title(), "value": val})
                continue

            label, is_secret = mapping
            if label == "__title__":
                if not title:
                    title = val
            elif label == "__tags__":
                # cartella/gruppo: spezzo su / e , per ricavare più tag
                for t in val.replace("/", ",").split(","):
                    t = t.strip().lower()
                    if t and t not in tags:
                        tags.append(t)
            else:
                if label == "OTP (2FA)":
                    val = _looks_like_otpauth_uri(val)
                fields.append({"label": label, "value": val})

        # scarta righe completamente vuote
        if not title and not fields:
            continue
        if not title:
            # ripiega su Email/Utente/URL come titolo
            cand = next((f["value"] for f in fields
                         if f["label"] in ("Email", "Utente", "URL")), "")
            title = cand or "voce senza titolo"

        # tag automatici dal titolo se nessuno presente
        if not tags:
            base = "".join(ch if ch.isalnum() or ch == " " else " " for ch in title.lower())
            tags = sorted({w for w in base.split() if len(w) >= 3})[:4]

        entries.append({"title": title, "fields": fields, "tags": tags})

    return {"source": source, "entries": entries}
