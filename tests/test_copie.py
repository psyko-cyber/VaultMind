r"""
Le copie di sicurezza del vault e il ripristino che non distrugge.

Nasce dal pentest del 10/11/2026 (punto M1): «Ripristina da backup» accettava
un file qualunque e lo scriveva sopra il vault, senza lasciarne copia; e
nessuna delle tre operazioni che riscrivono il vault per intero (ripristino,
sync, svuota) lasciava modo di tornare indietro.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import shutil
import sys
import tempfile
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import crypto_store as cs  # noqa: E402
from app.crypto_store import VaultStore, VaultCorrupted  # noqa: E402

MASTER = "master-di-prova-1"


def _testo(percorso: str) -> str:
    with open(percorso, encoding="utf-8") as f:
        return f.read()


class ConVault(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vm-copie-")
        self.path = os.path.join(self.dir, "vault.json")
        self.store = VaultStore(self.path)
        self.store.create(MASTER)
        self.store.add("Banca", [{"label": "password", "value": "segreta"}], [])

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def copie(self, motivo=None):
        return [c for c in cs.elenco_copie(self.path)
                if motivo is None or c["motivo"] == motivo]

    def apre(self, percorso) -> list:
        s = VaultStore(percorso)
        s.unlock(MASTER)
        return [c.title for c in s.entries]


class TestControlloDelFile(unittest.TestCase):

    def test_il_file_del_pentest_non_passa(self):
        with self.assertRaises(VaultCorrupted):
            cs.controlla_blob(json.dumps({"kdf": {}, "nonce": "", "ciphertext": ""}))

    def test_cose_che_non_sono_un_vault(self):
        for testo in ("", "ciao", "[]", "{}", '{"kdf":{"salt":"AAAA"},"nonce":"AAAA","ciphertext":"AAAA"}',
                      '{"kdf":{"salt":1},"nonce":2,"ciphertext":3}'):
            with self.assertRaises(VaultCorrupted, msg=testo):
                cs.controlla_blob(testo)


class TestRipristino(ConVault):

    def test_un_file_qualunque_non_tocca_il_vault(self):
        prima = _testo(self.path)
        with self.assertRaises(VaultCorrupted):
            cs.sostituisci_vault(self.path, '{"kdf":{},"nonce":"","ciphertext":""}')
        self.assertEqual(_testo(self.path), prima)
        self.assertEqual(self.copie(), [])

    def test_il_vault_di_prima_resta_fra_le_copie(self):
        altra = os.path.join(self.dir, "altro.json")
        s2 = VaultStore(altra)
        s2.create(MASTER)
        s2.add("Posta", [{"label": "password", "value": "x"}], [])
        copia = cs.sostituisci_vault(self.path, _testo(altra))
        self.assertEqual(self.apre(self.path), ["Posta"])
        self.assertEqual(self.apre(copia), ["Banca"])
        self.assertEqual([c["motivo"] for c in self.copie()], ["ripristino"])

    def test_senza_vault_precedente_non_c_e_niente_da_copiare(self):
        testo = _testo(self.path)
        nuovo = os.path.join(self.dir, "nuovo", "vault.json")
        self.assertIsNone(cs.sostituisci_vault(nuovo, testo))
        self.assertEqual(self.apre(nuovo), ["Banca"])

    def test_nessun_file_temporaneo_resta(self):
        cs.sostituisci_vault(self.path, _testo(self.path))
        for cartella, _, file in os.walk(self.dir):
            self.assertEqual([f for f in file if f.endswith(".tmp")], [], cartella)


class TestCopieAutomatiche(ConVault):

    def test_svuotare_lascia_una_copia_che_si_apre(self):
        self.store.clear()
        self.assertEqual(self.store.entries, [])
        (copia,) = self.copie("svuota")
        self.assertEqual(
            self.apre(os.path.join(cs.cartella_copie(self.path), copia["nome"])), ["Banca"])

    def test_la_fusione_lascia_una_copia_ma_non_una_a_ogni_giro(self):
        for titolo in ("uno", "due", "tre"):
            voci = self.store.entries
            voci[0].title = titolo
            self.store.applica_fusione(voci, [], [])
        self.assertEqual(len(self.copie("sync")), 1)

    def test_una_copia_identica_non_si_ripete(self):
        self.assertIsNotNone(cs.copia_di_sicurezza(self.path, "apertura"))
        self.assertIsNone(cs.copia_di_sicurezza(self.path, "apertura"))
        self.store.add("Posta", [{"label": "password", "value": "x"}], [])
        self.assertIsNotNone(cs.copia_di_sicurezza(self.path, "apertura"))
        self.assertEqual(len(self.copie("apertura")), 2)

    def test_se_ne_tengono_poche_per_motivo(self):
        for i in range(cs.COPIE_PER_MOTIVO + 3):
            self.store.add(f"voce {i}", [{"label": "password", "value": "x"}], [])
            cs.copia_di_sicurezza(self.path, "apertura")
        cs.copia_di_sicurezza(self.path, "svuota")
        self.assertEqual(len(self.copie("apertura")), cs.COPIE_PER_MOTIVO)
        # Le copie di un motivo non si portano via quelle di un altro.
        self.assertEqual(len(self.copie("svuota")), 1)
        # Resta la più recente: è quella con tutte le voci.
        nome = self.copie("apertura")[0]["nome"]
        self.assertEqual(
            len(self.apre(os.path.join(cs.cartella_copie(self.path), nome))),
            cs.COPIE_PER_MOTIVO + 4)

    def test_senza_vault_non_si_copia_niente(self):
        self.assertIsNone(cs.copia_di_sicurezza(os.path.join(self.dir, "manca.json"), "apertura"))

    def test_l_elenco_ignora_i_file_estranei(self):
        cs.copia_di_sicurezza(self.path, "apertura")
        d = cs.cartella_copie(self.path)
        for nome in ("appunti.txt", "vault.json", "vault-x.json", "altro-apertura-1-2.json"):
            open(os.path.join(d, nome), "w").close()
        self.assertEqual([c["motivo"] for c in self.copie()], ["apertura"])


if __name__ == "__main__":
    unittest.main()
