"""
import_parse.py — Estrazione "best-effort" senza LLM.

Quando Ollama non è disponibile, proviamo comunque a strutturare il testo
incollato con regole euristiche, producendo CAMPI LIBERI (label + valore) come
fa il percorso LLM — non più username/password fissi, per gestire casi come
CIE/SPID dove servono ID, PIN, PUC, telefono, ecc.

È volutamente prudente: meglio proporre una voce con un campo da correggere
che indovinare. L'utente conferma sempre prima del salvataggio (anteprima).
"""

from __future__ import annotations
import re
from typing import List, Dict

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
SEP_RE = re.compile(r"^\s*(?P<key>[^:\-\n]{1,40}?)\s*(?:[:]|[-–—]{1,3})\s*(?P<val>.*\S)?\s*$")
PASS_LABEL_RE = re.compile(r"(?:pass(?:word)?|pwd)\s*[:=]?\s*(?P<pwd>\S.*)$", re.IGNORECASE)
PIN_LABEL_RE = re.compile(r"pin|sblocco|unlock|puc", re.IGNORECASE)

TITLEISH = re.compile(r"^[\w .()/&'+]{2,40}$")


def _looks_like_password(tok: str) -> bool:
    if "@" in tok or " " in tok.strip():
        return False
    if len(tok) < 5:
        return False
    has_alpha = any(c.isalpha() for c in tok)
    has_other = any(c.isdigit() or not c.isalnum() for c in tok)
    return has_alpha and has_other


def _new_entry(title: str = "", multi: bool = False) -> Dict:
    return {"title": title, "fields": [], "tags": [], "_multi": multi}


def _add_field(entry: Dict, label: str, value: str) -> None:
    if not value:
        return
    entry["fields"].append({"label": label, "value": value})


def _finalize(e: Dict) -> Dict:
    if not e["title"]:
        first_val = e["fields"][0]["value"] if e["fields"] else ""
        e["title"] = first_val or "voce senza titolo"
    return e


def heuristic_extract(text: str) -> List[Dict]:
    entries: List[Dict] = []
    current = None

    def push():
        nonlocal current
        if current and current["fields"]:
            entries.append(_finalize(current))
        current = None

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            push()
            continue

        # 1) riga "etichetta separatore valore"
        m = SEP_RE.match(line)
        if m and m.group("val") is not None:
            key = m.group("key").strip()
            val = m.group("val").strip()

            # Se la voce corrente è un "blocco multi-campo" apertosi con una
            # riga di solo titolo (es. CIE/SPID), le righe successive "chiave:
            # valore" sono SUOI campi — usiamo la chiave testuale come
            # etichetta (ID, PIN, PUC, Telefono...). Restiamo nel blocco finché
            # non troviamo un segnale forte di un NUOVO servizio one-liner
            # (tipicamente: un'email nel valore, come in "Google-- mail pass:").
            if current is not None and current.get("_multi") and not EMAIL_RE.search(val):
                label = _clean_title(key) or "Valore"
                _add_field(current, label, val)
                continue

            # altrimenti la chiave è probabilmente un NUOVO servizio
            # (es. "Google-- mario@gmail.com pass: xyz" tutto su una riga)
            if current is None or _is_service_label(key):
                push()
                current = _new_entry(_clean_title(key))

            email_m = EMAIL_RE.search(val)
            pm = PASS_LABEL_RE.search(val) or PASS_LABEL_RE.search(line)
            if email_m:
                _add_field(current, "Email", email_m.group(0))
                rest = val.replace(email_m.group(0), "").strip(" -:")
                if rest and _looks_like_password(rest.split()[-1]):
                    _add_field(current, "Password", rest.split()[-1])
            elif pm:
                _add_field(current, "Password", pm.group("pwd").strip())
            elif _looks_like_password(val):
                _add_field(current, "Password", val)
            elif val:
                _add_field(current, "Valore", val)
            continue

        # 2) riga con etichetta password senza separatore chiave (es. "pass: xyz")
        pm = PASS_LABEL_RE.search(line)
        if pm and current is not None:
            _add_field(current, "Password", pm.group("pwd").strip())
            continue

        emails = EMAIL_RE.findall(line)

        # 3) riga di solo titolo (es. "Steam", "Localxpose")
        if TITLEISH.match(line) and not emails and len(line.split()) <= 3 and not _looks_like_password(line):
            push()
            current = _new_entry(_clean_title(line), multi=True)
            continue

        # 4) riga "sciolta": più token, eventuale email/freccia (es. "user pass -> recovery@mail")
        if current is None:
            current = _new_entry()
        tokens = [t for t in re.split(r"\s+|->|→", line) if t]
        has_username = any(f["label"] == "Utente" for f in current["fields"])
        has_password = any(f["label"] == "Password" for f in current["fields"])
        has_email = any(f["label"].startswith("Email") for f in current["fields"])
        for t in tokens:
            if EMAIL_RE.fullmatch(t):
                _add_field(current, "Email recupero" if has_email else "Email", t)
                has_email = True
            elif _looks_like_password(t) and not has_password:
                _add_field(current, "Password", t)
                has_password = True
            elif not has_username:
                _add_field(current, "Utente", t)
                has_username = True
            else:
                _add_field(current, "Nota", t)

    push()
    for e in entries:
        e.pop("_multi", None)
        # Niente tag ricavati dal titolo: erano parole già presenti nel titolo,
        # quindi inutili alla ricerca (che il titolo lo indicizza) e fuorvianti
        # a vedersi. Stessa correzione fatta in `import_csv.py`.
    return entries


def _is_service_label(key: str) -> bool:
    return len(key) <= 30 and "@" not in key


def _clean_title(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip(" -–—:")).strip()
