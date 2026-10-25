r"""
Il sync del PC dall'inizio alla fine: `SyncApp` vero, vault vero sul disco,
un telefono finto (`telefono_finto.py`) che risponde su 127.0.0.1 con lo
stesso protocollo del telefono vero.

Il telefono vero contro il PC vero lo prova `mobile/test/sync_ponte_test.dart`.

    tests\run.ps1
"""

from __future__ import annotations
import os
import shutil
import sys
import tempfile
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _QUI)
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app.crypto_store import VaultStore  # noqa: E402
from app.sync_app import RADICE, SyncApp  # noqa: E402
from app import sync_protocol as sp  # noqa: E402
from telefono_finto import TelefonoFinto  # noqa: E402

MASTER = "master-di-prova-1"


def voce(id_, titolo, uid="", rev=1, mod=0, valore="x", categoria=""):
    d = {"id": id_, "title": titolo, "tags": [], "critical": False,
         "fields": [{"label": "password", "value": valore}]}
    if uid:
        d["uid"] = uid
    if rev != 1:
        d["rev"] = rev
    if mod:
        d["mod"] = mod
    if categoria:
        d["category"] = categoria
    return d


class Base(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vaultmind-sync-")
        self.store = VaultStore(os.path.join(self.dir, "pc.json"))
        self.store.create(MASTER)
        self.store.add_many([
            {"title": "Banca", "fields": [{"label": "password", "value": "b"}]},
            {"title": "Amazon", "fields": [{"label": "password", "value": "a"}]},
        ])
        self.impostazioni: dict = {}
        self.avvisi = 0
        self.tel = TelefonoFinto()
        self.sync = self._sync()

    def _sync(self):
        def avvisato():
            self.avvisi += 1
        return SyncApp(store_di=lambda: self.store,
                       leggi_impostazioni=lambda: self.impostazioni,
                       salva_impostazioni=lambda s: self.impostazioni.update(s),
                       porta=self.tel.porta, dopo_fusione=avvisato,
                       reti=lambda: [["127.0.0.1"]], automatico=False)

    def tearDown(self):
        self.sync.ferma()
        self.tel.chiudi()
        shutil.rmtree(self.dir, ignore_errors=True)

    def collega(self):
        uri = self.sync.inizia_collegamento()["uri"]
        self.tel.collega(uri)
        self.sync.giro()

    def titoli_pc(self):
        return sorted(c.title for c in self.store.entries)

    def titoli_tel(self):
        return sorted(v["title"] for v in self.tel.voci)


class TestCollegamento(Base):

    def test_il_qr_collega_e_il_telefono_riceve_il_vault(self):
        self.collega()
        stato = self.sync.stato_collegamento()
        self.assertEqual(stato["collegato"]["nome"], "Telefono di prova")
        self.assertEqual(self.titoli_tel(), ["Amazon", "Banca"])
        # La chiave sta nel vault cifrato, non nelle impostazioni in chiaro.
        self.assertIn(self.tel.id, self.store.radice(RADICE))
        self.assertNotIn("chiave", str(self.impostazioni))
        self.assertEqual(self.impostazioni["sync"]["telefoni"][self.tel.id]["indirizzo"],
                         "127.0.0.1")

    def test_il_qr_si_legge_uguale(self):
        uri = self.sync.inizia_collegamento()["uri"]
        q = sp.leggi_uri(uri)
        self.assertEqual(q["pc"], self.sync.id_dispositivo)
        self.assertEqual(len(q["chiave"]), 32)
        self.assertTrue(self.sync.inizia_collegamento()["svg"].startswith("<svg"))

    def test_due_vault_nati_separati_si_uniscono(self):
        """Il caso che col sync di prima era impossibile: il telefono ha un
        vault suo, con un'altra master password e altre voci. Comprese due voci
        «#1» che non sono la stessa voce."""
        self.tel.voci = [voce(1, "Posta"), voce(99, "Altra voce 99"),
                         voce(2, "Netflix", uid="u-netflix")]
        self.tel.modifica()
        self.store.applica_fusione(self.store.entries
                                   + [VaultStoreVoce(99, "Vecchia")], [], [])
        self.collega()
        attesi = ["Altra voce 99", "Amazon", "Banca", "Netflix", "Posta", "Vecchia"]
        self.assertEqual(self.titoli_pc(), attesi)
        self.assertEqual(self.titoli_tel(), attesi)

    def test_un_qr_scaduto_non_collega(self):
        uri = self.sync.inizia_collegamento()["uri"]
        self.sync._attesa["scade"] = 0
        self.tel.collega(uri)
        self.sync.giro()
        self.assertEqual(self.sync.stato_collegamento(), {"scaduto": True})
        self.assertEqual(self.tel.voci, [])
        self.assertFalse(self.store.radice(RADICE))

    def test_una_chiave_sbagliata_non_entra(self):
        uri = self.sync.inizia_collegamento()["uri"]
        q = sp.leggi_uri(uri)
        self.tel.pc[q["pc"]] = bytes(32)   # stesso PC, chiave che non è quella
        scritture = self.store.scritture
        self.sync.giro()
        self.assertIsNone(self.sync.stato_collegamento()["collegato"])
        self.assertEqual(self.store.scritture, scritture)
        self.assertEqual(self.tel.voci, [])

    def test_le_chiavi_sopravvivono_al_cambio_della_master(self):
        self.collega()
        self.store.change_master(MASTER, "un'altra-master-1")
        riaperto = VaultStore(self.store.path)
        riaperto.unlock("un'altra-master-1")
        self.assertIn(self.tel.id, riaperto.radice(RADICE))

    def test_scollegare_dimentica_il_telefono(self):
        self.collega()
        self.assertTrue(self.sync.scollega(self.tel.id))
        self.assertFalse(self.store.radice(RADICE))
        self.assertNotIn(self.tel.id, self.impostazioni["sync"]["telefoni"])
        prima = self.tel.collegamenti
        self.sync.giro()
        self.assertEqual(self.tel.collegamenti, prima)

    def test_il_telefono_che_ha_scollegato_il_pc_lo_dice(self):
        self.collega()
        self.tel.pc.clear()
        self.sync.giro()
        t = self.sync.telefoni()[0]
        self.assertEqual(t["esito"], "sconosciuto")
        self.assertIn("non riconosce", t["messaggio"])


def VaultStoreVoce(id_, titolo):
    from app.crypto_store import Credential, Field
    return Credential(id=id_, title=titolo, fields=[Field("password", "v")])


class TestGiro(Base):

    def setUp(self):
        super().setUp()
        self.collega()

    def test_una_voce_aggiunta_sul_telefono_arriva_al_pc(self):
        self.tel.voci.insert(0, voce(50, "Spotify", uid="u-spotify", mod=1))
        self.tel.modifica()
        rev = self.sync.revisione
        self.sync.giro()
        self.assertIn("Spotify", self.titoli_pc())
        self.assertEqual(self.sync.revisione, rev + 1)
        self.assertGreaterEqual(self.avvisi, 1)
        self.assertEqual(self.sync.ultimo["aggiunte"], 1)

    def test_una_modifica_sul_pc_arriva_al_telefono(self):
        banca = next(c for c in self.store.entries if c.title == "Banca")
        self.store.update(banca.id, "Banca Intesa", [{"label": "password", "value": "nuova"}], [])
        self.sync.giro()
        self.assertIn("Banca Intesa", self.titoli_tel())
        self.assertEqual(self.tel.riepilogo["aggiornate"], 1)

    def test_una_cancellazione_sul_telefono_arriva_al_pc(self):
        v = next(v for v in self.tel.voci if v["title"] == "Amazon")
        self.tel.voci.remove(v)
        self.tel.lapidi.append({"uid": v["uid"], "rev": 2, "mod": v.get("mod", 0) + 1})
        self.tel.modifica()
        self.sync.giro()
        self.assertEqual(self.titoli_pc(), ["Banca"])

    def test_vince_l_ultima_modifica(self):
        banca = next(c for c in self.store.entries if c.title == "Banca")
        self.store.update(banca.id, "Banca dal PC", [], [])
        dopo_pc = next(c for c in self.store.entries if c.uid == banca.uid).mod
        v = next(v for v in self.tel.voci if v["uid"] == banca.uid)
        v["title"] = "Banca dal telefono"
        v["rev"] = 2
        v["mod"] = dopo_pc + 1000   # cambiata dopo, sul telefono
        self.tel.modifica()
        self.sync.giro()
        self.assertIn("Banca dal telefono", self.titoli_pc())
        self.assertIn("Banca dal telefono", self.titoli_tel())

    def test_se_niente_e_cambiato_non_si_scrive_niente(self):
        scritture = self.store.scritture
        adozioni = self.tel.adozioni
        self.sync.giro()
        self.sync.giro()
        self.assertEqual(self.store.scritture, scritture)
        self.assertEqual(self.tel.adozioni, adozioni)
        self.assertEqual(self.sync.telefoni()[0]["esito"], "allineato")

    def test_il_telefono_cambiato_durante_la_fusione_riprova(self):
        """L'utente salva sul telefono mentre il PC fonde: il risultato non si
        adotta (perderebbe quel salvataggio), e il giro dopo lo raccoglie."""
        banca = next(c for c in self.store.entries if c.title == "Banca")
        self.store.update(banca.id, "Banca 2", [], [])

        def salva_sul_telefono():
            self.tel.prima_di_adottare = None
            self.tel.voci.insert(0, voce(70, "Aggiunta in corsa", uid="u-corsa", mod=1))
            self.tel.modifica()

        self.tel.prima_di_adottare = salva_sul_telefono
        self.sync.giro()
        self.assertNotIn("Banca 2", self.titoli_tel())
        self.sync.giro()
        self.assertIn("Banca 2", self.titoli_tel())
        self.assertIn("Aggiunta in corsa", self.titoli_tel())
        self.assertIn("Aggiunta in corsa", self.titoli_pc())

    def test_le_categorie_cancellate_restano_cancellate(self):
        self.store.add_category("Lavoro")
        self.store.add_category("Casa")
        self.sync.giro()
        self.assertEqual(self.tel.categorie, ["Lavoro", "Casa"])
        self.tel.categorie = ["Casa", "Viaggi"]
        self.tel.modifica()
        self.sync.giro()
        self.assertEqual(self.store.categories, ["Casa", "Viaggi"])

    def test_le_voci_illeggibili_fermano_il_sync(self):
        self.tel.voci.append({"title": "senza id"})
        self.tel.modifica()
        scritture = self.store.scritture
        self.sync.giro()
        self.assertEqual(self.store.scritture, scritture)

    def test_un_telefono_spento_si_dice_assente(self):
        self.tel.chiudi()
        self.sync.giro()
        self.assertEqual(self.sync.telefoni()[0]["esito"], "assente")


if __name__ == "__main__":
    unittest.main()
