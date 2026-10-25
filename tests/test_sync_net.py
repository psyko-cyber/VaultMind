r"""
Test sul trasporto del sync, lato PC (`app/sync_net.py`).

Non sono finti: dall'altra parte c'e' un socket vero su 127.0.0.1 che fa da
telefono e risponde come vuole il singolo test. Contano soprattutto i casi in
cui qualcosa va storto, perche' sono quelli che decidono cosa leggera' Luca:
«il telefono non riconosce questo PC» e «non risponde» chiedono azioni diverse.

Il protocollo intero (ciao, stato, vault, prendi) lo provano `test_sync_app.py`
col telefono finto e la suite Dart col telefono vero.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import socket
import sys
import threading
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import sync_net as rete  # noqa: E402
from app import sync_protocol as sp  # noqa: E402

CHIAVE = bytes(range(32))
ALTRA_CHIAVE = bytes(range(1, 33))


class Ascolto:
    """Un «telefono» da una riga: accetta un collegamento, passa la prima
    riga ricevuta a `risponde`, manda indietro i byte che restituisce."""

    def __init__(self, risponde):
        self._s = socket.socket()
        self._s.bind(("127.0.0.1", 0))
        self._s.listen(1)
        self.porta = self._s.getsockname()[1]
        self.ricevuto = b""
        self._risponde = risponde
        self._t = threading.Thread(target=self._uno, daemon=True)
        self._t.start()

    def _uno(self):
        try:
            conn, _ = self._s.accept()
        except OSError:
            return
        with conn:
            f = conn.makefile("rb")
            self.ricevuto = f.readline()
            uscita = self._risponde(self.ricevuto)
            if uscita:
                conn.sendall(uscita)

    def chiudi(self):
        self._s.close()
        self._t.join(2)


def _cifrata(dati: dict, chiave: bytes = CHIAVE) -> bytes:
    return json.dumps({"m": sp.cifra(chiave, dati)}).encode() + b"\n"


class TestCollegamento(unittest.TestCase):

    def _prova(self, risponde):
        a = Ascolto(risponde)
        self.addCleanup(a.chiudi)
        c = rete.Collegamento.apri("127.0.0.1", a.porta, CHIAVE)
        self.addCleanup(c.chiudi)
        c.manda({"t": "ciao", "nome": "PC di prova"}, {"v": 1, "pc": "ab" * 8})
        return a, c

    def test_una_riga_cifrata_per_parte(self):
        def risponde(riga):
            dati = sp.decifra(CHIAVE, json.loads(riga)["m"])
            return _cifrata({"t": "eco", "nome": dati["nome"]})
        a, c = self._prova(risponde)
        self.assertEqual({"t": "eco", "nome": "PC di prova"}, c.ricevi())
        riga = json.loads(a.ricevuto)
        self.assertEqual({"v", "pc", "m"}, set(riga), "in chiaro solo chi chiama")
        self.assertNotIn(b"PC di prova", a.ricevuto, "il contenuto non viaggia in chiaro")

    def test_il_telefono_che_non_conosce_il_pc_lo_dice(self):
        _, c = self._prova(lambda _r: b'{"no":"pc"}\n')
        with self.assertRaises(rete.Rifiutato) as e:
            c.ricevi()
        self.assertEqual("pc", e.exception.motivo)

    def test_una_risposta_con_un_altra_chiave(self):
        _, c = self._prova(lambda _r: _cifrata({"t": "x"}, ALTRA_CHIAVE))
        with self.assertRaises(rete.Rifiutato) as e:
            c.ricevi()
        self.assertEqual("chiave", e.exception.motivo)

    def test_chiuso_senza_rispondere(self):
        _, c = self._prova(lambda _r: b"")
        with self.assertRaises(rete.Rifiutato) as e:
            c.ricevi()
        self.assertEqual("chiuso", e.exception.motivo)

    def test_spazzatura(self):
        for byte in (b"non json\n", b"[1,2]\n", b'{"m": 5}\n'):
            with self.subTest(byte=byte):
                _, c = self._prova(lambda _r, b=byte: b)
                with self.assertRaises(rete.Rifiutato):
                    c.ricevi()

    def test_nessuno_in_ascolto(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        porta = s.getsockname()[1]
        s.close()   # porta libera: nessuno risponde
        with self.assertRaises(rete.NonRaggiungibile):
            rete.Collegamento.apri("127.0.0.1", porta, CHIAVE, attesa=0.5)


class TestDoveCercare(unittest.TestCase):

    def test_bussa_trova_solo_chi_ascolta(self):
        a = Ascolto(lambda _r: b"")
        self.addCleanup(a.chiudi)
        self.assertEqual(["127.0.0.1"],
                         rete.bussa(["127.0.0.2", "127.0.0.1"], a.porta, attesa=0.5))

    def test_le_reti_da_provare(self):
        reti = rete.reti_locali()
        for indirizzi in reti:
            self.assertEqual(254, len(indirizzi))
            self.assertFalse(indirizzi[0].startswith(("127.", "169.254.")))
        principale = rete._principale()
        if principale and reti:
            self.assertIn(principale, reti[0], "la scheda principale per prima")


if __name__ == "__main__":
    unittest.main(verbosity=2)
