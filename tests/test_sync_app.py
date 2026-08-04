r"""
Il sync intero, dall'inizio alla fine, su due vault veri.

Qui non ci sono finzioni: due file cifrati sul disco, due `SyncApp`, un
ascoltatore vero e un client vero su 127.0.0.1. E' la simulazione piu' fedele
che si possa fare del PC e del telefono senza avere il telefono.

Il caso di partenza e' quello reale: il vault del telefono e' una **copia** di
quello del PC — stesso salt, quindi stessa chiave — e da li' i due divergono.

    tests\run.ps1
"""

from __future__ import annotations
import os
import shutil
import sys
import tempfile
import time
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app.crypto_store import VaultStore  # noqa: E402
from app.sync_app import SyncApp  # noqa: E402
from app import sync_net  # noqa: E402

MASTER = "master-di-prova-1"


class Dispositivo:
    """Un finto dispositivo: un vault sul disco e il suo SyncApp."""

    def __init__(self, path: str, nome: str, porta: int = 0):
        self.store = VaultStore(path)
        self.impostazioni: dict = {}
        self.sync = SyncApp(
            store_di=lambda: self.store,
            leggi_impostazioni=lambda: self.impostazioni,
            salva_impostazioni=lambda s: self.impostazioni.update(s),
            porta=porta,
            porta_scoperta=0,   # niente scoperta: qui ci si collega a mano
        )
        self.sync.imposta(nome=nome)

    def titoli(self):
        return sorted(c.title for c in self.store.entries)


class BaseDueDispositivi(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vaultmind-sync-")
        pc = os.path.join(self.dir, "pc.json")
        tel = os.path.join(self.dir, "telefono.json")

        # Il PC crea il vault e ci mette dentro qualcosa...
        s = VaultStore(pc)
        s.create(MASTER)
        s.add_many([
            {"title": "Banca", "fields": [{"label": "password", "value": "b"}]},
            {"title": "Amazon", "fields": [{"label": "password", "value": "a"}]},
        ])
        # ...e il telefono ne riceve una COPIA: e' il travaso vero, ed e' il
        # motivo per cui i due hanno la stessa chiave (stesso salt).
        shutil.copyfile(pc, tel)

        self.pc = Dispositivo(pc, "PC", porta=0)
        self.tel = Dispositivo(tel, "Telefono", porta=0)
        for d in (self.pc, self.tel):
            d.store.unlock(MASTER)
        self.addCleanup(shutil.rmtree, self.dir, True)

    def collega(self, da: Dispositivo, a: Dispositivo, codice: str = ""):
        """`da` chiama `a`. Torna il riepilogo del lato chiamante."""
        self.assertTrue(a.sync.avvia(), "l'ascoltatore non si e' aperto")
        self.addCleanup(a.sync.ferma)
        try:
            return da.sync.sincronizza_con("127.0.0.1", a.sync.porta_vera, codice)
        finally:
            # si aspetta che anche il lato server abbia finito di fondere
            for _ in range(60):
                if a.sync.ultimo:
                    break
                time.sleep(0.05)


class TestSyncIntero(BaseDueDispositivi):

    def test_primo_abbinamento_e_le_voci_si_incrociano(self):
        """Il giro completo. Ognuno aggiunge una voce sua, poi si allineano e
        se le ritrovano tutte e due — senza che nessuno debba scegliere."""
        self.pc.store.add("Netflix", [{"label": "password", "value": "n"}], [])
        self.tel.store.add("Slack", [{"label": "password", "value": "s"}], [])

        codice = self.pc.sync.apri_abbinamento()["codice"]
        esito = self.collega(self.tel, self.pc, codice)

        self.assertTrue(esito["ok"])
        atteso = ["Amazon", "Banca", "Netflix", "Slack"]
        self.assertEqual(atteso, self.tel.titoli())
        self.assertEqual(atteso, self.pc.titoli())
        self.assertEqual(0, esito.get("conflitti", 0))

    def test_l_abbinamento_vale_nei_due_versi(self):
        """Anche chi CHIAMA deve registrare l'altro: altrimenti l'abbinamento
        resta a meta' e il sync funziona in un verso solo — e nell'elenco dei
        fidati manca proprio il dispositivo con cui ti sei appena abbinato."""
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        self.assertEqual([self.tel.sync.id_dispositivo],
                         [d["id"] for d in self.pc.sync.dispositivi()])
        self.assertEqual([self.pc.sync.id_dispositivo],
                         [d["id"] for d in self.tel.sync.dispositivi()],
                         "chi ha chiamato non ha registrato l'altro")

        # e infatti ora puo' chiamare anche il PC, senza codice
        self.pc.store.add("Dal PC", [{"label": "p", "value": "x"}], [])
        esito = self.collega(self.pc, self.tel)
        self.assertTrue(esito["ok"])
        self.assertIn("Dal PC", self.tel.titoli())

    def test_dopo_l_abbinamento_ci_si_riconosce_senza_codice(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        self.pc.store.add("Spotify", [{"label": "password", "value": "x"}], [])
        esito = self.collega(self.tel, self.pc)   # nessun codice
        self.assertTrue(esito["ok"])
        self.assertIn("Spotify", self.tel.titoli())

    def test_ci_si_riconosce_anche_SENZA_riavviare_l_ascoltatore(self):
        """Il caso che i test precedenti mascheravano: `collega()` riapriva
        l'ascoltatore ogni volta, e cosi' l'elenco dei fidati veniva riletto da
        capo. Nell'app vera l'ascoltatore resta aperto dallo sblocco al blocco,
        e con una fotografia dell'elenco il dispositivo appena abbinato
        risultava sconosciuto per sempre."""
        self.assertTrue(self.pc.sync.avvia())
        self.addCleanup(self.pc.sync.ferma)
        porta = self.pc.sync.porta_vera

        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.tel.sync.sincronizza_con("127.0.0.1", porta, codice)
        self.pc.sync.chiudi_abbinamento()

        # stesso ascoltatore, nessun codice, finestra chiusa: deve passare
        esito = self.tel.sync.sincronizza_con("127.0.0.1", porta)
        self.assertTrue(esito["ok"])

    def test_una_cancellazione_si_propaga_e_non_torna_indietro(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        voce = next(c for c in self.pc.store.entries if c.title == "Amazon")
        self.pc.store.delete(voce.id)

        self.collega(self.tel, self.pc)
        self.assertNotIn("Amazon", self.tel.titoli())

        # e un secondo giro non deve farla resuscitare dal telefono
        self.collega(self.tel, self.pc)
        self.assertNotIn("Amazon", self.tel.titoli())
        self.assertNotIn("Amazon", self.pc.titoli())

    def test_le_categorie_viaggiano(self):
        self.pc.store.add_category("Banche")
        voce = next(c for c in self.pc.store.entries if c.title == "Banca")
        self.pc.store.set_category([voce.id], "Banche")

        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)

        self.assertIn("Banche", self.tel.store.categories)
        gemella = next(c for c in self.tel.store.entries if c.title == "Banca")
        self.assertEqual("Banche", gemella.category)

    def test_un_codice_sbagliato_non_abbina(self):
        self.pc.sync.apri_abbinamento()
        with self.assertRaises(sync_net.RifiutoSync):
            self.collega(self.tel, self.pc, "000000")
        self.assertEqual([], self.pc.sync.dispositivi())

    def test_revocare_chiude_la_porta(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        self.assertEqual(1, len(self.pc.sync.dispositivi()))
        self.assertTrue(self.pc.sync.revoca(self.tel.sync.id_dispositivo))

        with self.assertRaises(sync_net.RifiutoSync):
            self.collega(self.tel, self.pc)

    def test_niente_da_fare_non_cambia_niente(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        prima = self.tel.titoli()
        esito = self.collega(self.tel, self.pc)
        self.assertEqual(prima, self.tel.titoli())
        self.assertEqual(0, esito.get("aggiunte", 0))
        self.assertEqual(0, esito.get("conflitti", 0))


class TestConflitti(BaseDueDispositivi):

    def _abbina_e_allinea(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

    def _cambia(self, d: Dispositivo, titolo: str, nuovo_valore: str):
        v = next(c for c in d.store.entries if c.title == titolo)
        d.store.update(v.id, titolo, [{"label": "password", "value": nuovo_valore}],
                       list(v.tags))
        return v.uid

    def test_la_stessa_voce_cambiata_da_entrambi_diventa_un_conflitto(self):
        """Il caso per cui esiste tutto il resto. Nessuna delle due password
        deve sparire, e nessuno dei due deve decidere al posto dell'utente."""
        self._abbina_e_allinea()
        uid = self._cambia(self.pc, "Banca", "nuova-dal-pc")
        self._cambia(self.tel, "Banca", "nuova-dal-telefono")

        esito = self.collega(self.tel, self.pc)

        self.assertEqual(1, esito.get("conflitti"))
        self.assertIn(uid, self.tel.sync.conflitti)
        # finche' non si decide, ognuno tiene la sua: niente sparisce
        mia = next(c for c in self.tel.store.entries if c.uid == uid)
        self.assertEqual("nuova-dal-telefono", mia.fields[0].value)

    def test_il_conflitto_non_mostra_i_valori(self):
        """Scegliere fra due versioni non deve costringere a farsi stampare due
        password sullo schermo: si mostrano le etichette, mai i valori."""
        self._abbina_e_allinea()
        self._cambia(self.pc, "Banca", "nuova-dal-pc")
        self._cambia(self.tel, "Banca", "nuova-dal-telefono")
        self.collega(self.tel, self.pc)

        testo = repr(self.tel.sync.elenco_conflitti())
        self.assertIn("password", testo, "le etichette servono a capire cosa c'e'")
        self.assertNotIn("nuova-dal-pc", testo)
        self.assertNotIn("nuova-dal-telefono", testo)

    def test_una_scelta_non_si_ripresenta_su_chi_l_ha_fatta(self):
        """Chi decide, decide una volta sola: la base registra il `rev` che
        aveva l'altro, e da li' in poi la voce non risulta piu' contesa."""
        self._abbina_e_allinea()
        uid = self._cambia(self.pc, "Banca", "nuova-dal-pc")
        self._cambia(self.tel, "Banca", "nuova-dal-telefono")
        self.collega(self.tel, self.pc)

        self.assertTrue(self.tel.sync.risolvi(uid, "mia"))
        self.assertEqual({}, self.tel.sync.conflitti)

        esito = self.collega(self.tel, self.pc)
        self.assertEqual(0, esito.get("conflitti", 0), "richiesto di nuovo a chi aveva gia' scelto")
        mia = next(c for c in self.tel.store.entries if c.uid == uid)
        self.assertEqual("nuova-dal-telefono", mia.fields[0].value)

    def test_l_altro_dispositivo_chiede_una_volta_e_poi_si_converge(self):
        """Il limite onesto del contatore singolo: `rev` dice quante volte una
        voce e' cambiata, non da quale versione discende. Chi ha lo stesso
        conflitto in sospeso lo chiede una volta anche a te — e dopo quella
        risposta i due restano allineati per sempre."""
        self._abbina_e_allinea()
        uid = self._cambia(self.pc, "Banca", "nuova-dal-pc")
        self._cambia(self.tel, "Banca", "nuova-dal-telefono")
        self.collega(self.tel, self.pc)

        self.tel.sync.risolvi(uid, "mia")            # decide il telefono
        self.collega(self.tel, self.pc)
        self.assertIn(uid, self.pc.sync.conflitti, "il PC deve chiedere una volta")

        self.pc.sync.risolvi(uid, "sua")             # e il PC accetta
        di_la = next(c for c in self.pc.store.entries if c.uid == uid)
        self.assertEqual("nuova-dal-telefono", di_la.fields[0].value)

        # da qui in poi silenzio: nessuno chiede piu' niente
        for _ in range(2):
            esito = self.collega(self.tel, self.pc)
            self.assertEqual(0, esito.get("conflitti", 0))
        self.assertEqual({}, self.tel.sync.conflitti)
        self.assertEqual({}, self.pc.sync.conflitti)

    def test_scegliere_quella_dell_altro(self):
        self._abbina_e_allinea()
        uid = self._cambia(self.pc, "Banca", "nuova-dal-pc")
        self._cambia(self.tel, "Banca", "nuova-dal-telefono")
        self.collega(self.tel, self.pc)

        self.assertTrue(self.tel.sync.risolvi(uid, "sua"))
        mia = next(c for c in self.tel.store.entries if c.uid == uid)
        self.assertEqual("nuova-dal-pc", mia.fields[0].value)

    def test_un_conflitto_non_deciso_si_ripresenta(self):
        """La base esclude le voci contese apposta: se l'app si chiude prima
        che tu abbia scelto, al giro dopo la domanda torna invece di sparire."""
        self._abbina_e_allinea()
        self._cambia(self.pc, "Banca", "nuova-dal-pc")
        self._cambia(self.tel, "Banca", "nuova-dal-telefono")

        self.collega(self.tel, self.pc)
        self.tel.sync.conflitti = {}          # come se l'app si fosse chiusa
        esito = self.collega(self.tel, self.pc)
        self.assertEqual(1, esito.get("conflitti"))

    def test_modificata_qui_e_cancellata_di_la(self):
        """Buttare la modifica sarebbe perdere lavoro che il cancellatore non
        ha mai visto: si chiede."""
        self._abbina_e_allinea()
        uid = self._cambia(self.tel, "Amazon", "aggiornata-sul-telefono")
        voce_pc = next(c for c in self.pc.store.entries if c.title == "Amazon")
        self.pc.store.delete(voce_pc.id)

        esito = self.collega(self.tel, self.pc)
        self.assertEqual(1, esito.get("conflitti"))
        self.assertIn("Amazon", self.tel.titoli())

        # e scegliendo di tenerla, resta
        self.assertTrue(self.tel.sync.risolvi(uid, "mia"))
        self.assertIn("Amazon", self.tel.titoli())


class TestMasterDiversa(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vaultmind-sync-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_due_vault_diversi_non_si_parlano(self):
        """Non e' un errore di rete: e' un vault diverso, e riprovare non serve.
        Il messaggio deve dire cosa fare davvero."""
        a = os.path.join(self.dir, "a.json")
        b = os.path.join(self.dir, "b.json")
        for path, master in ((a, MASTER), (b, "un'altra-password")):
            s = VaultStore(path)
            s.create(master)
            s.add("Voce", [{"label": "p", "value": "x"}], [])

        uno = Dispositivo(a, "Uno", porta=0)
        due = Dispositivo(b, "Due", porta=0)
        uno.store.unlock(MASTER)
        due.store.unlock("un'altra-password")

        codice = uno.sync.apri_abbinamento()["codice"]
        self.assertTrue(uno.sync.avvia())
        self.addCleanup(uno.sync.ferma)
        with self.assertRaises(sync_net.RifiutoSync) as e:
            due.sync.sincronizza_con("127.0.0.1", uno.sync.porta_vera, codice)
        self.assertIn("chiave", str(e.exception).lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
