r"""
firma_somme.py — Firma `SHA256SUMS.txt` con la chiave degli aggiornamenti.

## Perché

`SHA256SUMS.txt` sta nella stessa release del setup: chi può pubblicare una
release può pubblicare anche le sue impronte, quindi da solo dice «il download
non si è rotto», non «questo setup l'ha fatto Luca». Con la firma, l'app
installa solo ciò che è stato firmato con una chiave che **non sta su GitHub**:
rubare l'account non basta più (pentest del 10/11/2026, punto A2).

La chiave privata sta in `C:\Android\vaultmind-aggiornamenti.key`, accanto al
keystore dell'APK e fuori da git. La pubblica sta scritta dentro
`VaultMind_Windows/app/aggiornamenti.py`, e quindi dentro ogni exe.

**Perderla** = le app installate rifiutano gli aggiornamenti automatici e
mandano alla pagina delle release (si rimedia pubblicando, a mano, una versione
con una chiave pubblica nuova). **Farsela rubare** = chi ha anche l'account
GitHub può firmare un finto aggiornamento. Va custodita come il keystore.

## Uso

    py -3 installer\firma_somme.py Consegnabili\SHA256SUMS.txt
        -> scrive Consegnabili\SHA256SUMS.txt.sig e la verifica

    py -3 installer\firma_somme.py --nuova-chiave
        -> crea la chiave (si rifiuta se esiste) e stampa la pubblica

    py -3 installer\firma_somme.py --pubblica
        -> stampa la chiave pubblica di quella che c'è

Lo chiama `rilascio.ps1 -Release`. Va eseguito con il Python del venv
dell'app, che ha `cryptography`.
"""

from __future__ import annotations
import base64
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

CHIAVE = os.environ.get("VAULTMIND_CHIAVE_AGGIORNAMENTI",
                        r"C:\Android\vaultmind-aggiornamenti.key")


def _carica(percorso: str) -> Ed25519PrivateKey:
    with open(percorso, "rb") as f:
        chiave = serialization.load_pem_private_key(f.read(), password=None)
    if not isinstance(chiave, Ed25519PrivateKey):
        raise SystemExit(f"{percorso} non e' una chiave Ed25519.")
    return chiave


def pubblica_esa(chiave: Ed25519PrivateKey) -> str:
    return chiave.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()


def nuova_chiave(percorso: str) -> str:
    if os.path.exists(percorso):
        raise SystemExit(f"{percorso} esiste gia': non la sovrascrivo. "
                         "Una chiave nuova rende inutile quella dentro le app installate.")
    chiave = Ed25519PrivateKey.generate()
    os.makedirs(os.path.dirname(percorso), exist_ok=True)
    # "x": se nel frattempo e' comparsa, meglio fallire che sovrascrivere.
    with open(percorso, "xb") as f:
        f.write(chiave.private_bytes(serialization.Encoding.PEM,
                                     serialization.PrivateFormat.PKCS8,
                                     serialization.NoEncryption()))
    return pubblica_esa(chiave)


def firma(percorso_somme: str, percorso_chiave: str) -> str:
    """Scrive `<somme>.sig`: la firma dei byte del file, in base64 su una riga.
    Torna la chiave pubblica, cosi' chi rilascia vede con quale ha firmato."""
    chiave = _carica(percorso_chiave)
    with open(percorso_somme, "rb") as f:
        dati = f.read()
    if not dati.strip():
        raise SystemExit(f"{percorso_somme} e' vuoto: niente da firmare.")
    sig = chiave.sign(dati)
    chiave.public_key().verify(sig, dati)     # solleva se qualcosa non torna
    with open(percorso_somme + ".sig", "w", encoding="ascii", newline="\n") as f:
        f.write(base64.b64encode(sig).decode("ascii") + "\n")
    return pubblica_esa(chiave)


def main(argv: list) -> int:
    if argv == ["--nuova-chiave"]:
        print(nuova_chiave(CHIAVE))
        return 0
    if argv == ["--pubblica"]:
        print(pubblica_esa(_carica(CHIAVE)))
        return 0
    if len(argv) != 1 or argv[0].startswith("-"):
        print(__doc__)
        return 2
    if not os.path.exists(CHIAVE):
        print(f"Manca la chiave degli aggiornamenti: {CHIAVE}")
        return 1
    print(firma(argv[0], CHIAVE))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
