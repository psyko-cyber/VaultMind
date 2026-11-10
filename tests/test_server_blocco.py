r"""
Le difese che il server tiene da solo, senza fidarsi della pagina.

Nascono dal pentest del 10/11/2026: la master debole e i tentativi senza
freno (M5), il blocco automatico che viveva solo nella pagina (M4), il token
dell'estensione che non scadeva mai (M6), le impostazioni che accettavano
qualunque valore (B4), i corpi senza misura (B8).

Il vault non si apre mai per intero qui (`/api/unlock` avvierebbe il sync e
caricherebbe il modello): si provano i pezzi che decidono, con l'orologio in
mano al test.

    tests\run.ps1
"""

from __future__ import annotations
import os
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _QUI)
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

import test_server_accesso as accesso  # noqa: E402  (il server e `chiama`)
from app import master  # noqa: E402
from app.crypto_store import VaultStore  # noqa: E402

server = None
_NOSTRO = False


def setUpModule():
    # Il server lo importa una volta sola `test_server_accesso`, con le sue
    # cautele sul vault vero: qui si riusa il suo.
    global server, _NOSTRO
    if accesso.server is None:
        accesso.setUpModule()
        _NOSTRO = True
    server = accesso.server


def tearDownModule():
    if _NOSTRO:
        accesso.tearDownModule()


class MasterNuova(unittest.TestCase):

    def test_quelle_che_non_passano(self):
        for pw in ("12345678", "corta", "aaaaaaaaaaaaaaaa", "abababababab",
                   "123456789012", "qwertyuiopas", "lkjhgfdsapoi",
                   "password1234", "Password2026!", "passwordpassword",
                   "vaultmind2026", "!!benvenuto!!"):
            with self.subTest(pw=pw):
                self.assertIsInstance(master.troppo_debole(pw), str)

    def test_quelle_che_passano(self):
        for pw in ("cavallo-pila-graffetta", "Tr0mba!verde#lago", "la mia frase lunga",
                   "x9$Lq2@vB7!n"):
            with self.subTest(pw=pw):
                self.assertIsNone(master.troppo_debole(pw))

    def test_il_messaggio_dice_quanti_caratteri(self):
        self.assertIn(str(master.LUNGHEZZA_MINIMA), master.troppo_debole("corta"))


class Freno(unittest.TestCase):

    def setUp(self):
        self.cartella = tempfile.mkdtemp(prefix="vm-freno-")
        self.addCleanup(shutil.rmtree, self.cartella, ignore_errors=True)
        percorso = os.path.join(self.cartella, "vault.json")
        VaultStore(percorso).create("la-master-giusta-2026")
        p = mock.patch.object(server, "DEFAULT_VAULT", percorso)
        p.start()
        self.addCleanup(p.stop)
        server._freno_azzera()
        self.addCleanup(server._freno_azzera)

    def _prova(self, pw: str) -> int:
        try:
            server.unlock(server.UnlockIn(master=pw))
        except server.HTTPException as e:
            return e.status_code
        self.fail("lo sblocco riuscito non si prova qui")

    def test_le_prime_sbagliate_non_fanno_aspettare(self):
        for _ in range(server.TENTATIVI_GRATIS - 1):
            self.assertEqual(self._prova("sbagliata"), 403)
        self.assertEqual(server._freno_attesa(), 0)

    def test_poi_si_aspetta_anche_con_quella_giusta(self):
        for _ in range(server.TENTATIVI_GRATIS):
            self.assertEqual(self._prova("sbagliata"), 403)
        self.assertGreater(server._freno_attesa(), 0)
        # Quella giusta non viene nemmeno provata: altrimenti il freno si
        # scavalca mettendola in mezzo alle altre.
        with mock.patch.object(VaultStore, "unlock") as apri:
            self.assertEqual(self._prova("la-master-giusta-2026"), 429)
            apri.assert_not_called()

    def test_l_attesa_raddoppia_e_ha_un_tetto(self):
        attese = []
        ora = [1000.0]
        with mock.patch.object(server.time, "time", lambda: ora[0]):
            for _ in range(server.TENTATIVI_GRATIS + 12):
                ora[0] += 10000          # ogni volta si è aspettato abbastanza
                self.assertEqual(self._prova("sbagliata"), 403)
                attese.append(server._freno_attesa())
        dopo = attese[server.TENTATIVI_GRATIS - 1:]
        self.assertEqual(dopo[:4], [5, 10, 20, 40])
        self.assertEqual(max(attese), server.ATTESA_MASSIMA_S)
        self.assertEqual(attese[:server.TENTATIVI_GRATIS - 1],
                         [0] * (server.TENTATIVI_GRATIS - 1))

    def test_un_vault_rotto_non_conta_come_tentativo(self):
        with open(server.DEFAULT_VAULT, "w", encoding="utf-8") as f:
            f.write("{non un vault")
        for _ in range(server.TENTATIVI_GRATIS + 2):
            self.assertEqual(self._prova("qualunque"), 422)
        self.assertEqual(server._freno_attesa(), 0)

    def test_master_nuova_debole_rifiutata_alla_creazione(self):
        os.remove(server.DEFAULT_VAULT)
        self.assertEqual(self._prova("12345678"), 400)
        self.assertFalse(os.path.exists(server.DEFAULT_VAULT))


class BloccoAutomatico(unittest.TestCase):

    def setUp(self):
        prima = (server.S.store, server.S.attivo)
        self.addCleanup(lambda: (setattr(server.S, "store", prima[0]),
                                 setattr(server.S, "attivo", prima[1])))
        server.S.store = object()        # «aperto»: qui conta solo che ci sia

    def _con(self, minuti):
        return mock.patch.object(server, "_load_settings",
                                 lambda: {"autolock_minutes": minuti})

    def test_scade_un_minuto_dopo_il_timer_della_pagina(self):
        server.S.attivo = 5000.0
        with self._con(10):
            self.assertFalse(server._scaduto(5000.0 + 600 + 59))
            self.assertTrue(server._scaduto(5000.0 + 600 + 61))

    def test_mai_vuol_dire_mai(self):
        server.S.attivo = 5000.0
        with self._con(0):
            self.assertFalse(server._scaduto(5000.0 + 10 ** 7))

    def test_un_valore_illeggibile_non_tiene_aperto(self):
        server.S.attivo = 5000.0
        with self._con("boh"):
            self.assertTrue(server._scaduto(5000.0 + 10 ** 7))

    def test_vault_chiuso_niente_da_bloccare(self):
        server.S.store = None
        server.S.attivo = 1.0
        with self._con(10):
            self.assertFalse(server._scaduto(10 ** 9))

    def test_vivo_a_vault_chiuso_non_riapre(self):
        server.S.store = None
        stato, _, _ = accesso.chiama("POST", "/api/vivo",
                                     {"X-VaultMind-Token": server.UI_TOKEN,
                                      "Content-Length": "0"})
        self.assertEqual(stato, 401)

    def test_l_estensione_non_puo_dire_vivo(self):
        self.assertNotIn("/api/vivo", server.EXT_ALLOWED)
        self.assertNotIn("/api/lock", server.EXT_ALLOWED)


class Estensione(unittest.TestCase):
    """Il registro delle estensioni, con le impostazioni in memoria."""

    def setUp(self):
        self.file = {"extensions": []}
        for nome, finto in (("_load_settings", lambda: dict(self.file)),
                            ("_save_settings", lambda s: self.file.update(s))):
            p = mock.patch.object(server, nome, finto)
            p.start()
            self.addCleanup(p.stop)

    def _abbina(self, **campi):
        e = {"name": "Chrome", "origin": "chrome-extension://abc",
             "token_hash": server._hash_token("tok"), "created": "01/11/2026 10:00"}
        e.update(campi)
        self.file["extensions"] = [e]

    def test_usata_di_recente_resta(self):
        self._abbina(last_used=time.time() - 3 * 86400)
        self.assertIsNotNone(server._ext_for_token("tok"))
        # e l'uso viene segnato
        self.assertGreater(self.file["extensions"][0]["last_used"], time.time() - 60)

    def test_ferma_da_troppo_perde_l_accesso(self):
        self._abbina(last_used=time.time() - (server.EXT_SCADENZA_GIORNI + 1) * 86400)
        self.assertIsNone(server._ext_for_token("tok"))
        self.assertEqual(self.file["extensions"], [], "tolta dal registro")
        self.assertIsNone(server._ext_for_token("tok"), "e non torna")

    def test_abbinata_prima_che_la_scadenza_esistesse_non_si_butta_fuori(self):
        # Chi l'ha abbinata mesi fa e la usa ogni giorno non ha `last_used`:
        # contare da `created` lo costringerebbe a riabbinarla all'aggiornamento.
        vecchia = time.strftime("%d/%m/%Y %H:%M", time.localtime(time.time() - 90 * 86400))
        for creata in (vecchia, "chissà"):
            self._abbina(created=creata)
            self.assertIsNotNone(server._ext_for_token("tok"), creata)
            # e da adesso si conta
            self.assertGreater(self.file["extensions"][0]["last_used"], time.time() - 60)

    def test_non_si_riscrive_a_ogni_richiesta(self):
        self._abbina(last_used=time.time() - 60)
        with mock.patch.object(server, "_save_settings") as salva:
            self.assertIsNotNone(server._ext_for_token("tok"))
            salva.assert_not_called()

    def test_token_sbagliato(self):
        self._abbina(last_used=time.time())
        self.assertIsNone(server._ext_for_token("altro"))
        self.assertIsNone(server._ext_for_token(""))


class Impostazioni(unittest.TestCase):

    def test_valori_assurdi(self):
        for k, v in (("autolock_minutes", -1), ("autolock_minutes", 10 ** 9),
                     ("gen_length", 0), ("gen_length", 100000),
                     ("theme", "x" * 41), ("sfondi", {"a": "b" * 81}),
                     ("sfondi", {str(n): "x" for n in range(51)}),
                     ("recenti", list(range(201)))):
            with self.subTest(k=k):
                self.assertIsInstance(server._impostazione_strana(k, v), str)

    def test_valori_normali(self):
        for k, v in (("autolock_minutes", 0), ("autolock_minutes", 10),
                     ("gen_length", 20), ("theme", "cristallo"), ("theme", ""),
                     ("sfondi", {"chat": "aurora"}), ("recenti", [1, 2, 3]),
                     ("use_ollama", False)):
            with self.subTest(k=k):
                self.assertIsNone(server._impostazione_strana(k, v))


class CorpoSenzaMisura(unittest.TestCase):

    def _post(self, **h):
        return accesso.chiama("POST", "/api/vivo",
                              {"X-VaultMind-Token": server.UI_TOKEN, **h})[0]

    def test_troppo_grande(self):
        self.assertEqual(self._post(**{"Content-Length": str(server.MAX_CORPO + 1)}), 413)
        self.assertEqual(self._post(**{"Content-Length": "tanto"}), 413)

    def test_a_pezzi_senza_lunghezza(self):
        self.assertEqual(self._post(**{"Transfer-Encoding": "chunked"}), 411)

    def test_il_rifiuto_arriva_prima_del_token(self):
        stato, _, _ = accesso.chiama("POST", "/api/vivo",
                                     {"Content-Length": str(10 ** 12)})
        self.assertEqual(stato, 413)


if __name__ == "__main__":
    unittest.main()
