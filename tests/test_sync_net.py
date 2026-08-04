r"""
Test sul trasporto del sync (`app/sync_net.py`).

Non sono finti: fanno partire un ascoltatore vero su 127.0.0.1 e ci collegano
un client vero. Quello che si verifica e' quello che succedera' fra il PC e il
telefono, meno il cavo.

I casi che contano sono quelli in cui il collegamento **deve fallire**: un
dispositivo mai abbinato, un codice sbagliato, un vault con un'altra master
password. Se uno solo di questi passasse, basterebbe stare sulla stessa WiFi
per farsi mandare il vault.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import sys
import threading
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import sync_net as rete  # noqa: E402
from app import sync_protocol as sp  # noqa: E402

CHIAVE = bytes(range(32))
ALTRA_CHIAVE = bytes(range(1, 33))


def contesto(nome, chiave=CHIAVE, fidati=None, codice=None, blob="il-mio-vault"):
    ricevuti = []
    ctx = rete.ContestoSync(
        id_dispositivo=sp.id_dispositivo(),
        nome=nome,
        chiave_vault=chiave,
        fidati=dict(fidati or {}),
        leggi_vault_cifrato=lambda: blob,
        ricevi_vault=lambda b, i: (ricevuti.append((b, i)), {"ricevuto": True})[1],
        salt_vault=b"\x01" * 16,
        codice_attivo=lambda: codice,
    )
    ctx.abbina = lambda id_peer, n: ctx.fidati.__setitem__(id_peer, {"nome": n})
    return ctx, ricevuti


class BaseRete(unittest.TestCase):
    def avvia(self, ctx):
        a = rete.Ascoltatore(ctx, porta=0)
        a.start()
        self.assertTrue(a.pronto.wait(5), "l'ascoltatore non si e' aperto")
        self.addCleanup(a.ferma)
        return a


class TestStrettaDiMano(BaseRete):

    def test_abbinamento_col_codice_giusto_e_scambio(self):
        """Il giro completo: due dispositivi che non si conoscono, il codice
        letto sull'altro schermo, e i due vault che si incrociano."""
        srv, ricevuti_srv = contesto("PC", codice="123456", blob="vault-del-pc")
        cli, ricevuti_cli = contesto("Telefono", blob="vault-del-telefono")
        a = self.avvia(srv)

        esito = rete.sincronizza(cli, "127.0.0.1", a.porta_vera, codice="123456")

        self.assertTrue(esito["ok"])
        self.assertEqual("PC", esito["con"])
        self.assertEqual([("vault-del-pc", srv.id_dispositivo)], ricevuti_cli)
        # il server riceve nel suo thread: si aspetta che finisca
        for _ in range(50):
            if ricevuti_srv:
                break
            threading.Event().wait(0.05)
        self.assertEqual([("vault-del-telefono", cli.id_dispositivo)], ricevuti_srv)
        # e da adesso si conoscono, senza codice
        self.assertIn(cli.id_dispositivo, srv.fidati)

    def test_il_codice_sbagliato_non_passa(self):
        srv, _ = contesto("PC", codice="123456")
        cli, _ = contesto("Telefono")
        a = self.avvia(srv)
        with self.assertRaises(rete.RifiutoSync) as e:
            rete.sincronizza(cli, "127.0.0.1", a.porta_vera, codice="000000")
        self.assertIn("odice", str(e.exception))
        self.assertEqual({}, srv.fidati)

    def test_un_dispositivo_mai_abbinato_viene_respinto(self):
        """Senza codice attivo, chi non e' nell'elenco non entra — anche se
        conosce la master password. E' il senso stesso dell'elenco."""
        srv, _ = contesto("PC", codice=None)
        cli, _ = contesto("Telefono")
        a = self.avvia(srv)
        with self.assertRaises(rete.RifiutoSync):
            rete.sincronizza(cli, "127.0.0.1", a.porta_vera)

    def test_un_dispositivo_gia_abbinato_non_richiede_il_codice(self):
        cli, _ = contesto("Telefono")
        srv, _ = contesto("PC", fidati={cli.id_dispositivo: {"nome": "Telefono"}})
        a = self.avvia(srv)
        esito = rete.sincronizza(cli, "127.0.0.1", a.porta_vera)
        self.assertTrue(esito["ok"])

    def test_una_master_password_diversa_viene_detta_chiaramente(self):
        """Non e' un errore di rete e riprovare non serve: il messaggio deve
        dire cosa fare davvero, cioe' rimandare il vault."""
        cli, _ = contesto("Telefono", chiave=ALTRA_CHIAVE)
        srv, _ = contesto("PC", fidati={cli.id_dispositivo: {"nome": "Telefono"}})
        a = self.avvia(srv)
        with self.assertRaises(rete.RifiutoSync) as e:
            rete.sincronizza(cli, "127.0.0.1", a.porta_vera)
        self.assertIn("chiave", str(e.exception).lower())

    def test_chi_non_ha_la_chiave_non_ottiene_il_vault(self):
        """La prova che conta: uno sulla stessa WiFi, con l'elenco a suo
        favore, ma senza la chiave del vault. Non deve ricevere niente."""
        cli, ricevuti = contesto("Intruso", chiave=ALTRA_CHIAVE)
        srv, _ = contesto("PC", fidati={cli.id_dispositivo: {"nome": "Intruso"}},
                          blob="SEGRETO")
        a = self.avvia(srv)
        with self.assertRaises(rete.RifiutoSync):
            rete.sincronizza(cli, "127.0.0.1", a.porta_vera)
        self.assertEqual([], ricevuti)

    def test_una_versione_diversa_si_ferma_subito(self):
        """Meglio un rifiuto netto che due app che si capiscono a meta'."""
        import socket
        srv, _ = contesto("PC", codice="123456")
        a = self.avvia(srv)
        s = socket.create_connection(("127.0.0.1", a.porta_vera), timeout=5)
        self.addCleanup(s.close)
        s.sendall(json.dumps({"vm": 99, "tipo": "ciao", "id": "x",
                              "sfida": "00" * 16}).encode() + b"\n")
        r = json.loads(s.recv(4096).decode().splitlines()[0])
        self.assertEqual("no", r["tipo"])
        self.assertEqual("versione diversa", r["perche"])

    def test_spazzatura_non_fa_cadere_l_ascoltatore(self):
        import socket
        srv, _ = contesto("PC", codice="123456")
        a = self.avvia(srv)
        s = socket.create_connection(("127.0.0.1", a.porta_vera), timeout=5)
        s.sendall(b"non sono json\n")
        s.close()
        # e subito dopo un collegamento buono deve funzionare lo stesso
        cli, _ = contesto("Telefono")
        self.assertTrue(rete.sincronizza(cli, "127.0.0.1", a.porta_vera,
                                         codice="123456")["ok"])


class TestScoperta(unittest.TestCase):
    """La decisione di rispondere o no, senza tirare in ballo la rete: e' la
    parte che riguarda la privacy, e va provata in modo deterministico."""

    def sonda(self, chiave, nonce_hex="aa" * 16, firmata=True):
        d = {"vm": rete.VERSIONE, "tipo": "sonda", "n": nonce_hex}
        if firmata:
            d["f"] = rete._firma_sonda(chiave, nonce_hex)
        return json.dumps(d).encode("utf-8")

    def test_risponde_a_chi_ha_lo_stesso_vault(self):
        ctx, _ = contesto("PC")
        r = rete.Annunciatore(ctx)._rispondi(self.sonda(CHIAVE))
        self.assertIsNotNone(r)
        self.assertEqual(ctx.id_dispositivo, r["id"])
        self.assertEqual("PC", r["nome"])
        # e firma a sua volta, perche' nessuno possa fingersi un nostro dispositivo
        self.assertEqual(rete._firma_eccomi(CHIAVE, "aa" * 16, ctx.id_dispositivo), r["f"])

    def test_non_risponde_a_un_estraneo(self):
        """Per chi sta sulla stessa WiFi ma non ha il vault, qui non c'e'
        niente: nessuna risposta, nessun nome, nessuna traccia."""
        ctx, _ = contesto("PC")
        self.assertIsNone(rete.Annunciatore(ctx)._rispondi(self.sonda(ALTRA_CHIAVE)))
        self.assertIsNone(rete.Annunciatore(ctx)._rispondi(
            self.sonda(CHIAVE, firmata=False)))

    def test_durante_l_abbinamento_risponde_anche_a_chi_non_firma(self):
        """Finestra voluta di 120 secondi: il dispositivo nuovo il vault non
        ce l'ha, quindi non puo' firmare. Riceve il salt, che non e' segreto."""
        ctx, _ = contesto("PC", codice="123456")
        r = rete.Annunciatore(ctx)._rispondi(self.sonda(CHIAVE, firmata=False))
        self.assertIsNotNone(r)
        self.assertTrue(r["abbinabile"])
        self.assertEqual((b"\x01" * 16).hex(), r["salt"])

    def test_finito_l_abbinamento_torna_invisibile(self):
        ctx, _ = contesto("PC", codice=None)
        self.assertIsNone(rete.Annunciatore(ctx)._rispondi(
            self.sonda(CHIAVE, firmata=False)))

    def test_il_salt_non_esce_fuori_dall_abbinamento(self):
        ctx, _ = contesto("PC")
        r = rete.Annunciatore(ctx)._rispondi(self.sonda(CHIAVE))
        self.assertNotIn("salt", r)

    def test_messaggi_malformati_non_ottengono_risposta(self):
        ctx, _ = contesto("PC", codice="123456")
        ann = rete.Annunciatore(ctx)
        for cattivo in [b"", b"{", b"[]", b'{"tipo":"altro"}',
                        json.dumps({"vm": 99, "tipo": "sonda", "n": "aa"}).encode(),
                        json.dumps({"vm": 1, "tipo": "sonda", "n": "zz"}).encode()]:
            self.assertIsNone(ann._rispondi(cattivo), cattivo)


if __name__ == "__main__":
    unittest.main(verbosity=2)
