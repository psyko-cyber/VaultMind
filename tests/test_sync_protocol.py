r"""
Test sul protocollo di abbinamento (`app/sync_protocol.py`).

Il grosso sta nel vettore `vettore/sync.json`, che verifica **anche la suite
Dart**: ingressi fissi, byte attesi. Se le due implementazioni calcolassero
prove diverse, l'abbinamento fallirebbe sempre — e senza questo file lo si
scoprirebbe con due dispositivi veri in mano, che e' il momento peggiore.

Qui, oltre al vettore, ci sono le proprieta' che il protocollo deve avere e che
un vettore non puo' mostrare: che una prova non valga per l'altro ruolo, che il
codice sbagliato non passi, che i nonce cambino.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import sync_protocol as sp  # noqa: E402
from app.crypto_store import derive_key  # noqa: E402


class TestVettoreSync(unittest.TestCase):
    """Gli stessi ingressi e le stesse uscite della suite Dart."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(_QUI, "vettore", "sync.json"), encoding="utf-8") as f:
            cls.v = json.load(f)
        cls.chiave = bytes.fromhex(cls.v["chiave_vault"])
        cls.na = bytes.fromhex(cls.v["nonce_a"])
        cls.nb = bytes.fromhex(cls.v["nonce_b"])
        cls.sfida = bytes.fromhex(cls.v["sfida"])
        cls.atteso = cls.v["atteso"]

    def sessione(self):
        return sp.chiave_sessione(self.chiave, self.na, self.nb)

    def test_chiave_di_sessione(self):
        self.assertEqual(self.atteso["chiave_sessione"], self.sessione().hex())

    def test_le_due_prove(self):
        s = self.sessione()
        self.assertEqual(self.atteso["prova_a"], sp.prova(s, "A", self.v["codice"]))
        self.assertEqual(self.atteso["prova_b"], sp.prova(s, "B", self.v["codice"]))

    def test_impronta_di_sessione(self):
        self.assertEqual(self.atteso["impronta_sessione"],
                         sp.impronta_sessione(self.sessione()))

    def test_chiave_verso_un_dispositivo(self):
        self.assertEqual(self.atteso["chiave_verso_peer"],
                         sp.chiave_verso(self.chiave, self.v["id_peer"]).hex())

    def test_risposta_alla_sfida(self):
        self.assertEqual(self.atteso["risposta_sfida"],
                         sp.risposta_sfida(self.chiave, self.v["id_peer"], self.sfida))

    def test_impronta_del_vault(self):
        self.assertEqual(self.atteso["impronta_vault"], sp.impronta_vault(self.chiave))


class TestProprietaProtocollo(unittest.TestCase):

    def setUp(self):
        self.chiave = bytes(range(32))
        self.altra = bytes(range(1, 33))
        self.s = sp.chiave_sessione(self.chiave, b"a" * 16, b"b" * 16)

    def test_i_due_ruoli_hanno_prove_diverse(self):
        """Se fossero uguali, chi riceve la prova di A potrebbe rimandarla
        indietro spacciandosi per B, e l'abbinamento non dimostrerebbe piu'
        niente."""
        self.assertNotEqual(sp.prova(self.s, "A", "123456"),
                            sp.prova(self.s, "B", "123456"))
        self.assertFalse(sp.verifica_prova(self.s, "B", "123456",
                                           sp.prova(self.s, "A", "123456")))

    def test_il_codice_sbagliato_non_passa(self):
        """E' il senso stesso delle sei cifre: legano l'abbinamento a quello
        che hai letto sull'altro schermo."""
        buona = sp.prova(self.s, "A", "123456")
        self.assertTrue(sp.verifica_prova(self.s, "A", "123456", buona))
        self.assertFalse(sp.verifica_prova(self.s, "A", "654321", buona))

    def test_una_chiave_diversa_non_passa(self):
        """Due vault con master password diverse non si abbinano: e' la
        proprieta' su cui poggia tutto il resto."""
        s2 = sp.chiave_sessione(self.altra, b"a" * 16, b"b" * 16)
        self.assertFalse(sp.verifica_prova(s2, "A", "123456",
                                           sp.prova(self.s, "A", "123456")))

    def test_nonce_diversi_danno_sessioni_diverse(self):
        """Senza, una conversazione registrata ieri varrebbe ancora oggi."""
        a = sp.chiave_sessione(self.chiave, b"a" * 16, b"b" * 16)
        b = sp.chiave_sessione(self.chiave, b"a" * 16, b"c" * 16)
        self.assertNotEqual(a, b)

    def test_i_nonce_non_si_ripetono(self):
        self.assertEqual(50, len({sp.nonce() for _ in range(50)}))

    def test_il_codice_ha_sei_cifre_e_varia(self):
        codici = {sp.codice_abbinamento() for _ in range(200)}
        for c in codici:
            self.assertEqual(6, len(c))
            self.assertTrue(c.isdigit())
        self.assertGreater(len(codici), 150, "codice poco variabile")

    def test_l_impronta_e_leggibile_ad_alta_voce(self):
        i = sp.impronta_sessione(self.s)
        self.assertRegex(i, r"^\d{3} \d{3}$")

    def test_l_impronta_cambia_con_la_sessione(self):
        """E' quello che permette di accorgersi di qualcuno in mezzo
        guardando i due schermi."""
        altra = sp.chiave_sessione(self.chiave, b"z" * 16, b"b" * 16)
        self.assertNotEqual(sp.impronta_sessione(self.s), sp.impronta_sessione(altra))

    def test_chiavi_diverse_verso_dispositivi_diversi(self):
        """Un dispositivo revocato non deve poter riusare quello che sapeva per
        farsi passare per un altro."""
        a = sp.chiave_verso(self.chiave, "aaaa")
        b = sp.chiave_verso(self.chiave, "bbbb")
        self.assertNotEqual(a, b)
        self.assertEqual(32, len(a))

    def test_la_sfida_non_si_riusa_fra_dispositivi(self):
        sfida = b"s" * 16
        r = sp.risposta_sfida(self.chiave, "aaaa", sfida)
        self.assertTrue(sp.verifica_sfida(self.chiave, "aaaa", sfida, r))
        self.assertFalse(sp.verifica_sfida(self.chiave, "bbbb", sfida, r))

    def test_l_id_dispositivo_e_casuale(self):
        self.assertEqual(30, len({sp.id_dispositivo() for _ in range(30)}))

    def test_impronte_vault_diverse_per_chiavi_diverse(self):
        """E' cosi' che si distingue «non ci siamo capiti sulla rete» da «hai
        cambiato la master password su un dispositivo e non sull'altro»."""
        self.assertNotEqual(sp.impronta_vault(self.chiave), sp.impronta_vault(self.altra))

    def test_niente_prove_o_chiavi_vuote(self):
        """Un confronto con la stringa vuota non deve mai riuscire: e' il caso
        che si verifica quando un messaggio arriva monco."""
        self.assertFalse(sp.verifica_prova(self.s, "A", "123456", ""))
        self.assertFalse(sp.verifica_prova(self.s, "A", "123456", None))

    def test_il_dispositivo_senza_vault_arriva_alla_stessa_chiave(self):
        """Il primo travaso: il telefono nuovo non ha il vault, riceve il salt
        (che non e' segreto) e scrive la master password. Se e' quella giusta
        ottiene la stessa identica chiave; se e' sbagliata le prove non tornano
        e non viene trasferito niente."""
        salt = os.urandom(16)
        vera = derive_key("master-di-prova-1", salt)
        chiave, impronta = sp.sessione_da_password("master-di-prova-1", salt, derive_key)
        self.assertEqual(vera, chiave)
        self.assertEqual(sp.impronta_vault(vera), impronta)

        sbagliata, _ = sp.sessione_da_password("non-e-questa", salt, derive_key)
        self.assertNotEqual(vera, sbagliata)


if __name__ == "__main__":
    unittest.main(verbosity=2)
