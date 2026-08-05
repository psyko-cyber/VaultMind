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

from app.crypto_store import VaultStore, derive_key  # noqa: E402
from app.sync_app import SyncApp  # noqa: E402
from app import sync_net  # noqa: E402

MASTER = "master-di-prova-1"


class Dispositivo:
    """Un finto dispositivo: un vault sul disco e il suo SyncApp."""

    def __init__(self, path: str, nome: str, porta: int = 0):
        self.store = VaultStore(path)
        self.impostazioni: dict = {}
        #: Quante volte l'app e' stata avvisata che il vault e' cambiato sotto
        #: i suoi piedi. Sul PC vero e' il segnale che rifa' l'indice della
        #: ricerca e sveglia la pagina aperta.
        self.avvisi = 0
        self.sync = SyncApp(
            store_di=lambda: self.store,
            leggi_impostazioni=lambda: self.impostazioni,
            salva_impostazioni=lambda s: self.impostazioni.update(s),
            porta=porta,
            porta_scoperta=0,   # niente scoperta: qui ci si collega a mano
            dopo_fusione=self._avvisato,
        )
        self.sync.imposta(nome=nome)

    def _avvisato(self):
        self.avvisi += 1

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


class TestAccorgersene(BaseDueDispositivi):
    """Chi RICEVE deve sapere di aver ricevuto.

    Il vault che arriva lo applica un thread dell'ascoltatore, dentro il
    server: l'interfaccia non ne sa niente. Prima del 04/08/2026 la voce
    arrivata dal telefono si vedeva sul PC solo chiudendo e riaprendo l'app —
    il dato c'era gia' e veniva nascosto. Da qui passa anche l'indice della
    ricerca, che senza avviso resta indietro e fa dire alla chat «non trovo
    niente» su una voce che nel vault c'e'.
    """

    def test_chi_riceve_qualcosa_lo_sa(self):
        self.tel.store.add("Slack", [{"label": "password", "value": "s"}], [])
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)

        self.assertIn("Slack", self.pc.titoli())
        self.assertEqual(1, self.pc.sync.revisione,
                         "il PC ha applicato una fusione senza contarla")
        self.assertGreaterEqual(self.pc.avvisi, 1,
                                "l'app non e' stata avvisata: indice vecchio e pagina vecchia")

    def test_un_sync_a_vuoto_non_riscrive_e_non_sveglia_nessuno(self):
        """Il sync automatico parte a ogni modifica, quindi capita
        continuamente che l'altro non abbia niente da darci. `applica_fusione`
        ri-cifra l'INTERO vault: senza questo controllo sarebbe un megabyte
        riscritto per confermare che eravamo gia' allineati, e la pagina si
        ricaricherebbe da sola per niente."""
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        rev = self.pc.sync.revisione
        avvisi = self.pc.avvisi
        with open(self.pc.store.path, "rb") as f:
            prima = f.read()

        self.pc.sync.ultimo = None     # senza, collega() non aspetta il server
        self.collega(self.tel, self.pc)

        with open(self.pc.store.path, "rb") as f:
            self.assertEqual(prima, f.read(), "il vault e' stato riscritto per niente")
        self.assertEqual(rev, self.pc.sync.revisione)
        self.assertEqual(avvisi, self.pc.avvisi)

    def test_anche_risolvere_un_conflitto_conta_come_cambiamento(self):
        """La scelta cambia il vault quanto una voce in arrivo: se non
        contasse, l'elenco aperto resterebbe con la versione scartata."""
        self.pc.store.update(1, "Banca", [{"label": "password", "value": "pc"}], [])
        self.tel.store.update(1, "Banca", [{"label": "password", "value": "tel"}], [])
        codice = self.pc.sync.apri_abbinamento()["codice"]
        esito = self.collega(self.tel, self.pc, codice)
        self.assertEqual(1, esito["conflitti"])

        uid = next(iter(self.tel.sync.conflitti))
        prima = self.tel.sync.revisione
        self.assertTrue(self.tel.sync.risolvi(uid, "mia"))
        self.assertGreater(self.tel.sync.revisione, prima)


class TestPrimoTravaso(unittest.TestCase):
    """Il telefono appena installato non ha il vault: se lo fa mandare dal PC.

    Sostituisce il passaggio "salva un backup, mandatelo su WhatsApp, aprilo".
    Non c'e' nessun protocollo nuovo: durante l'abbinamento il PC risponde
    anche a chi non firma la sonda e gli da' il `salt`, che non e' segreto. Da
    li' il telefono ricava la STESSA chiave dalla master password, si crea un
    vault vuoto con quel salt, e lascia che sia la fusione normale a
    riempirlo. E' quello che fa `mobile/lib/schermate/travaso.dart`.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vaultmind-travaso-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        pc = os.path.join(self.dir, "pc.json")
        s = VaultStore(pc)
        s.create(MASTER)
        s.add_many([
            {"title": "Banca", "fields": [{"label": "password", "value": "b"}]},
            {"title": "Amazon", "fields": [{"label": "password", "value": "a"}]},
        ])
        self.pc = Dispositivo(pc, "PC", porta=0)
        self.pc.store.unlock(MASTER)

    def _telefono_appena_installato(self, master: str = MASTER) -> Dispositivo:
        """Quello che fa il telefono: salt dalla scoperta, chiave dalla master
        password, e un vault VUOTO con quel salt. Vuoto davvero — nessuna voce
        e **nessuna lapide**."""
        salt = self.pc.store.salt
        path = os.path.join(self.dir, "telefono.json")
        st = VaultStore(path)
        st.create(master)
        st._salt = salt
        st._key = derive_key(master, salt)
        st._flush()
        d = Dispositivo(path, "Telefono", porta=0)
        d.store.unlock(master)
        return d

    def _aspetta_il_pc(self):
        for _ in range(60):
            if self.pc.sync.ultimo:
                return
            time.sleep(0.05)

    def test_il_vault_arriva_e_il_pc_non_perde_niente(self):
        tel = self._telefono_appena_installato()
        self.assertEqual([], tel.titoli(), "il telefono doveva partire vuoto")

        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.assertTrue(self.pc.sync.avvia())
        self.addCleanup(self.pc.sync.ferma)
        esito = tel.sync.sincronizza_con("127.0.0.1", self.pc.sync.porta_vera, codice)
        self._aspetta_il_pc()

        self.assertTrue(esito["ok"])
        self.assertEqual(["Amazon", "Banca"], tel.titoli())
        # Il punto che conta piu' di tutti: il PC e' il vault VERO, e uno
        # sbaglio qui lo svuoterebbe da un dispositivo appena installato.
        self.assertEqual(["Amazon", "Banca"], self.pc.titoli())
        self.assertEqual([], self.pc.store.tombstones)
        self.assertEqual(0, self.pc.sync.revisione,
                         "il PC non doveva avere niente da applicare")

    def test_la_chiave_si_ricava_dal_salt_senza_avere_il_vault(self):
        """Il cuore del travaso: due file diversi, nessuna copia passata a
        mano, e la stessa chiave — perche' il salt viaggia in chiaro (non e'
        un segreto) e la master password non viaggia affatto."""
        tel = self._telefono_appena_installato()
        self.assertEqual(self.pc.store.salt, tel.store.salt)
        self.assertEqual(self.pc.store.chiave, tel.store.chiave)

    def test_una_master_diversa_non_apre_e_non_porta_via_niente(self):
        tel = self._telefono_appena_installato(master="quella-sbagliata")
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.assertTrue(self.pc.sync.avvia())
        self.addCleanup(self.pc.sync.ferma)

        with self.assertRaises(sync_net.RifiutoSync):
            tel.sync.sincronizza_con("127.0.0.1", self.pc.sync.porta_vera, codice)

        self.assertEqual([], tel.titoli())
        self.assertEqual(["Amazon", "Banca"], self.pc.titoli())

    def test_svuotare_un_vault_NON_e_un_modo_di_partire_da_zero(self):
        """Perche' `travaso.dart` costruisce un vault vuoto invece di svuotarne
        uno gia' esistente: `clear()` lascia una **lapide per ogni voce**, e le
        lapidi al primo sync vincono sulle voci vive. Un telefono che partisse
        cosi' cancellerebbe il vault del PC, che e' l'unica copia vera.

        Il test pretende il disastro apposta: se un domani qualcuno
        "semplificasse" il travaso riusando `clear()`, questo resta a dire
        perche' non si fa."""
        copia = os.path.join(self.dir, "sbagliato.json")
        shutil.copyfile(self.pc.store.path, copia)
        tel = Dispositivo(copia, "Telefono", porta=0)
        tel.store.unlock(MASTER)
        tel.store.clear()
        self.assertEqual(2, len(tel.store.tombstones), "clear() lascia lapidi")

        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.assertTrue(self.pc.sync.avvia())
        self.addCleanup(self.pc.sync.ferma)
        tel.sync.sincronizza_con("127.0.0.1", self.pc.sync.porta_vera, codice)
        self._aspetta_il_pc()

        self.assertEqual([], self.pc.titoli(),
                         "se questo non fosse vero, il commento in travaso.dart "
                         "sarebbe una paura infondata e andrebbe tolto")


class TestFuoriCasa(BaseDueDispositivi):
    """L'indirizzo ricordato: quello che fa funzionare il sync da fuori.

    La scoperta e' in broadcast, e un tunnel VPN e' un collegamento
    punto-punto instradato: i broadcast non ci passano, quindi da fuori casa
    non si trova mai nessuno — la strada c'e', ma la domanda non arriva.
    L'indirizzo imparato in casa pero' resta valido ATTRAVERSO il tunnel, ed e'
    tutto quello che serve.
    """

    def test_l_indirizzo_si_impara_sincronizzando(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        d = self.tel.sync.dispositivi()[0]
        self.assertEqual("127.0.0.1", d.get("indirizzo"))
        self.assertEqual(self.pc.sync.porta_vera, d.get("porta"))

    def test_senza_scoperta_si_va_dove_rispondeva_prima(self):
        """Il caso vero: telefono in 4G dentro la VPN. La sonda non arriva a
        nessuno, e il sync deve funzionare lo stesso."""
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        self.pc.store.add("Da casa", [{"label": "p", "value": "x"}], [])
        self.pc.sync.ultimo = None
        esito = self.tel.sync.sincronizza_tutti()

        self.assertTrue(esito["ok"])
        self.assertEqual(0, esito["trovati"], "la scoperta non doveva trovare niente")
        self.assertEqual(1, esito["abbinati"], "l'indirizzo ricordato non e' stato usato")
        self.assertIn("Da casa", self.tel.titoli())

    def test_non_si_tiene_traccia_di_chi_non_e_abbinato(self):
        """L'elenco degli indirizzi segue quello dei fidati: tenere l'indirizzo
        di un dispositivo che non ci riguarda sarebbe raccogliere dati per
        niente, ed e' esattamente quello che questo progetto non fa."""
        self.tel.sync._ricorda_dove("mai-visto", "10.0.0.9", 8732)
        self.assertEqual([], self.tel.sync.dispositivi())

    def test_revocare_dimentica_anche_dove_stava(self):
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        id_pc = self.pc.sync.id_dispositivo
        self.assertTrue(self.tel.sync.revoca(id_pc))
        # e adesso un giro non deve piu' bussare a quell'indirizzo
        esito = self.tel.sync.sincronizza_tutti()
        self.assertEqual(0, esito["abbinati"])


class TestSyncSubito(BaseDueDispositivi):
    """`sincronizza_tutti` e `programma_sync`: quello che sta dietro al
    pulsante in barra e al sync che parte da solo."""

    def test_a_vault_chiuso_non_prova_nemmeno(self):
        self.pc.store.lock()
        esito = self.pc.sync.sincronizza_tutti()
        self.assertFalse(esito["ok"])
        self.assertEqual([], esito["esiti"])

    def test_senza_nessuno_abbinato_non_parte_nessuna_sonda(self):
        """Chi non ha ancora abbinato niente non deve mettersi a chiamare
        sulla rete a ogni voce che salva."""
        self.assertTrue(self.pc.sync.avvia())
        self.addCleanup(self.pc.sync.ferma)
        self.pc.sync.programma_sync(ritardo=0.05)
        self.assertIsNone(self.pc.sync._rinvio)

    def test_il_rinvio_si_sposta_in_avanti_a_ogni_modifica(self):
        """Le modifiche arrivano a raffica — salvi una voce, cambi categoria,
        ne salvi un'altra — e ognuna farebbe partire uno scambio dell'intero
        vault. Deve partirne uno solo, quando ti fermi."""
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        self.assertTrue(self.pc.sync.avvia())
        self.addCleanup(self.pc.sync.ferma)
        self.pc.sync.programma_sync(ritardo=30)
        primo = self.pc.sync._rinvio
        self.assertIsNotNone(primo)
        self.pc.sync.programma_sync(ritardo=30)
        self.assertIsNot(primo, self.pc.sync._rinvio, "il rinvio non e' stato spostato")
        self.assertFalse(primo.is_alive(), "il rinvio precedente e' rimasto in piedi")

    def test_chiudere_il_vault_annulla_il_sync_rinviato(self):
        """Un sync che scatta a vault chiuso non troverebbe la chiave, ma
        proverebbe lo stesso a farsi vivo sulla rete."""
        codice = self.pc.sync.apri_abbinamento()["codice"]
        self.collega(self.tel, self.pc, codice)
        self.pc.sync.chiudi_abbinamento()

        self.assertTrue(self.pc.sync.avvia())
        self.pc.sync.programma_sync(ritardo=30)
        self.assertIsNotNone(self.pc.sync._rinvio)
        self.pc.sync.ferma()
        self.assertIsNone(self.pc.sync._rinvio)


if __name__ == "__main__":
    unittest.main(verbosity=2)
