r"""
Genera il vettore di prova: un vault d'esempio con password NOTA.

Serve all'app Android (§2 del TODO): l'implementazione Dart della crittografia
si verifica aprendo questo file. Se lo apre e ritrova esattamente il contenuto
di `atteso.json`, è compatibile col vault vero. Senza un vettore, l'unico modo
di accorgersi di un errore sarebbe scoprire sul telefono che il vault vero non
si apre — cioè troppo tardi.

Si esegue UNA VOLTA e il risultato si committa. Rigenerarlo cambia salt e
nonce (sono casuali, ed è giusto così): il contenuto resta lo stesso, ma il
file cambia. Non c'è motivo di rifarlo se non cambia il formato.

    ..\..\VaultMind_Windows\.venv\Scripts\python.exe genera.py

Le credenziali qui dentro sono INVENTATE. Nessun dato reale in un file che
sta in un repository.
"""
from __future__ import annotations
import json
import os
import sys
from pathlib import Path

QUI = Path(__file__).resolve().parent
sys.path.insert(0, str(QUI.parents[1] / "VaultMind_Windows"))

from app.crypto_store import VaultStore, ARGON2_TIME, ARGON2_MEMORY, ARGON2_PARALLELISM  # noqa: E402
from app import totp  # noqa: E402

MASTER = "vettore-di-prova-2026"

# Voci scelte per esercitare i punti in cui un'implementazione diversa
# sbaglia: accenti/emoji (UTF-8), ordine dei campi, titolo-dominio, voce
# critica, secret TOTP, voce senza campi, valore lungo.
VOCI = [
    {"title": "Banca Esempio",
     "fields": [{"label": "utente", "value": "mario.rossi"},
                {"label": "password", "value": "b4nc4-InVeNtAtA!"}],
     "tags": ["banca", "importante"], "critical": True},

    {"title": "amazon.it",
     "fields": [{"label": "URL", "value": "https://www.amazon.it"},
                {"label": "utente", "value": "mario@example.com"},
                {"label": "password", "value": "amz-finta-01"}],
     "tags": ["shopping"], "critical": False},

    {"title": "Posta con 2FA",
     "fields": [{"label": "utente", "value": "mario@example.com"},
                {"label": "password", "value": "p0st4-finta"},
                {"label": "secret OTP", "value": "JBSWY3DPEHPK3PXP"}],
     "tags": ["email"], "critical": True},

    {"title": "Vocé àccentata 🔐",
     "fields": [{"label": "nòta", "value": "àèìòù — accenti, trattini e 🔑"}],
     "tags": ["unicode"], "critical": False},

    {"title": "Senza campi", "fields": [], "tags": [], "critical": False},

    {"title": "Valore lungo",
     "fields": [{"label": "blob", "value": "x" * 3000}],
     "tags": [], "critical": False},
]

vault = QUI / "vault-esempio.json"
if vault.exists():
    vault.unlink()

store = VaultStore(str(vault))
store.create(MASTER)
store.add_many(VOCI)

# `atteso.json`: il contenuto in chiaro, nell'ordine esatto in cui il vault lo
# restituisce dopo add_many (le voci entrano in testa: l'ordine finale e'
# l'inverso della lista). Chi implementa in Dart confronta con questo.
atteso = {
    "master_password": MASTER,
    "kdf": {"alg": "argon2id", "time_cost": ARGON2_TIME,
            "memory_cost_kib": ARGON2_MEMORY, "parallelism": ARGON2_PARALLELISM,
            "key_len": 32},
    "cipher": {"alg": "aes-256-gcm", "aad": "vaultmind", "nonce_len": 12},
    "credentials": [c.to_dict() for c in store.entries],
}

# Un codice TOTP calcolato a un istante FISSO: cosi' l'implementazione mobile
# verifica anche il 2FA, non solo la decifratura.
istante = 1_800_000_000  # unix time fisso, arbitrario
atteso["totp_di_verifica"] = {
    "secret": "JBSWY3DPEHPK3PXP",
    "unix_time": istante,
    "codice_atteso": totp.generate("JBSWY3DPEHPK3PXP", t=istante)["code"],
}

(QUI / "atteso.json").write_text(
    json.dumps(atteso, ensure_ascii=False, indent=2), encoding="utf-8")

print("vault-esempio.json :", vault.stat().st_size, "byte")
print("voci               :", len(store.entries))
print("TOTP di verifica   :", atteso["totp_di_verifica"]["codice_atteso"],
      "al tempo", istante)
