"""
import_csv.py — Import da export CSV di altri password manager.

Supporta gli export "standard" di:
  - Bitwarden  (login_username, login_password, login_uri, login_totp, name, notes)
  - 1Password  (Title, Username, Password, URL, OTPAuth, Notes)  [export CSV legacy]
  - KeePass    (Title, UserName, Password, URL, Notes, TOTP)     [KeePassXC]
  - Chrome / Google Password Manager / Edge (name, url, username, password, note)
  - Firefox    (url, username, password, httpRealm, guid, time…)
  - LastPass   (url, username, password, totp, extra, name, grouping, fav)
  - Apple Passwords, Proton Pass, Dashlane, NordPass: colonne con nomi
    riconoscibili, passano dalla stessa mappa
  - Generico   (qualsiasi CSV con colonne riconoscibili: name/title, user, password…)

**Il telefono ha lo stesso parser** (`mobile/lib/import_csv.dart`): chi ha
solo il telefono non ha Ollama, ma un export CSV ce l'ha come chiunque. I due
si tengono allineati coi file di `tests/vettore/import/` e il loro
`atteso.json`, scritto da questo modulo (`tests/test_import_csv.py --scrivi`):
una colonna nuova qui va aggiunta anche là, o il test Dart lo dice.

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
    # le stesse in italiano: il CSV fatto a mano in Excel da una PMI
    "servizio": ("__title__", False),
    "titolo": ("__title__", False),
    "nome": ("__title__", False),
    # username / email
    "loginusername": ("Utente", False),
    "username": ("Utente", False),
    "user": ("Utente", False),
    "utente": ("Utente", False),
    "nomeutente": ("Utente", False),
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
    "sito": ("URL", False),
    "indirizzo": ("URL", False),
    # 2FA / TOTP (il secret, non il codice)
    "logintotp": ("OTP (2FA)", True),
    "otpsecret": ("OTP (2FA)", True),      # Dashlane
    "totp": ("OTP (2FA)", True),
    "otpauth": ("OTP (2FA)", True),
    "otp": ("OTP (2FA)", True),
    # note
    "notes": ("Note", False),
    "note": ("Note", False),
    "nota": ("Note", False),
    "extra": ("Note", False),              # LastPass
    # tag / cartella di origine -> diventano tag
    "folder": ("__tags__", False),
    "group": ("__tags__", False),
    "tags": ("__tags__", False),
    "collection": ("__tags__", False),
    "grouping": ("__tags__", False),       # LastPass
    "category": ("__tags__", False),       # Dashlane
    "cartella": ("__tags__", False),
    "gruppo": ("__tags__", False),
    "categoria": ("__tags__", False),
}

# Colonne da IGNORARE del tutto (rumore tipico degli export).
_IGNORE = {
    "type", "favorite", "fields", "reprompt", "revision", "created",
    "modified", "icon", "loginuris", "androidapp",
    "lastmodified",                                  # KeePassXC
    "fav",                                           # LastPass
    "httprealm", "formactionorigin", "guid",         # Firefox
    "timecreated", "timelastused", "timepasswordchanged",
    "createtime", "modifytime", "vault",             # Proton Pass
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


def _host(url: str) -> str:
    """`https://www.amazon.it/login` -> `amazon.it`: il nome che una persona
    darebbe alla voce. Chrome e Firefox a volte non esportano un nome."""
    v = (url or "").strip()
    if "://" in v:
        v = v.split("://", 1)[1]
    v = v.split("/", 1)[0].split("?", 1)[0].split("@")[-1].split(":", 1)[0]
    v = v.lower()
    return v[4:] if v.startswith("www.") else v


# Il gruppo radice di KeePass: ce l'hanno tutte le voci, come tag non dice niente.
_TAG_RADICE = {"root", "radice"}

# LastPass mette questo finto indirizzo sulle note sicure.
_URL_FINTI = {"http://sn"}


def _separatore(text: str) -> str:
    """Virgola, punto e virgola o tab: quello che compare più volte nella riga
    delle intestazioni, fuori dalle virgolette.

    Prima qui c'era `csv.Sniffer`, che indovina anche le virgolette: davanti a
    una password come `"Pa,ss""word1"` decideva che `""` non era un escape e
    la importava con una virgoletta in più. Del dialetto serve solo il
    separatore; il resto è lo standard (RFC 4180) che tutti gli export usano.
    La stessa regola sta in `import_csv.dart`.
    """
    conta = {",": 0, ";": 0, "\t": 0}
    dentro = False
    for ch in text:
        if ch == '"':
            dentro = not dentro
        elif not dentro and ch in "\r\n":
            break
        elif not dentro and ch in conta:
            conta[ch] += 1
    migliore = max(conta, key=lambda k: conta[k])  # a pari merito la virgola
    return migliore if conta[migliore] else ","


def detect_format(headers: List[str]) -> str:
    """Identifica il PM di origine dai nomi colonna (best-effort, solo informativo)."""
    cols = {_norm_col(h) for h in headers}
    if "loginpassword" in cols or "loginusername" in cols or "loginuri" in cols:
        return "Bitwarden"
    if "grouping" in cols or "extra" in cols:
        return "LastPass"
    if "httprealm" in cols or "formactionorigin" in cols:
        return "Firefox"
    if "otpauth" in cols and "title" in cols:
        return "1Password o Apple"
    if "title" in cols and "username" in cols and "url" in cols:
        return "KeePass"
    if {"name", "url", "username", "password"} <= cols:
        return "Chrome o Google"
    return "CSV generico"


def parse_csv(text: str) -> Dict:
    """Analizza una stringa CSV e ritorna {source, entries}.
    `entries` = lista di {title, fields:[{label,value}], tags:[...]}."""
    text = (text or "").lstrip("\ufeff")  # toglie eventuale BOM
    if not text.strip():
        return {"source": "vuoto", "entries": []}

    reader = csv.DictReader(io.StringIO(text), delimiter=_separatore(text))
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
            if not val or col in _IGNORE or val.lower() in _URL_FINTI:
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
                    if t and t not in tags and t not in _TAG_RADICE:
                        tags.append(t)
            else:
                if label == "OTP (2FA)":
                    val = _looks_like_otpauth_uri(val)
                fields.append({"label": label, "value": val})

        # scarta righe completamente vuote
        if not title and not fields:
            continue
        if not title:
            # Senza nome: prima il sito (`amazon.it`), poi chi accede.
            url = next((f["value"] for f in fields if f["label"] == "URL"), "")
            cand = _host(url) or next((f["value"] for f in fields
                                       if f["label"] in ("Email", "Utente")), "")
            title = cand or "voce senza titolo"

        # Nessun tag inventato: se l'export non ne porta, la voce resta senza.
        #
        # Prima qui si ricavavano dal titolo le parole di almeno 3 lettere, in
        # ordine alfabetico. Il risultato erano tag che non dicevano niente —
        # `PayPal (606)` diventava `606, paypal`, `Poste Italiane` diventava
        # `italiane, poste` — e per giunta erano inutili alla ricerca, che il
        # titolo lo indicizza già (spezzandolo anche sui punti dei domini).
        # Il raggruppamento si fa con le categorie, scelte a mano.
        entries.append({"title": title, "fields": fields, "tags": tags})

    return {"source": source, "entries": entries}
