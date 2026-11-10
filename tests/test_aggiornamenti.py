r"""
Test sul controllo degli aggiornamenti (`app/aggiornamenti.py` e la colla in
`app/server.py`).

Il confronto fra versioni non sta qui dentro: sta in
`vettore/versioni.json`, un elenco di casi che **anche la suite Dart esegue**.
Due implementazioni dello stesso confronto sono un'app che si aggiorna sul PC
e non sul telefono — o un telefono che propone all'infinito la versione che ha
gia' installato.

Qui si prova il resto, e tutto **senza toccare la rete**: che una risposta
illeggibile non diventi mai un aggiornamento, che l'assenza di connessione sia
un non-evento, e che il tetto delle 12 ore sia davvero un tetto.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import aggiornamenti, __version__  # noqa: E402


_SCARICA = "https://github.com/psyko-cyber/VaultMind/releases/download/v7.0/"


def _release(tag="7.0", allegati=("VaultMind-Setup.exe", "SHA256SUMS.txt",
                                  "SHA256SUMS.txt.sig"), base=_SCARICA) -> str:
    """Una risposta di GitHub come quella vera, ridotta ai campi che leggiamo."""
    return json.dumps({
        "tag_name": tag,
        "html_url": f"https://github.com/psyko-cyber/VaultMind/releases/tag/{tag}",
        "body": "## Novita\n**Aggiornamenti dentro l'app**\n\n\n- e altro",
        "assets": [
            {"name": n, "browser_download_url": f"{base}{n}"}
            for n in allegati
        ],
    })


class _Risposta:
    """Il minimo che `urlopen` restituisce: un gestore di contesto con
    `status`, `headers` e `read()`."""

    def __init__(self, corpo: str, status: int = 200):
        self._corpo = corpo.encode("utf-8")
        self.status = status
        self.headers = {"Content-Length": str(len(self._corpo))}

    def read(self, quanti: int = -1) -> bytes:
        return self._corpo

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class TestConfrontoVersioni(unittest.TestCase):
    """Il contratto condiviso con Dart."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(_QUI, "vettore", "versioni.json"), encoding="utf-8") as f:
            cls.casi = json.load(f)["casi"]

    def test_ogni_caso_del_vettore(self):
        self.assertGreater(len(self.casi), 10, "il vettore si e' svuotato")
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                self.assertEqual(
                    aggiornamenti.piu_recente(caso["a"], caso["b"]),
                    caso["piuRecente"],
                    f'{caso["a"]!r} > {caso["b"]!r}: ' + caso.get("perche", ""),
                )

    def test_la_versione_del_prodotto_e_un_numero(self):
        # Era "0.1.0" mentre l'installer dichiarava 6.8: con il controllo degli
        # aggiornamenti un numero scollegato significa non aggiornarsi mai.
        self.assertRegex(__version__, r"^\d+(\.\d+)*$")


class TestLetturaRelease(unittest.TestCase):
    """Della forma di una risposta altrui non si da' mai niente per buono."""

    def test_release_vera(self):
        i = aggiornamenti.leggi_release(_release())
        self.assertIsNotNone(i)
        self.assertEqual(i["versione"], "7.0")
        self.assertEqual(i["download"], _SCARICA + "VaultMind-Setup.exe")
        self.assertEqual(i["sums"], _SCARICA + "SHA256SUMS.txt")
        self.assertEqual(i["firma"], _SCARICA + "SHA256SUMS.txt.sig")
        self.assertTrue(aggiornamenti.installabile(i))

    def test_allegati_ospitati_altrove_non_si_prendono(self):
        # L'indirizzo finisce nelle impostazioni e si rilegge al momento di
        # installare: deve essere una release del nostro repo, non «un .exe».
        for base in ("https://esempio/", "http://github.com/psyko-cyber/VaultMind/releases/download/v7.0/",
                     "https://github.com/altro/VaultMind/releases/download/v7.0/",
                     "https://github.com.esempio/psyko-cyber/VaultMind/releases/download/v7.0/"):
            with self.subTest(base):
                i = aggiornamenti.leggi_release(_release(base=base))
                self.assertIsNone(i["download"])
                self.assertFalse(aggiornamenti.installabile(i))

    def test_senza_firma_non_e_installabile(self):
        i = aggiornamenti.leggi_release(
            _release(allegati=("VaultMind-Setup.exe", "SHA256SUMS.txt")))
        self.assertIsNotNone(i["download"])
        self.assertFalse(aggiornamenti.installabile(i))

    def test_il_v_del_tag_sparisce(self):
        self.assertEqual(aggiornamenti.leggi_release(_release("v7.1"))["versione"], "7.1")

    def test_senza_allegati(self):
        i = aggiornamenti.leggi_release(_release(allegati=()))
        self.assertIsNotNone(i)
        self.assertIsNone(i["download"])

    def test_lo_zip_non_e_il_setup(self):
        # Sulla release ci sono anche gli zip e l'APK: si cerca per nome.
        i = aggiornamenti.leggi_release(
            _release(allegati=("VaultMind-Windows.zip", "VaultMind.apk")))
        self.assertIsNone(i["download"])

    def test_risposte_che_non_sono_release(self):
        # Il portale Wi-Fi dell'hotel che risponde 200 con la sua pagina, un
        # proxy che restituisce una lista, un tag che non e' un numero.
        for corpo in ("<html>Accedi alla rete</html>", "", "[]", "null",
                      json.dumps({"tag_name": "ultima"}),
                      json.dumps({"tag_name": ""}),
                      json.dumps({"tag_name": "7.0; rm -rf"})):
            with self.subTest(corpo[:30]):
                self.assertIsNone(aggiornamenti.leggi_release(corpo))

    def test_allegati_malformati_non_fanno_cadere_niente(self):
        corpo = json.dumps({
            "tag_name": "7.0",
            "assets": ["non un oggetto", {"name": "VaultMind-Setup.exe"},
                       {"name": "VaultMind-Setup.exe", "browser_download_url": 42}],
        })
        i = aggiornamenti.leggi_release(corpo)
        self.assertIsNotNone(i)
        self.assertIsNone(i["download"])

    def test_note_in_testo_semplice(self):
        note = aggiornamenti.note_pulite(aggiornamenti.leggi_release(_release())["note"])
        self.assertNotIn("#", note)
        self.assertNotIn("**", note)
        self.assertNotIn("\n\n\n", note)
        self.assertTrue(note.startswith("Novita"))

    def test_note_troppo_lunghe_si_tagliano(self):
        note = aggiornamenti.note_pulite("\n".join(str(n) for n in range(50)), righe=5)
        self.assertEqual(note.splitlines()[-1], "…")
        self.assertEqual(len(note.splitlines()), 6)


class TestImpronte(unittest.TestCase):
    def test_formati_di_sha256sums(self):
        atteso = "a" * 64
        for riga in (f"{atteso} *VaultMind-Setup.exe",
                     f"{atteso}  VaultMind-Setup.exe",
                     f"b{'a' * 63} *altro.exe\n{atteso} *VaultMind-Setup.exe"):
            with self.subTest(riga[:20]):
                self.assertEqual(
                    aggiornamenti.sha_atteso(riga, "VaultMind-Setup.exe"), atteso)

    def test_maiuscole_normalizzate(self):
        self.assertEqual(
            aggiornamenti.sha_atteso("A" * 64 + " *x.exe", "x.exe"), "a" * 64)

    def test_file_assente_o_riga_rotta(self):
        for sums in ("", "non un'impronta  VaultMind-Setup.exe",
                     "a" * 63 + " *VaultMind-Setup.exe",
                     "a" * 64 + " *altro.exe"):
            with self.subTest(sums[:20]):
                self.assertIsNone(
                    aggiornamenti.sha_atteso(sums, "VaultMind-Setup.exe"))


class TestSenzaRete(unittest.TestCase):
    """Nessuna connessione e' un non-evento: nessuna eccezione, nessun avviso."""

    def test_cerca_non_solleva_mai(self):
        for guasto in (OSError("niente rete"), ValueError("DNS strano"),
                       TimeoutError(), Exception("boh")):
            with self.subTest(type(guasto).__name__):
                with mock.patch.object(aggiornamenti.urllib.request, "urlopen",
                                       side_effect=guasto):
                    self.assertIsNone(aggiornamenti.cerca())

    def test_risposta_non_200(self):
        with mock.patch.object(aggiornamenti.urllib.request, "urlopen",
                               return_value=_Risposta("{}", status=404)):
            self.assertIsNone(aggiornamenti.cerca())

    def test_risposta_buona(self):
        with mock.patch.object(aggiornamenti.urllib.request, "urlopen",
                               return_value=_Risposta(_release())):
            self.assertEqual(aggiornamenti.cerca()["versione"], "7.0")

    def test_scarica_senza_allegato(self):
        with self.assertRaises(ValueError):
            aggiornamenti.scarica({"versione": "7.0"})


class TestFirma(unittest.TestCase):
    """Il setup si installa solo se le impronte sono firmate con la nostra
    chiave (pentest del 10/11/2026, A2). Qui la chiave e' una di prova: quella
    vera sta fuori dal repo."""

    SETUP = b"MZ finto setup di VaultMind" * 100

    @classmethod
    def setUpClass(cls):
        import base64
        import hashlib
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        cls.chiave = Ed25519PrivateKey.generate()
        cls.pubblica = cls.chiave.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
        cls.somme = (hashlib.sha256(cls.SETUP).hexdigest()
                     + " *VaultMind-Setup.exe\n").encode("ascii")
        cls.firma = base64.b64encode(cls.chiave.sign(cls.somme)).decode("ascii") + "\n"
        cls.info = aggiornamenti.leggi_release(_release())

    def tearDown(self):
        aggiornamenti.pulisci()

    def _scarica(self, setup=None, somme=None, firma=None, manca=()):
        corpi = {"VaultMind-Setup.exe": self.SETUP if setup is None else setup,
                 "SHA256SUMS.txt": self.somme if somme is None else somme,
                 "SHA256SUMS.txt.sig": (self.firma if firma is None else firma).encode("ascii")}

        def finta(richiesta, timeout=None):
            nome = richiesta.full_url.rsplit("/", 1)[-1]
            if nome in manca:
                raise OSError("404")
            r = _Risposta("")
            r._corpo = corpi[nome]
            r.headers = {"Content-Length": str(len(r._corpo))}
            # `scarica` legge a blocchi finche' non arriva un blocco vuoto.
            pezzi = [r._corpo, b""]
            r.read = lambda quanti=-1: pezzi.pop(0) if pezzi else b""
            return r

        with mock.patch.object(aggiornamenti, "CHIAVE_PUBBLICA", self.pubblica):
            with mock.patch.object(aggiornamenti.urllib.request, "urlopen", side_effect=finta):
                return aggiornamenti.scarica(self.info)

    def test_release_firmata_si_scarica(self):
        percorso = self._scarica()
        with open(percorso, "rb") as f:
            self.assertEqual(f.read(), self.SETUP)

    def test_la_chiave_vera_non_e_quella_di_prova(self):
        # Se un giorno questo test firmasse con la chiave dentro l'app, la
        # chiave privata sarebbe finita nel repo.
        self.assertNotEqual(self.pubblica, aggiornamenti.CHIAVE_PUBBLICA)
        self.assertEqual(len(bytes.fromhex(aggiornamenti.CHIAVE_PUBBLICA)), 32)

    def test_impronte_di_un_altro_non_passano(self):
        # Il caso del pentest: chi pubblica la release pubblica anche le sue
        # impronte, giuste per il SUO setup. Senza la nostra firma non vale.
        import hashlib
        suo = b"MZ setup di qualcun altro"
        sue_somme = (hashlib.sha256(suo).hexdigest() + " *VaultMind-Setup.exe\n").encode()
        with self.assertRaises(IOError) as e:
            self._scarica(setup=suo, somme=sue_somme)
        self.assertIn("firma", str(e.exception).lower())
        self.assertFalse(os.path.exists(os.path.join(aggiornamenti.cartella(), "VaultMind-Setup.exe")))

    def test_firma_di_un_altra_chiave(self):
        import base64
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        altra = base64.b64encode(Ed25519PrivateKey.generate().sign(self.somme)).decode()
        with self.assertRaises(IOError):
            self._scarica(firma=altra)

    def test_firma_storta_o_assente(self):
        for firma in ("", "non base64 !!", "AAAA"):
            with self.subTest(firma):
                with self.assertRaises(IOError):
                    self._scarica(firma=firma)
        with self.assertRaises(IOError):
            self._scarica(manca=("SHA256SUMS.txt.sig",))

    def test_setup_diverso_da_quello_firmato(self):
        with self.assertRaises(IOError) as e:
            self._scarica(setup=self.SETUP + b"!")
        self.assertIn("sha-256", str(e.exception).lower())

    def test_firma_valida_non_solleva_mai(self):
        for somme, firma, chiave in ((b"x", "", None), (b"x", "AAAA", "zz"), (b"", "ÿ", "00")):
            self.assertFalse(aggiornamenti.firma_valida(somme, firma, chiave))


class TestControlloNelServer(unittest.TestCase):
    """Il tetto delle 12 ore, la memoria di quello che si sapeva, l'interruttore.

    `server.py` legge e scrive `settings.json` accanto al vault: qui il vault
    sta in una cartella temporanea (`VAULTMIND_FILE`), perche' su questa
    macchina `~/.vaultmind` e' il vault VERO.
    """

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="vm_agg_")
        os.environ["VAULTMIND_FILE"] = os.path.join(cls.dir, "vault.json")
        if "app.server" in sys.modules:
            raise unittest.SkipTest(
                "app.server importato da un altro test: non si rischia di "
                "scrivere nelle impostazioni vere")
        from app import server  # noqa: E402
        cls.server = server
        if not server.SETTINGS_PATH.startswith(cls.dir):
            raise unittest.SkipTest(
                f"le impostazioni finirebbero in {server.SETTINGS_PATH}")

    @classmethod
    def tearDownClass(cls):
        os.environ.pop("VAULTMIND_FILE", None)
        shutil.rmtree(cls.dir, ignore_errors=True)

    def setUp(self):
        self.server._save_settings({})

    def _nuova(self, versione="99.0"):
        return {"versione": versione, "pagina": "https://esempio",
                "note": "", "download": _SCARICA + "VaultMind-Setup.exe",
                "sums": _SCARICA + "SHA256SUMS.txt",
                "firma": _SCARICA + "SHA256SUMS.txt.sig"}

    def test_spento_non_chiede_niente(self):
        self.server._save_settings({"aggiornamenti": False})
        with mock.patch.object(aggiornamenti, "cerca",
                               side_effect=AssertionError("non deve chiedere")):
            self.assertEqual(self.server._agg_controlla(), (None, True))

    def test_trova_e_ricorda(self):
        with mock.patch.object(aggiornamenti, "cerca", return_value=self._nuova()):
            trovata, risposto = self.server._agg_controlla()
        self.assertEqual(trovata["versione"], "99.0")
        self.assertTrue(risposto)
        self.assertEqual(self.server._load_settings()["agg_trovata"]["versione"], "99.0")

    def test_non_chiede_due_volte_in_dodici_ore(self):
        with mock.patch.object(aggiornamenti, "cerca", return_value=self._nuova()):
            self.server._agg_controlla()
        with mock.patch.object(aggiornamenti, "cerca",
                               side_effect=AssertionError("tetto non rispettato")):
            trovata, _ = self.server._agg_controlla()
        self.assertEqual(trovata["versione"], "99.0")   # dalla memoria

    def test_forza_chiede_comunque(self):
        with mock.patch.object(aggiornamenti, "cerca", return_value=self._nuova()):
            self.server._agg_controlla()
        with mock.patch.object(aggiornamenti, "cerca", return_value=None) as finta:
            self.server._agg_controlla(forza=True)
        finta.assert_called_once()

    def test_senza_rete_si_tiene_quello_che_si_sapeva(self):
        with mock.patch.object(aggiornamenti, "cerca", return_value=self._nuova()):
            self.server._agg_controlla()
        with mock.patch.object(aggiornamenti, "cerca", return_value=None):
            trovata, risposto = self.server._agg_controlla(forza=True)
        self.assertEqual(trovata["versione"], "99.0")
        self.assertFalse(risposto, "chi premuto un pulsante deve sapere che non si sa")

    def test_dopo_l_aggiornamento_la_nota_smette_di_comparire(self):
        # La versione ricordata e' quella che gia' si ha: non e' una novita'.
        self.server._save_settings({"agg_trovata": self._nuova(__version__),
                                    "agg_controllo": aggiornamenti.ora_ms()})
        self.assertEqual(self.server._agg_controlla(), (None, True))

    def test_una_release_piu_vecchia_non_e_un_aggiornamento(self):
        with mock.patch.object(aggiornamenti, "cerca",
                               return_value=self._nuova("0.1")):
            self.assertEqual(self.server._agg_controlla()[0], None)
        self.assertIsNone(self.server._load_settings().get("agg_trovata"))

    def test_rinvio(self):
        nuova = self._nuova()
        s = self.server._load_settings()
        self.assertFalse(self.server._agg_rinviata(s, "99.0"))
        self.server.aggiornamento_rinvia(self.server.RinviaIn(versione="99.0"))
        s = self.server._load_settings()
        self.assertTrue(self.server._agg_rinviata(s, "99.0"))
        self.assertFalse(self.server._agg_rinviata(s, "99.1"),
                         "il rinvio vale per quella versione, non per sempre")
        # Scaduto il rinvio, si ripropone.
        s["agg_rinviata_quando"] = aggiornamenti.ora_ms() - (
            aggiornamenti.RINVIO_ORE + 1) * 3600_000
        self.assertFalse(self.server._agg_rinviata(s, nuova["versione"]))

    def test_la_risposta_per_la_pagina(self):
        with mock.patch.object(aggiornamenti, "cerca", return_value=self._nuova()):
            fuori = self.server.aggiornamento(forza=True)
        self.assertEqual(fuori["versione"], __version__)
        self.assertTrue(fuori["attiva"])
        self.assertEqual(fuori["nuova"]["versione"], "99.0")
        self.assertTrue(fuori["nuova"]["scaricabile"])
        self.assertFalse(fuori["nuova"]["rinviata"])
        self.assertEqual(fuori["fase"], "fermo")

    def test_le_altre_impostazioni_non_si_perdono(self):
        # Il controllo riscrive settings.json da un thread: se riscrivesse il
        # dizionario letto all'inizio, cancellerebbe quello che l'utente ha
        # salvato nel frattempo.
        self.server._save_settings({"theme": "light", "autolock_minutes": 30})
        with mock.patch.object(aggiornamenti, "cerca", return_value=self._nuova()):
            self.server._agg_controlla()
        s = self.server._load_settings()
        self.assertEqual(s["theme"], "light")
        self.assertEqual(s["autolock_minutes"], 30)


if __name__ == "__main__":
    unittest.main()
