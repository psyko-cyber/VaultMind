r"""
Un telefono finto, in Python: risponde al PC con lo stesso protocollo di
`mobile/lib/sync_rete_io.dart`, tenendo il vault in memoria.

Serve ai test del PC (`test_sync_app.py`), che così provano il `SyncApp`
**vero** — con un vault vero su disco — senza un telefono in mano. Che il
telefono vero parli allo stesso modo lo prova un altro test, dal lato Dart:
`mobile/test/sync_ponte_test.dart` fa collegare il `GestoreSync` vero al
`SyncApp` vero (`tests/ponte_sync.py`).

Si può anche lanciare a mano, per provare l'app del PC senza telefono. Il
PC va avviato con `VAULTMIND_SYNC_PORT=8798` e `VAULTMIND_SYNC_INDIRIZZI=127.0.0.1`
(vedi server.py), poi:

    VaultMind_Windows\.venv\Scripts\python.exe tests\telefono_finto.py

e incollare il testo del QR (`uri` nella risposta di `/api/sync/collega`).
"""
from __future__ import annotations
import json
import os
import secrets
import socket
import sys
import threading
from typing import Callable, Dict, List, Optional

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import sync_protocol as sp  # noqa: E402


class TelefonoFinto:
    def __init__(self, porta: int = 0, id_tel: str = "7e" * 8,
                 nome: str = "Telefono di prova", host: str = "127.0.0.1"):
        self.id = id_tel
        self.nome = nome
        self.pc: Dict[str, bytes] = {}
        self.voci: List[dict] = []
        self.lapidi: List[dict] = []
        self.categorie: List[str] = []
        self.gettone = secrets.token_hex(8)
        #: Quante volte ha adottato un risultato, e l'ultimo riepilogo.
        self.adozioni = 0
        self.riepilogo: Optional[dict] = None
        #: Chiamata subito prima di adottare: un test ci mette una modifica,
        #: per simulare l'utente che salva mentre il PC sta fondendo.
        self.prima_di_adottare: Optional[Callable[[], None]] = None
        #: Quanti collegamenti ha ricevuto (compresi quelli di chi bussa).
        self.collegamenti = 0
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind((host, porta))
        self._srv.listen(16)
        self.porta = self._srv.getsockname()[1]
        self._via = False
        threading.Thread(target=self._ascolta, daemon=True).start()

    # ------------------------------------------------------------ dall'utente

    def collega(self, uri: str) -> None:
        q = sp.leggi_uri(uri)
        self.pc[q["pc"]] = q["chiave"]

    def modifica(self) -> None:
        """Da chiamare dopo aver cambiato voci/lapidi/categorie a mano."""
        self.gettone = secrets.token_hex(8)

    def chiudi(self) -> None:
        self._via = True
        try:
            self._srv.close()
        except OSError:
            pass

    # ---------------------------------------------------------------- la rete

    def _ascolta(self) -> None:
        while not self._via:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            self.collegamenti += 1
            threading.Thread(target=self._servi, args=(conn,), daemon=True).start()

    def _servi(self, conn: socket.socket) -> None:
        conn.settimeout(20)
        f = conn.makefile("rb")

        def scrivi(obj: dict) -> None:
            conn.sendall(json.dumps(obj).encode("ascii") + b"\n")

        try:
            riga = f.readline()
            if not riga:
                return   # qualcuno ha bussato e se n'è andato
            h = json.loads(riga)
            chiave = self.pc.get(str(h.get("pc")))
            if chiave is None:
                scrivi({"no": "pc"})
                return
            try:
                ciao = sp.decifra(chiave, h["m"])
            except Exception:
                scrivi({"no": "chiave"})
                return
            if ciao.get("t") != "ciao":
                return
            s = str(ciao["s"]) + secrets.token_hex(8)

            def manda(obj: dict) -> None:
                scrivi({"m": sp.cifra(chiave, {**obj, "s": s})})

            def ricevi() -> dict:
                r = sp.decifra(chiave, json.loads(f.readline())["m"])
                if r.get("s") != s:
                    raise ValueError("sessione sbagliata")
                return r

            manda({"t": "stato", "id": self.id, "nome": self.nome,
                   "token": self.gettone})
            while True:
                r = ricevi()
                if r["t"] in ("fine", "uguale"):
                    return
                if r["t"] == "dammi":
                    manda({"t": "vault", "token": self.gettone, "voci": self.voci,
                           "lapidi": self.lapidi, "categorie": self.categorie})
                elif r["t"] == "prendi":
                    if self.prima_di_adottare:
                        self.prima_di_adottare()
                    if r["base"] != self.gettone:
                        manda({"t": "cambiato"})
                        return
                    self.voci = r["voci"]
                    self.lapidi = r["lapidi"]
                    self.categorie = r["categorie"]
                    self.riepilogo = r.get("riepilogo")
                    self.adozioni += 1
                    self.modifica()
                    manda({"t": "preso", "token": self.gettone})
                    return
                else:
                    return
        except Exception:
            return
        finally:
            try:
                f.close()
                conn.close()
            except OSError:
                pass


if __name__ == "__main__":
    t = TelefonoFinto(porta=8798)
    print(f"Telefono finto in ascolto su {t.porta}.")
    print("Incolla il testo del QR mostrato dal PC e premi Invio:", flush=True)
    t.collega(input().strip())
    print("Collegato. Le voci arrivate si vedono qui sotto; Ctrl+C per uscire.")
    visto = -1
    try:
        while True:
            threading.Event().wait(2)
            if t.adozioni != visto:
                visto = t.adozioni
                print(f"{len(t.voci)} voci, {len(t.lapidi)} lapidi, "
                      f"categorie {t.categorie}", flush=True)
    except KeyboardInterrupt:
        t.chiudi()
