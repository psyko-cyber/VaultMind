r"""
Ascoltatore Python vero, da far collegare al client Dart.

Verifica la giuntura che nessun test unitario copre: che le due lingue si
capiscano **sul filo**, non solo sui vettori. I vettori garantiscono che PC e
telefono calcolino gli stessi byte; i test di rete garantiscono che ciascuno
parli con se stesso. Nessuno dei due dice che si capiscano fra loro — ed e' li'
che un nome di campo diverso non si vedrebbe finche' non hai i due dispositivi
in mano.

Non e' un test automatico perche' servirebbero i due runtime coordinati. Si
esegue a mano, in due terminali:

    VaultMind_Windows\.venv\Scripts\python.exe tests\ponte_sync.py
    mobile\costruisci.ps1 -Test

Il test Dart e' `mobile/test/ponte_python_test.dart`: se questo server non e'
in ascolto **si dichiara saltato**, non passa fingendo.

Qui dentro non c'e' nessun vault vero: chiave finta, contenuti finti, porta
dedicata.
"""
from __future__ import annotations
import os
import sys
import time

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import sync_net as rete  # noqa: E402

#: Porta dedicata alla prova: non e' quella vera del sync (8732), cosi' non si
#: rischia di parlare con un'app aperta per davvero.
PORTA = 8799
CHIAVE = bytes(range(32))     # la stessa che usa il test Dart
ID_PYTHON = "aa" * 8
CODICE = "123456"
ATTESA_S = 60

ricevuti: list = []

ctx = rete.ContestoSync(
    id_dispositivo=ID_PYTHON,
    nome="PC di prova",
    chiave_vault=CHIAVE,
    fidati={},
    leggi_vault_cifrato=lambda: "vault-scritto-dal-python",
    ricevi_vault=lambda blob, id_peer: (
        ricevuti.append((blob, id_peer)), {"ricevuto": True})[1],
    salt_vault=b"\x01" * 16,
    codice_attivo=lambda: CODICE,
)
ctx.abbina = lambda id_peer, nome: ctx.fidati.__setitem__(id_peer, {"nome": nome})

if __name__ == "__main__":
    a = rete.Ascoltatore(ctx, porta=PORTA)
    a.start()
    a.pronto.wait(5)
    print(f"In ascolto su {a.porta_vera}. Ora esegui i test Dart.", flush=True)

    fine = time.time() + ATTESA_S
    while time.time() < fine and not ricevuti:
        time.sleep(0.2)

    if ricevuti:
        blob, id_peer = ricevuti[0]
        print(f"  ricevuto dal Dart : {blob}")
        print(f"  id del Dart       : {id_peer}")
        print(f"  ora abbinato      : {ctx.fidati}")
        print("OK — le due lingue si capiscono sul filo.")
    else:
        print(f"NIENTE: nessun client Dart si e' collegato entro {ATTESA_S}s.")
    a.ferma()
