"""
Test su crypto_store.py — la rete di sicurezza sotto al modulo che cifra il vault.

Perché esistono: qui un bug non significa "l'interfaccia è brutta", significa
**tutte le password perse per sempre** oppure "il vault si apre a chi non deve".
Il sync multi-dispositivo e il vault di team riscriveranno proprio questo file:
questi test sono la garanzia che una riscrittura non rompa niente in silenzio.

Si usa `unittest` della libreria standard, NON pytest: installare un pacchetto
nel venv significa rischiare di ritrovarlo dentro l'exe (è già successo con
Pillow, +6 MB). Zero dipendenze nuove.

Esecuzione (da VaultMind_Windows/, con l'interprete del venv per path esplicito
perché `python` nel PATH è il finto alias del Microsoft Store):

    .\.venv\Scripts\python.exe -m unittest discover -s ..\tests -v

oppure, più corto:  tests\run.ps1

I parametri Argon2 sono quelli VERI (64 MB, time_cost 3): ogni derivazione
costa ~0,2 s. La suite intera resta sotto il minuto e prova la crittografia
di produzione, non una versione annacquata.
"""

from __future__ import annotations
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

# I test stanno fuori dal pacchetto consegnabile: si aggancia VaultMind_Windows
# al path, come farebbe l'app.
_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app.crypto_store import (  # noqa: E402
    Credential, Field, VaultStore, WrongPassword, VaultCorrupted,
    derive_key, _b64e, _b64d,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: E402

MASTER = "master-di-prova-1"
ALTRA = "master-di-prova-2"

VOCI = [
    {"title": "Banca Intesa", "fields": [{"label": "utente", "value": "lg88"},
                                         {"label": "password", "value": "b4nc4!segreta"}],
     "tags": ["banca"], "critical": True},
    {"title": "amazon.it", "fields": [{"label": "URL", "value": "https://www.amazon.it"},
                                      {"label": "password", "value": "amz-pw-01"}],
     "tags": ["shopping"], "critical": False},
    {"title": "Wifi ufficio", "fields": [{"label": "chiave", "value": "wifi-uff-2026"}],
     "tags": [], "critical": False},
]


class BaseVault(unittest.TestCase):
    """Ogni test lavora su una cartella temporanea sua: nessun test può toccare
    il vault vero (`~/.vaultmind`), che su questa macchina contiene credenziali
    di famiglia."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="vaultmind-test-")
        self.path = os.path.join(self.dir, "vault.json")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    # ---- aiutanti ----
    def vault_con_voci(self, master=MASTER, voci=None):
        s = VaultStore(self.path)
        s.create(master)
        s.add_many(voci if voci is not None else VOCI)
        return s

    def leggi_blob(self):
        with open(self.path, "r", encoding="utf-8") as f:
            return json.load(f)

    def byte_del_file(self):
        with open(self.path, "rb") as f:
            return f.read()

    def assertVociUguali(self, attese, ottenute, msg=""):
        """Confronto profondo: titolo, tag, critical, e i campi NELL'ORDINE
        scelto dall'utente (l'ordine è una funzione del prodotto, non un
        dettaglio: è quello con cui la voce viene mostrata)."""
        self.assertEqual(len(attese), len(ottenute), f"numero di voci diverso {msg}")
        for a, o in zip(attese, ottenute):
            self.assertEqual(a.title, o.title, msg)
            self.assertEqual(a.tags, o.tags, msg)
            self.assertEqual(a.critical, o.critical, msg)
            self.assertEqual([(f.label, f.value) for f in a.fields],
                             [(f.label, f.value) for f in o.fields], msg)


# ===========================================================================
class TestCreaESblocca(BaseVault):

    def test_create_produce_vault_vuoto_e_sbloccato(self):
        s = VaultStore(self.path)
        self.assertFalse(s.exists())
        s.create(MASTER)
        self.assertTrue(s.exists())
        self.assertTrue(s.unlocked)
        self.assertEqual([], s.entries, "un vault appena creato deve essere VUOTO")

    def test_round_trip_completo(self):
        """Il test più importante: quello che scrivo lo devo ritrovare identico."""
        s = self.vault_con_voci()
        attese = s.entries

        s2 = VaultStore(self.path)          # processo nuovo, nessuna memoria
        s2.unlock(MASTER)
        self.assertVociUguali(attese, s2.entries)

    def test_password_sbagliata_solleva_WrongPassword(self):
        self.vault_con_voci()
        s2 = VaultStore(self.path)
        with self.assertRaises(WrongPassword):
            s2.unlock(ALTRA)
        self.assertFalse(s2.unlocked, "dopo un tentativo fallito il vault non è aperto")

    def test_password_sbagliata_non_tocca_il_file(self):
        """Un tentativo fallito non deve danneggiare niente: il vault resta
        apribile con la password giusta, byte per byte com'era."""
        self.vault_con_voci()
        prima = self.byte_del_file()
        for tentativo in (ALTRA, "", "master-di-prova-1 ", "MASTER-DI-PROVA-1"):
            with self.assertRaises(WrongPassword):
                VaultStore(self.path).unlock(tentativo)
        self.assertEqual(prima, self.byte_del_file())
        s = VaultStore(self.path)
        s.unlock(MASTER)
        self.assertEqual(3, len(s.entries))

    def test_lock_dimentica_chiave_e_voci(self):
        s = self.vault_con_voci()
        s.lock()
        self.assertFalse(s.unlocked)
        self.assertEqual([], s.entries, "le voci non devono restare in RAM dopo lock()")
        # e il vault su disco è ancora integro
        s2 = VaultStore(self.path)
        s2.unlock(MASTER)
        self.assertEqual(3, len(s2.entries))

    def test_mutazioni_a_vault_bloccato_sono_rifiutate(self):
        s = self.vault_con_voci()
        s.lock()
        for azione in (
            lambda: s.add("x", [], []),
            lambda: s.add_many([{"title": "x"}]),
            lambda: s.delete(1),
            lambda: s.clear(),
            lambda: s.update(1, "x", [], []),
        ):
            with self.assertRaises(RuntimeError):
                azione()

    def test_password_unicode_e_valori_lunghi(self):
        """Accenti, emoji e valori lunghi: un vault che si crea ma non si
        riapre è la peggiore delle rotture possibili."""
        master = "pàsswörd-àccentata-🔐-lunga"
        valore = "x" * 5000
        s = VaultStore(self.path)
        s.create(master)
        s.add("Vocé con àccenti 🔑", [{"label": "nòta", "value": valore}], ["tàg"])
        s2 = VaultStore(self.path)
        s2.unlock(master)
        self.assertEqual("Vocé con àccenti 🔑", s2.entries[0].title)
        self.assertEqual(valore, s2.entries[0].fields[0].value)


# ===========================================================================
class TestCambioMaster(BaseVault):

    def test_cambio_master_conserva_le_voci(self):
        s = self.vault_con_voci()
        attese = s.entries
        s.change_master(MASTER, ALTRA)

        s2 = VaultStore(self.path)
        s2.unlock(ALTRA)
        self.assertVociUguali(attese, s2.entries, "(dopo change_master)")

    def test_dopo_il_cambio_la_vecchia_password_non_apre_piu(self):
        s = self.vault_con_voci()
        s.change_master(MASTER, ALTRA)
        with self.assertRaises(WrongPassword):
            VaultStore(self.path).unlock(MASTER)

    def test_cambio_master_rigenera_il_salt(self):
        """Salt nuovo = chiave nuova anche se un domani si riusasse la stessa
        password. Un salt riciclato renderebbe il cambio password apparente."""
        s = self.vault_con_voci()
        salt_prima = self.leggi_blob()["kdf"]["salt"]
        s.change_master(MASTER, ALTRA)
        self.assertNotEqual(salt_prima, self.leggi_blob()["kdf"]["salt"])

    def test_vecchia_password_errata_lascia_tutto_come_prima(self):
        """Se sbaglio la password attuale, il vault NON deve essere toccato:
        deve continuare ad aprirsi con quella originale."""
        s = self.vault_con_voci()
        prima = self.byte_del_file()
        with self.assertRaises(WrongPassword):
            s.change_master("non-e-questa", ALTRA)
        self.assertEqual(prima, self.byte_del_file(), "il file non va riscritto")
        s2 = VaultStore(self.path)
        s2.unlock(MASTER)
        self.assertEqual(3, len(s2.entries))

    def test_cambio_master_a_vault_bloccato(self):
        s = VaultStore(self.path)
        s.create(MASTER)
        s.lock()
        with self.assertRaises(WrongPassword):
            s.change_master(MASTER, ALTRA)

    def test_voci_aggiunte_dopo_il_cambio_sono_leggibili(self):
        """Le voci scritte con la chiave nuova devono convivere con quelle
        vecchie: è il caso reale di chi cambia password e continua a usare l'app."""
        s = self.vault_con_voci()
        s.change_master(MASTER, ALTRA)
        s.add("Aggiunta dopo", [{"label": "password", "value": "nuova-pw"}], ["x"])

        s2 = VaultStore(self.path)
        s2.unlock(ALTRA)
        self.assertEqual(4, len(s2.entries))
        self.assertEqual("Aggiunta dopo", s2.entries[0].title, "l'ultima aggiunta va in testa")
        self.assertEqual("nuova-pw", s2.entries[0].fields[0].value)
        # le tre di prima ci sono ancora tutte, coi loro valori leggibili
        vecchie = {c.title: c for c in s2.entries[1:]}
        self.assertEqual({"Banca Intesa", "amazon.it", "Wifi ufficio"}, set(vecchie))
        self.assertEqual("b4nc4!segreta", vecchie["Banca Intesa"].fields[1].value)
        self.assertTrue(vecchie["Banca Intesa"].critical)


# ===========================================================================
class TestAddEAddMany(BaseVault):

    def test_add_many_equivale_ad_add_in_sequenza(self):
        """add_many esiste solo per la velocità: il RISULTATO deve essere
        indistinguibile da add() chiamata in ciclo — stesso ordine, stessi id."""
        a = VaultStore(os.path.join(self.dir, "a.json"))
        a.create(MASTER)
        for v in VOCI:
            a.add(v["title"], v["fields"], v["tags"], v["critical"])

        b = VaultStore(os.path.join(self.dir, "b.json"))
        b.create(MASTER)
        b.add_many(VOCI)

        self.assertEqual([c.id for c in a.entries], [c.id for c in b.entries])
        self.assertVociUguali(a.entries, b.entries)

    def test_add_many_scrive_il_file_una_volta_sola(self):
        """La ragione d'essere di add_many: una sola riscrittura cifrata.
        Se qualcuno la reimplementasse con add() in ciclo, l'import di 800 voci
        tornerebbe a costare minuti — questo test lo impedisce."""
        s = VaultStore(self.path)
        s.create(MASTER)
        with mock.patch("app.crypto_store.os.replace", wraps=os.replace) as spia:
            s.add_many([{"title": f"voce {i}", "fields": [{"label": "p", "value": str(i)}]}
                        for i in range(50)])
        self.assertEqual(1, spia.call_count,
                         f"50 voci hanno prodotto {spia.call_count} scritture, attesa 1")

    def test_id_progressivi_e_unici(self):
        s = self.vault_con_voci()
        ids = [c.id for c in s.entries]
        self.assertEqual(len(ids), len(set(ids)), "id duplicati")
        s.add("Quarta", [{"label": "p", "value": "x"}], [])
        self.assertEqual(4, s.entries[0].id)

    def test_campi_del_tutto_vuoti_vengono_scartati(self):
        s = VaultStore(self.path)
        s.create(MASTER)
        c = s.add("Con vuoti", [
            {"label": "utente", "value": "mario"},
            {"label": "", "value": ""},          # da scartare
            {"label": "   ", "value": "  "},     # da scartare
            {"label": "URL", "value": ""},       # etichetta sola: si tiene
        ], [])
        self.assertEqual(["utente", "URL"], [f.label for f in c.fields])

    def test_delete_get_update(self):
        s = self.vault_con_voci()
        id_amazon = next(c.id for c in s.entries if c.title == "amazon.it")

        self.assertIsNotNone(s.get(id_amazon))
        s.update(id_amazon, "amazon.it (mio)", [{"label": "password", "value": "nuova"}],
                 ["shopping"], critical=True)
        s.delete(next(c.id for c in s.entries if c.title == "Wifi ufficio"))

        s2 = VaultStore(self.path)
        s2.unlock(MASTER)
        self.assertEqual(2, len(s2.entries))
        agg = s2.get(id_amazon)
        self.assertEqual("amazon.it (mio)", agg.title)
        self.assertTrue(agg.critical)
        self.assertEqual([("password", "nuova")], [(f.label, f.value) for f in agg.fields])
        self.assertIsNone(s2.get(999), "id inesistente deve dare None, non eccezione")

    def test_update_su_id_inesistente_ritorna_None(self):
        s = self.vault_con_voci()
        self.assertIsNone(s.update(999, "x", [], []))

    def test_clear_svuota_ma_il_vault_resta_apribile(self):
        s = self.vault_con_voci()
        s.clear()
        self.assertEqual([], s.entries)
        self.assertTrue(s.unlocked, "clear() non deve bloccare il vault")
        s2 = VaultStore(self.path)
        s2.unlock(MASTER)
        self.assertEqual([], s2.entries)


# ===========================================================================
class TestCompatibilita(BaseVault):
    """I vault creati con versioni precedenti devono continuare ad aprirsi.
    Chi ha 800 voci dentro non le reinserisce a mano perché abbiamo aggiunto
    un campo."""

    def _scrivi_vault_legacy(self, master, credentials):
        salt = os.urandom(16)
        key = derive_key(master, salt)
        nonce = os.urandom(12)
        payload = json.dumps({"credentials": credentials}).encode("utf-8")
        ct = AESGCM(key).encrypt(nonce, payload, b"vaultmind")
        blob = {"version": 1,
                "kdf": {"alg": "argon2id", "salt": _b64e(salt), "time_cost": 3,
                        "memory_cost": 64 * 1024, "parallelism": 2},
                "cipher": "aes-256-gcm", "nonce": _b64e(nonce), "ciphertext": _b64e(ct)}
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(blob, f)

    def test_vault_senza_campo_critical(self):
        """`critical` è stato aggiunto il 29/07: assente = non critica."""
        self._scrivi_vault_legacy(MASTER, [
            {"id": 1, "title": "Vecchia voce", "tags": ["x"],
             "fields": [{"label": "password", "value": "vecchia"}]},
        ])
        s = VaultStore(self.path)
        s.unlock(MASTER)
        self.assertEqual(1, len(s.entries))
        self.assertFalse(s.entries[0].critical)
        self.assertEqual("vecchia", s.entries[0].fields[0].value)

    def test_vault_senza_tag_ne_campi(self):
        self._scrivi_vault_legacy(MASTER, [{"id": 1, "title": "Minima"}])
        s = VaultStore(self.path)
        s.unlock(MASTER)
        self.assertEqual([], s.entries[0].tags)
        self.assertEqual([], s.entries[0].fields)

    def test_riscrittura_aggiunge_critical_senza_perdere_nulla(self):
        self._scrivi_vault_legacy(MASTER, [
            {"id": 1, "title": "Vecchia", "fields": [{"label": "p", "value": "v"}]},
        ])
        s = VaultStore(self.path)
        s.unlock(MASTER)
        s.add("Nuova", [{"label": "p", "value": "n"}], [])
        s2 = VaultStore(self.path)
        s2.unlock(MASTER)
        self.assertEqual(["Nuova", "Vecchia"], [c.title for c in s2.entries])
        self.assertFalse(s2.get(1).critical)


# ===========================================================================
class TestFileCorrotto(BaseVault):
    """Un file danneggiato deve dare un errore — mai un vault azzerato in
    silenzio, e mai un'apertura riuscita con dati sbagliati."""

    def test_ciphertext_manomesso_viene_rifiutato(self):
        """Integrità GCM: cambiare un byte del ciphertext deve far fallire
        l'apertura. Se passasse, qualcuno potrebbe alterare il vault."""
        self.vault_con_voci()
        blob = self.leggi_blob()
        ct = bytearray(_b64d(blob["ciphertext"]))
        ct[10] ^= 0x01                      # un solo bit
        blob["ciphertext"] = _b64e(bytes(ct))
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(blob, f)

        with self.assertRaises(WrongPassword):
            VaultStore(self.path).unlock(MASTER)

    def test_nonce_manomesso_viene_rifiutato(self):
        self.vault_con_voci()
        blob = self.leggi_blob()
        nonce = bytearray(_b64d(blob["nonce"]))
        nonce[0] ^= 0xFF
        blob["nonce"] = _b64e(bytes(nonce))
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(blob, f)
        with self.assertRaises(WrongPassword):
            VaultStore(self.path).unlock(MASTER)

    def test_salt_manomesso_viene_rifiutato(self):
        self.vault_con_voci()
        blob = self.leggi_blob()
        blob["kdf"]["salt"] = _b64e(os.urandom(16))
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(blob, f)
        with self.assertRaises(WrongPassword):
            VaultStore(self.path).unlock(MASTER)

    def test_file_troncato_da_errore_pulito_e_non_azzera_il_vault(self):
        """Il punto che conta: unlock() su un file rotto solleva VaultCorrupted
        — non un KeyError qualsiasi — e NON riscrive niente. La distinzione
        serve all'utente: con la password sbagliata si riprova, con un file
        danneggiato si ripristina un backup."""
        self.vault_con_voci()
        intero = self.byte_del_file()
        with open(self.path, "wb") as f:
            f.write(intero[: len(intero) // 2])
        troncato = self.byte_del_file()

        s = VaultStore(self.path)
        with self.assertRaises(VaultCorrupted):
            s.unlock(MASTER)
        self.assertFalse(s.unlocked)
        self.assertEqual(troncato, self.byte_del_file(),
                         "unlock() non deve MAI scrivere sul file")

    def test_file_vuoto_o_non_json(self):
        casi = [
            b"",                                  # file vuoto
            b"non sono json",                     # spazzatura
            b"{}",                                # JSON valido, vault no
            b'{"kdf": {}}',                       # struttura incompleta
            b'{"kdf": {"salt": "!!non-base64!!"}, "nonce": "x", "ciphertext": "y"}',
            b'{"kdf": {"salt": null}, "nonce": null, "ciphertext": null}',
        ]
        for contenuto in casi:
            with self.subTest(contenuto=contenuto[:30]):
                with open(self.path, "wb") as f:
                    f.write(contenuto)
                s = VaultStore(self.path)
                with self.assertRaises(VaultCorrupted):
                    s.unlock(MASTER)
                self.assertFalse(s.unlocked)

    def test_password_sbagliata_e_file_corrotto_sono_errori_DIVERSI(self):
        """Se fossero lo stesso errore, l'utente con un vault danneggiato
        continuerebbe a provare password all'infinito."""
        self.vault_con_voci()
        with self.assertRaises(WrongPassword):
            VaultStore(self.path).unlock(ALTRA)
        with open(self.path, "wb") as f:
            f.write(b"{}")
        with self.assertRaises(VaultCorrupted):
            VaultStore(self.path).unlock(MASTER)
        self.assertFalse(issubclass(VaultCorrupted, WrongPassword))
        self.assertFalse(issubclass(WrongPassword, VaultCorrupted))

    def test_change_master_su_file_corrotto_da_VaultCorrupted(self):
        s = self.vault_con_voci()
        with open(self.path, "wb") as f:
            f.write(b"rotto")
        with self.assertRaises(VaultCorrupted):
            s.change_master(MASTER, ALTRA)

    def test_una_sessione_aperta_non_perde_le_voci_se_il_file_si_rompe(self):
        """Se il file viene danneggiato mentre l'app è aperta, le voci in RAM
        ci sono ancora: l'utente può fare un backup e salvarsi."""
        s = self.vault_con_voci()
        with open(self.path, "wb") as f:
            f.write(b"rotto")
        self.assertEqual(3, len(s.entries))
        self.assertTrue(s.unlocked)


# ===========================================================================
class TestScritturaAtomica(BaseVault):

    def test_crash_durante_la_scrittura_lascia_il_vault_vecchio_leggibile(self):
        """La proprietà più importante di tutte: se il processo muore a metà
        scrittura, il vault PRECEDENTE deve restare intatto e apribile.
        La scrittura passa da file temporaneo + os.replace proprio per questo."""
        s = self.vault_con_voci()
        prima = self.byte_del_file()

        # il rename atomico non avviene: simula la morte del processo un istante
        # prima di sostituire il file
        with mock.patch("app.crypto_store.os.replace",
                        side_effect=OSError("morte simulata del processo")):
            with self.assertRaises(OSError):
                s.add("Voce che non arriverà", [{"label": "p", "value": "x"}], [])

        self.assertEqual(prima, self.byte_del_file(), "il vault vecchio è stato toccato")
        s2 = VaultStore(self.path)
        s2.unlock(MASTER)
        self.assertEqual(3, len(s2.entries), "le 3 voci originali si aprono ancora")

    def test_crash_durante_la_serializzazione(self):
        s = self.vault_con_voci()
        prima = self.byte_del_file()
        with mock.patch("app.crypto_store.json.dump",
                        side_effect=OSError("disco pieno")):
            with self.assertRaises(OSError):
                s.add("Mai salvata", [{"label": "p", "value": "x"}], [])
        self.assertEqual(prima, self.byte_del_file())

    def test_nessun_file_temporaneo_lasciato_in_giro(self):
        """I .tmp contengono il vault cifrato: lasciarli sparsi moltiplica le
        copie da cui recuperare dati."""
        s = self.vault_con_voci()
        for i in range(5):
            s.add(f"voce {i}", [{"label": "p", "value": str(i)}], [])
        # anche dopo un crash
        with mock.patch("app.crypto_store.os.replace", side_effect=OSError("crash")):
            with self.assertRaises(OSError):
                s.add("x", [], [])
        residui = [n for n in os.listdir(self.dir) if n.endswith(".tmp")]
        self.assertEqual([], residui, f"file temporanei rimasti: {residui}")


# ===========================================================================
class TestIgieneCrittografica(BaseVault):

    def test_il_file_non_contiene_password_in_chiaro(self):
        """Il controllo più elementare e più importante: cercare i segreti
        dentro il file cifrato non deve trovarli."""
        s = VaultStore(self.path)
        s.create(MASTER)
        s.add("Banca", [{"label": "password", "value": "SUPERSEGRETA-12345"}], ["banca"])
        grezzo = self.byte_del_file()
        for segreto in (b"SUPERSEGRETA-12345", MASTER.encode(), b"Banca", b"banca"):
            self.assertNotIn(segreto, grezzo,
                             f"{segreto!r} compare in chiaro nel file del vault")

    def test_la_master_password_non_finisce_nel_file(self):
        s = VaultStore(self.path)
        s.create(MASTER)
        blob = self.leggi_blob()
        self.assertEqual({"version", "kdf", "cipher", "nonce", "ciphertext"}, set(blob))
        self.assertNotIn("master", json.dumps(blob).lower())

    def test_il_nonce_cambia_a_ogni_scrittura(self):
        """Riusare un nonce con la stessa chiave in AES-GCM è catastrofico:
        rompe la riservatezza E l'autenticazione. Ogni flush deve estrarne uno
        nuovo."""
        s = VaultStore(self.path)
        s.create(MASTER)
        nonces = {self.leggi_blob()["nonce"]}
        for i in range(10):
            s.add(f"voce {i}", [{"label": "p", "value": str(i)}], [])
            nonces.add(self.leggi_blob()["nonce"])
        self.assertEqual(11, len(nonces), "nonce riutilizzato tra due scritture")

    def test_due_vault_con_la_stessa_password_hanno_chiavi_diverse(self):
        """Salt casuale per vault: due utenti con la stessa password non
        condividono la chiave, e un attacco precalcolato non è riutilizzabile."""
        a = VaultStore(os.path.join(self.dir, "a.json")); a.create(MASTER)
        b = VaultStore(os.path.join(self.dir, "b.json")); b.create(MASTER)
        with open(os.path.join(self.dir, "a.json"), encoding="utf-8") as f:
            salt_a = json.load(f)["kdf"]["salt"]
        with open(os.path.join(self.dir, "b.json"), encoding="utf-8") as f:
            salt_b = json.load(f)["kdf"]["salt"]
        self.assertNotEqual(salt_a, salt_b)

    def test_derive_key_e_deterministica_e_sensibile(self):
        salt = os.urandom(16)
        self.assertEqual(derive_key(MASTER, salt), derive_key(MASTER, salt))
        self.assertNotEqual(derive_key(MASTER, salt), derive_key(ALTRA, salt))
        self.assertNotEqual(derive_key(MASTER, salt), derive_key(MASTER, os.urandom(16)))
        self.assertEqual(32, len(derive_key(MASTER, salt)), "chiave a 256 bit")


# ===========================================================================
class TestVettoreDiProva(unittest.TestCase):
    """Il vault d'esempio in `vettore/` è il contratto del formato: ci si
    verifica l'implementazione dell'app Android.

    Questi test lo aprono a ogni esecuzione della suite. Se qualcuno cambia il
    formato del vault senza accorgersene, si rompono qui — cioè PRIMA che
    l'app mobile smetta di aprire i vault degli utenti.
    """

    @classmethod
    def setUpClass(cls):
        cls.dir = os.path.join(_QUI, "vettore")
        cls.vault = os.path.join(cls.dir, "vault-esempio.json")
        with open(os.path.join(cls.dir, "atteso.json"), encoding="utf-8") as f:
            cls.atteso = json.load(f)

    def test_il_vettore_si_apre_con_la_password_documentata(self):
        s = VaultStore(self.vault)
        s.unlock(self.atteso["master_password"])
        self.assertEqual(len(self.atteso["credentials"]), len(s.entries))

    def test_il_contenuto_combacia_esattamente(self):
        """Ordine delle voci, ordine dei campi, valori, tag, critical."""
        s = VaultStore(self.vault)
        s.unlock(self.atteso["master_password"])
        self.assertEqual(self.atteso["credentials"], [c.to_dict() for c in s.entries])

    def test_i_parametri_dichiarati_sono_quelli_veri(self):
        """`atteso.json` dice a chi implementa quali parametri usare: se il
        codice li cambiasse, il documento mentirebbe."""
        from app.crypto_store import ARGON2_TIME, ARGON2_MEMORY, ARGON2_PARALLELISM, KEY_LEN
        k = self.atteso["kdf"]
        self.assertEqual(ARGON2_TIME, k["time_cost"])
        self.assertEqual(ARGON2_MEMORY, k["memory_cost_kib"])
        self.assertEqual(ARGON2_PARALLELISM, k["parallelism"])
        self.assertEqual(KEY_LEN, k["key_len"])
        with open(self.vault, encoding="utf-8") as f:
            blob = json.load(f)
        self.assertEqual("aes-256-gcm", blob["cipher"])
        self.assertEqual(12, len(_b64d(blob["nonce"])), "nonce da 12 byte")
        self.assertEqual(16, len(_b64d(blob["kdf"]["salt"])), "salt da 16 byte")

    def test_il_codice_2FA_di_verifica(self):
        """Un errore nel base32 o nel contatore big-endian non si vede finché
        qualcuno non prova ad accedere a un servizio vero."""
        from app import totp
        v = self.atteso["totp_di_verifica"]
        self.assertEqual(v["codice_atteso"],
                         totp.generate(v["secret"], t=v["unix_time"])["code"])

    def test_la_password_sbagliata_fallisce_anche_sul_vettore(self):
        with self.assertRaises(WrongPassword):
            VaultStore(self.vault).unlock("non-e-questa")


if __name__ == "__main__":
    unittest.main(verbosity=2)
