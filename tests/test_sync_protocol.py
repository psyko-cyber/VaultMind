r"""
Test sui messaggi del sync (`app/sync_protocol.py`).

Il vettore `vettore/sync.json` lo verifica **anche la suite Dart**: stessa
chiave, stesso nonce, stessi byte. Se il PC e il telefono cifrassero in modo
diverso il primo collegamento fallirebbe sempre, e senza questo file lo si
scoprirebbe col telefono in mano.

Qui, oltre al vettore, le proprieta' che un vettore non puo' mostrare: che un
messaggio manomesso o cifrato con un'altra chiave non passi, e che il nonce
cambi a ogni messaggio.

    tests\run.ps1
"""

from __future__ import annotations
import base64
import json
import os
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import sync_protocol as sp  # noqa: E402


def _vettore() -> dict:
    with open(os.path.join(_QUI, "vettore", "sync.json"), encoding="utf-8") as f:
        return json.load(f)


class TestVettoreSync(unittest.TestCase):

    def setUp(self):
        self.v = _vettore()
        self.chiave = bytes.fromhex(self.v["chiave_hex"])

    def test_il_testo_in_chiaro_e_quello_del_vettore(self):
        """Il JSON compatto e senza escape degli accenti: e' quello che fa
        `jsonEncode` in Dart, e il vettore confronta i byte."""
        self.assertEqual(self.v["chiaro"],
                         json.dumps(self.v["dati"], ensure_ascii=False, separators=(",", ":")))

    def test_cifrare_da_esattamente_m(self):
        nonce = bytes.fromhex(self.v["nonce_hex"])
        self.assertEqual(self.v["m"], sp.cifra(self.chiave, self.v["dati"], nonce))

    def test_decifrare_m_ridà_i_dati(self):
        self.assertEqual(self.v["dati"], sp.decifra(self.chiave, self.v["m"]))

    def test_aad_e_quella_del_vettore(self):
        self.assertEqual(self.v["aad"].encode(), sp.AAD)

    def test_il_qr_del_vettore(self):
        qr = self.v["qr"]
        self.assertEqual(qr["uri"], sp.uri_abbinamento(qr["pc"], qr["nome"], self.chiave))
        letto = sp.leggi_uri(qr["uri"])
        self.assertEqual({"v": qr["v"], "pc": qr["pc"], "nome": qr["nome"],
                          "chiave": bytes.fromhex(qr["chiave_hex"])}, letto)

    def test_i_qr_non_validi_si_rifiutano(self):
        for uri in self.v["qr_non_validi"]:
            with self.subTest(uri):
                with self.assertRaises(ValueError):
                    sp.leggi_uri(uri)


class TestProprieta(unittest.TestCase):

    CHIAVE = bytes(range(32))

    def test_un_altra_chiave_non_legge(self):
        m = sp.cifra(self.CHIAVE, {"t": "ciao"})
        with self.assertRaises(sp.MessaggioRifiutato):
            sp.decifra(bytes(range(1, 33)), m)

    def test_un_byte_cambiato_non_passa(self):
        grezzo = bytearray(base64.b64decode(sp.cifra(self.CHIAVE, {"t": "ciao"})))
        for i in (0, 12, len(grezzo) - 1):   # nonce, testo, tag
            with self.subTest(posizione=i):
                rotto = bytearray(grezzo)
                rotto[i] ^= 1
                with self.assertRaises(sp.MessaggioRifiutato):
                    sp.decifra(self.CHIAVE, base64.b64encode(bytes(rotto)).decode())

    def test_spazzatura_dalla_rete_non_passa(self):
        for testo in ("", "non-base64!!", base64.b64encode(b"corto").decode(),
                      sp.cifra(self.CHIAVE, {"t": "x"})[:-4]):
            with self.subTest(testo=testo):
                with self.assertRaises(sp.MessaggioRifiutato):
                    sp.decifra(self.CHIAVE, testo)

    def test_un_messaggio_del_sync_non_e_un_vault(self):
        """AAD diverse: un blob cifrato per il vault non si apre come messaggio."""
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        nonce = os.urandom(12)
        blob = nonce + AESGCM(self.CHIAVE).encrypt(nonce, b'{"t":"ciao"}', b"vaultmind")
        with self.assertRaises(sp.MessaggioRifiutato):
            sp.decifra(self.CHIAVE, base64.b64encode(blob).decode())

    def test_il_nonce_cambia_ogni_volta(self):
        a = sp.cifra(self.CHIAVE, {"t": "ciao"})
        b = sp.cifra(self.CHIAVE, {"t": "ciao"})
        self.assertNotEqual(base64.b64decode(a)[:12], base64.b64decode(b)[:12])

    def test_il_nome_nel_qr_si_accorcia_e_si_ripulisce(self):
        uri = sp.uri_abbinamento("ab" * 8, "  PC\n di   casa  " + "x" * 100, self.CHIAVE)
        nome = sp.leggi_uri(uri)["nome"]
        self.assertTrue(nome.startswith("PC di casa x"))
        self.assertEqual(sp.NOME_MAX, len(nome))

    def test_ogni_chiave_e_nuova(self):
        self.assertNotEqual(sp.nuova_chiave(), sp.nuova_chiave())
        self.assertEqual(sp.LUNGHEZZA_CHIAVE, len(sp.nuova_chiave()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
