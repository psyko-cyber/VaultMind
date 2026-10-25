r"""
Il PC vero, in Python, comandato dal test Dart `mobile/test/sync_ponte_test.dart`.

E' la giuntura che nessun test di una lingua sola copre: che il PC (Python) e
il telefono (Dart) si capiscano **sul filo**. Il vettore `sync.json` dice che
cifrano gli stessi byte; i test di ciascuna suite che parlano con un finto di
se stessi. Solo qui un nome di campo diverso, o un messaggio in piu' da una
parte, si vede prima di avere i due dispositivi in mano.

Lo fa partire il test Dart con l'interprete del venv; se il venv non c'e' il
test si dichiara saltato. Parla a righe JSON:

  - all'avvio scrive `{"uri": "vaultmind://abbina?..."}`, il testo del QR;
  - poi legge un comando per riga e risponde con una riga:
      {"fai": "giro"}                      -> {"telefoni": [...], "titoli": [...]}
      {"fai": "aggiungi", "titolo": "X"}   -> {"titoli": [...]}
      {"fai": "modifica", "titolo": "X", "password": "p"} -> {"titoli": [...]}
      {"fai": "cancella", "titolo": "X"}   -> {"titoli": [...]}
      {"fai": "voce", "titolo": "X"}       -> {"voce": {...} | null}
      {"fai": "fine"}                      -> esce

    VaultMind_Windows\.venv\Scripts\python.exe tests\ponte_sync.py <porta del telefono>

Qui dentro nessun vault vero: uno nuovo in una cartella temporanea, che si
cancella all'uscita.
"""
from __future__ import annotations
import json
import os
import shutil
import sys
import tempfile

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app.crypto_store import VaultStore  # noqa: E402
from app.sync_app import SyncApp  # noqa: E402


def _scrivi(dati: dict) -> None:
    sys.stdout.write(json.dumps(dati, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> None:
    porta = int(sys.argv[1])
    cartella = tempfile.mkdtemp(prefix="vaultmind-ponte-")
    try:
        store = VaultStore(os.path.join(cartella, "vault.json"))
        store.create("ponte-di-prova")
        store.add_many([
            {"title": "Banca dal PC", "tags": [], "critical": True,
             "fields": [{"label": "password", "value": "dal-pc"}]},
            {"title": "Posta dal PC", "tags": [], "critical": False,
             "fields": [{"label": "password", "value": "posta"}]},
        ])
        impostazioni: dict = {}
        sync = SyncApp(store_di=lambda: store,
                       leggi_impostazioni=lambda: json.loads(json.dumps(impostazioni)),
                       salva_impostazioni=lambda s: (impostazioni.clear(), impostazioni.update(s)),
                       porta=porta, reti=lambda: [["127.0.0.1"]], automatico=False)
        _scrivi({"uri": sync.inizia_collegamento()["uri"]})

        def titoli():
            return sorted(c.title for c in store.entries)

        def per_titolo(t):
            return next((c for c in store.entries if c.title == t), None)

        for riga in sys.stdin:
            if not riga.strip():
                continue
            cmd = json.loads(riga)
            fai = cmd.get("fai")
            if fai == "fine":
                break
            if fai == "giro":
                sync.giro()
                _scrivi({"telefoni": sync.telefoni(), "titoli": titoli()})
            elif fai == "aggiungi":
                store.add(cmd["titolo"], [{"label": "password", "value": "nuova"}], [])
                _scrivi({"titoli": titoli()})
            elif fai == "modifica":
                c = per_titolo(cmd["titolo"])
                store.update(c.id, c.title, [{"label": "password", "value": cmd["password"]}],
                             c.tags, c.critical, c.category)
                _scrivi({"titoli": titoli()})
            elif fai == "cancella":
                store.delete(per_titolo(cmd["titolo"]).id)
                _scrivi({"titoli": titoli()})
            elif fai == "voce":
                c = per_titolo(cmd["titolo"])
                _scrivi({"voce": c.to_dict() if c else None})
            else:
                _scrivi({"errore": f"comando sconosciuto: {fai}"})
    finally:
        shutil.rmtree(cartella, ignore_errors=True)


if __name__ == "__main__":
    main()
