"""
totp.py — Generazione codici 2FA (TOTP, RFC 6238) in puro Python.

100% locale e offline: il codice a 6 cifre è solo un HMAC-SHA1 del tempo
corrente con il "secret" della 2FA (la chiave che il sito mostra quando attivi
l'autenticatore — quella del QR code / "manual entry key"). Nessuna rete,
nessuna dipendenza esterna.

NB: il secret va inserito UNA volta come campo della credenziale; da lì il
codice si rigenera da solo ogni 30s. Senza quel secret è matematicamente
impossibile generare i codici.
"""

from __future__ import annotations
import base64
import hmac
import hashlib
import struct
import time
import re

# Etichette che indicano un campo "secret TOTP" (non il codice, ma la chiave).
_OTP_LABEL_HINTS = ("otp", "totp", "2fa", "mfa", "authenticator", "auth",
                    "one time", "one-time", "google authenticator", "2 fa")


def is_otp_label(label: str) -> bool:
    l = (label or "").lower()
    # evitiamo falsi positivi tipo "author" / "autore"
    if "autor" in l:
        return False
    return any(h in l for h in _OTP_LABEL_HINTS)


def _b32decode(secret: str) -> bytes:
    s = re.sub(r"[^A-Za-z2-7]", "", secret or "").upper()
    if not s:
        raise ValueError("secret vuoto")
    pad = (-len(s)) % 8
    return base64.b32decode(s + "=" * pad)


def generate(secret: str, period: int = 30, digits: int = 6, t: float | None = None) -> dict:
    """Ritorna {code, remaining, period}. Solleva ValueError se il secret non è base32 valido."""
    key = _b32decode(secret)
    if t is None:
        t = time.time()
    counter = int(t // period)
    h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = h[-1] & 0x0F
    code_int = (struct.unpack(">I", h[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return {
        "code": str(code_int).zfill(digits),
        "remaining": period - int(t % period),
        "period": period,
    }


def codes_for(cred) -> list:
    """Per una credenziale, calcola i codici di tutti i campi 'secret OTP'.
    Ritorna lista di {label, code, remaining, period} oppure {label, error}."""
    out = []
    for f in cred.fields:
        if is_otp_label(f.label) and (f.value or "").strip():
            try:
                out.append({"label": f.label, **generate(f.value)})
            except Exception:
                out.append({"label": f.label, "error": "secret 2FA non valido (atteso base32)"})
    return out
