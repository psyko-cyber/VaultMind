"""
sync_protocol.py — Come parlano PC e telefono: la chiave del QR e i messaggi
cifrati. Gemello Dart: `mobile/lib/sync_protocollo.dart`; i byte sono fissati
dal vettore `tests/vettore/sync.json`, che eseguono tutte e due le suite.

## Perché è così semplice (ottobre 2026)

Il sync di prima ricavava le chiavi dalla master password, firmava le sonde e
chiedeva un codice di 6 cifre. Era sicuro, ma due vault con salt diversi — cioè
un vault creato sul telefono, anche con la stessa password — non potevano
abbinarsi in nessun modo, e l'errore diceva un'altra cosa. Luca ci ha perso
un'ora.

Adesso la fiducia la decide **chi inquadra il QR**: il PC genera 32 byte a caso,
li mostra nel QR, il telefono li legge. Da lì ogni messaggio è cifrato con
AES-256-GCM con quella chiave, e chi non ce l'ha non legge niente e non può
scrivere niente che l'altro accetti. È l'unico requisito che conta: i dati
viaggiano cifrati, e solo fra dispositivi che hai collegato tu.

## Un messaggio sul filo

Una riga JSON per messaggio. La prima, dal PC, dice in chiaro chi chiama —
`{"v": 1, "pc": "<id del PC>", "m": "<base64>"}` — perché il telefono sappia
quale chiave usare; le altre sono `{"m": "<base64>"}`. Dentro `m`: nonce di 12
byte, testo cifrato, tag di 16 byte in coda (la forma di Python
`cryptography`, come nel vault). AAD propria, `vaultmind-sync`: un messaggio
del sync non deve mai poter passare per un vault, né il contrario.

Il telefono che non conosce quel PC risponde in chiaro `{"no": "pc"}`, quello
che non riesce a decifrare `{"no": "chiave"}`: così il PC può dire «il
telefono non riconosce più questo PC» invece di un generico «non risponde».
Non rivela niente che un estraneo sulla rete non sappia già.
"""

from __future__ import annotations
import base64
import json
import os
import secrets
from typing import Optional
from urllib.parse import parse_qs, quote, urlsplit

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

VERSIONE = 1
AAD = b"vaultmind-sync"
LUNGHEZZA_CHIAVE = 32
#: Il nome nel QR si tronca: un nome lunghissimo farebbe un QR fitto, più
#: difficile da inquadrare, per un'informazione che il telefono riceve comunque
#: al primo collegamento.
NOME_MAX = 40


class MessaggioRifiutato(Exception):
    """Un messaggio che non si apre: chiave sbagliata, manomesso o malformato.
    Per chi lo riceve la reazione è sempre una sola: si chiude."""


def id_dispositivo() -> str:
    """Un identificativo per questo dispositivo. Casuale e non ricavato
    dall'hardware: come etichetta un numero a caso va benissimo, senza dire
    niente su di te."""
    return secrets.token_hex(8)


def nuova_chiave() -> bytes:
    return os.urandom(LUNGHEZZA_CHIAVE)


def nuova_meta_sessione() -> str:
    """Metà dell'identificativo di un collegamento: 8 byte del PC più 8 del
    telefono. Ogni messaggio successivo lo ripete, così un messaggio registrato
    da un collegamento vecchio non vale in uno nuovo."""
    return secrets.token_hex(8)


def cifra(chiave: bytes, dati: dict, nonce: Optional[bytes] = None) -> str:
    """`nonce` a parametro solo per il vettore di prova: in uso è sempre nuovo,
    perché due messaggi con la stessa coppia chiave-nonce in GCM si smontano a
    vicenda."""
    nonce = nonce if nonce is not None else os.urandom(12)
    chiaro = json.dumps(dati, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.b64encode(nonce + AESGCM(chiave).encrypt(nonce, chiaro, AAD)).decode("ascii")


def decifra(chiave: bytes, testo: str) -> dict:
    # Cattura larga: arriva dalla rete, e un messaggio storto può avere
    # qualunque forma. La conclusione è sempre la stessa.
    try:
        grezzo = base64.b64decode(testo.encode("ascii"), validate=True)
        if len(grezzo) < 12 + 16:
            raise ValueError("troppo corto")
        chiaro = AESGCM(chiave).decrypt(grezzo[:12], grezzo[12:], AAD)
        dati = json.loads(chiaro.decode("utf-8"))
    except Exception as exc:
        raise MessaggioRifiutato("Messaggio non decifrabile.") from exc
    if not isinstance(dati, dict):
        raise MessaggioRifiutato("Il messaggio non è un oggetto.")
    return dati


# ------------------------------------------------------------------ il QR

def uri_abbinamento(id_pc: str, nome: str, chiave: bytes) -> str:
    """Il testo del QR. La chiave in esadecimale e non in base64: si legge
    uguale in ogni lingua, senza discutere di `+`, `/` e `=` dentro un URI."""
    nome = " ".join(str(nome or "").split())[:NOME_MAX]
    return (f"vaultmind://abbina?v={VERSIONE}&pc={id_pc}"
            f"&k={chiave.hex()}&n={quote(nome, safe='')}")


def leggi_uri(uri: str) -> dict:
    """Il contrario di `uri_abbinamento`. Lo usa il telefono (in Dart) e i
    test; qui serve per provare che le due lingue leggono lo stesso QR."""
    try:
        parti = urlsplit(uri.strip())
        if parti.scheme != "vaultmind" or parti.netloc != "abbina":
            raise ValueError("non è un QR di VaultMind")
        q = parse_qs(parti.query)
        chiave = bytes.fromhex(q["k"][0])
        if len(chiave) != LUNGHEZZA_CHIAVE:
            raise ValueError("chiave della lunghezza sbagliata")
        return {"v": int(q["v"][0]), "pc": q["pc"][0],
                "nome": (q.get("n") or [""])[0], "chiave": chiave}
    except Exception as exc:
        raise ValueError(f"QR non valido: {exc}") from exc
