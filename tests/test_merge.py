r"""
Test sul motore di fusione (`app/merge.py`), il cuore del sync.

Il grosso non sta qui dentro: sta in `vettore/fusione.json`, un elenco di casi
che **anche la suite Dart esegue**. Le due implementazioni del merge devono
dare lo stesso risultato sugli stessi ingressi, altrimenti il PC e il telefono
si allineerebbero su idee diverse di cosa e' successo — e nessuno se ne
accorgerebbe finche' non manca una password.

Qui restano le verifiche che hanno senso solo in Python: che la fusione sia
davvero una funzione pura, e i casi limite del contorno.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app.crypto_store import Credential, Field  # noqa: E402
from app.merge import (  # noqa: E402
    Istantanea, fondi, impronta, base_da,
    ENTRAMBI_MODIFICATA, MODIFICATA_QUI_CANCELLATA_LA, CANCELLATA_QUI_MODIFICATA_LA,
)

_MOTIVI = {ENTRAMBI_MODIFICATA, MODIFICATA_QUI_CANCELLATA_LA, CANCELLATA_QUI_MODIFICATA_LA}


def voce(d: dict) -> Credential:
    """Una voce dalla forma compatta del vettore: id e title bastano."""
    return Credential(
        id=d["id"],
        title=d.get("title", ""),
        tags=list(d.get("tags", [])),
        critical=bool(d.get("critical", False)),
        category=d.get("category", ""),
        uid=d.get("uid", ""),
        rev=int(d.get("rev", 1)),
        mod=int(d.get("mod", 0)),
        fields=[Field(f[0], f[1]) for f in d.get("fields", [])],
    )


def istantanea(d: dict) -> Istantanea:
    return Istantanea(
        entries=[voce(v) for v in d.get("voci", [])],
        tombstones=[dict(t) for t in d.get("lapidi", [])],
        categories=list(d.get("categorie", [])),
    )


class TestVettoreFusione(unittest.TestCase):
    """Esegue i casi condivisi con la suite Dart."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(_QUI, "vettore", "fusione.json"), encoding="utf-8") as f:
            cls.casi = json.load(f)["casi"]

    def test_ogni_caso_del_vettore(self):
        self.assertGreater(len(self.casi), 10, "il vettore si e' svuotato")
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                self._verifica(caso)

    def _verifica(self, caso):
        f = fondi(istantanea(caso["mio"]), istantanea(caso["suo"]), caso.get("base"))
        atteso = caso["atteso"]

        # --- voci, confrontate per uid (l'ordine della lista non fa parte del contratto)
        ottenute = sorted(f.entries, key=lambda c: c.uid)
        attese = sorted(atteso.get("voci", []), key=lambda v: v["uid"])
        self.assertEqual([v["uid"] for v in attese], [c.uid for c in ottenute],
                         "voci sopravvissute alla fusione")
        for att, ott in zip(attese, ottenute):
            for chiave in ("title", "rev", "id", "category"):
                if chiave in att:
                    self.assertEqual(att[chiave], getattr(ott, chiave),
                                     f'{chiave} di «{att["uid"]}»')

        # --- lapidi
        if "lapidi" in atteso:
            self.assertEqual(sorted(atteso["lapidi"]),
                             sorted(t["uid"] for t in f.tombstones), "lapidi")
        for uid, rev in (atteso.get("revLapidi") or {}).items():
            trovata = next((t for t in f.tombstones if t["uid"] == uid), None)
            self.assertIsNotNone(trovata, f"lapide «{uid}» mancante")
            self.assertEqual(rev, trovata["rev"], f"rev della lapide «{uid}»")

        if "categorie" in atteso:
            self.assertEqual(atteso["categorie"], f.categories)

        # --- conflitti
        self.assertEqual(
            sorted((c["uid"], c["motivo"]) for c in atteso.get("conflitti", [])),
            sorted((c.uid, c.motivo) for c in f.conflitti),
            "conflitti")

    def test_nessuna_voce_e_viva_e_sepolta_insieme(self):
        """Una voce non puo' risultare contemporaneamente presente e cancellata:
        il vault direbbe due cose opposte, e il sync successivo impazzirebbe."""
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                f = fondi(istantanea(caso["mio"]), istantanea(caso["suo"]), caso.get("base"))
                vive = {c.uid for c in f.entries}
                sepolte = {t["uid"] for t in f.tombstones}
                self.assertEqual(set(), vive & sepolte)

    def test_gli_id_restano_unici(self):
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                f = fondi(istantanea(caso["mio"]), istantanea(caso["suo"]), caso.get("base"))
                ids = [c.id for c in f.entries]
                self.assertEqual(len(ids), len(set(ids)), "id duplicati dopo la fusione")

    def test_i_motivi_dei_conflitti_sono_quelli_dichiarati(self):
        for caso in self.casi:
            f = fondi(istantanea(caso["mio"]), istantanea(caso["suo"]), caso.get("base"))
            for c in f.conflitti:
                self.assertIn(c.motivo, _MOTIVI)


class TestFusionePura(unittest.TestCase):
    """La fusione non deve toccare NIENTE di quello che riceve: chi la chiama
    la usa per far vedere all'utente cosa succederebbe, e deve poter decidere
    di non applicarla."""

    def _due(self):
        mia = Istantanea(entries=[voce({"id": 1, "title": "Banca"}),
                                  voce({"id": 2, "title": "Dal PC", "uid": "aaa111"})])
        sua = Istantanea(entries=[voce({"id": 1, "title": "Banca"}),
                                  voce({"id": 2, "title": "Dal telefono", "uid": "bbb222"})])
        return mia, sua

    def test_gli_ingressi_non_vengono_modificati(self):
        mia, sua = self._due()
        prima = [(c.uid, c.id, c.title, c.rev) for c in mia.entries + sua.entries]
        fondi(mia, sua, None)
        dopo = [(c.uid, c.id, c.title, c.rev) for c in mia.entries + sua.entries]
        self.assertEqual(prima, dopo, "la fusione ha modificato i vault ricevuti")

    def test_fondere_due_volte_da_lo_stesso_risultato(self):
        mia, sua = self._due()
        a = fondi(mia, sua, None)
        b = fondi(mia, sua, None)
        self.assertEqual([c.uid for c in a.entries], [c.uid for c in b.entries])
        self.assertEqual(len(a.conflitti), len(b.conflitti))

    def test_fondere_con_se_stessi_non_cambia_niente(self):
        mia, _ = self._due()
        f = fondi(mia, mia, base_da(mia.entries))
        self.assertEqual([c.uid for c in mia.entries], [c.uid for c in f.entries])
        self.assertEqual([], f.conflitti)
        self.assertFalse(f.qualcosa_da_fare)

    def test_l_impronta_ignora_le_coordinate_e_non_il_contenuto(self):
        a = voce({"id": 1, "title": "Banca", "rev": 1})
        b = voce({"id": 9, "title": "Banca", "rev": 7, "uid": "diverso"})
        self.assertEqual(impronta(a), impronta(b), "id, rev e uid non sono contenuto")
        c = voce({"id": 1, "title": "Banca", "fields": [["password", "x"]]})
        self.assertNotEqual(impronta(a), impronta(c), "un campo in piu' e' contenuto")

    def test_una_password_cambiata_non_passa_inosservata(self):
        """Il caso che conta piu' di tutti: se l'impronta non guardasse i
        VALORI, due password diverse sembrerebbero la stessa voce e una delle
        due sparirebbe senza che nessuno chieda niente."""
        a = voce({"id": 1, "title": "Banca", "fields": [["password", "vecchia"]]})
        b = voce({"id": 1, "title": "Banca", "fields": [["password", "nuova"]]})
        self.assertNotEqual(impronta(a), impronta(b))

        f = fondi(Istantanea(entries=[a]), Istantanea(entries=[b]), None)
        self.assertEqual(1, len(f.conflitti))
        self.assertEqual(ENTRAMBI_MODIFICATA, f.conflitti[0].motivo)

    def test_la_base_si_costruisce_dalle_voci(self):
        mia, _ = self._due()
        self.assertEqual({"#1": 1, "aaa111": 1}, base_da(mia.entries))

    def test_due_vault_vuoti(self):
        f = fondi(Istantanea(), Istantanea(), None)
        self.assertEqual([], f.entries)
        self.assertEqual([], f.conflitti)
        self.assertFalse(f.qualcosa_da_fare)

    def test_il_titolo_del_conflitto_c_e_anche_se_una_parte_manca(self):
        """Serve a scrivere «Eliminare "Banca"?» anche quando la voce, da un
        lato, non esiste piu'."""
        viva = voce({"id": 1, "title": "Banca", "rev": 3})
        f = fondi(Istantanea(entries=[viva]),
                  Istantanea(tombstones=[{"uid": "#1", "rev": 2, "mod": 1}]),
                  {"#1": 1})
        self.assertEqual(1, len(f.conflitti))
        self.assertEqual("Banca", f.conflitti[0].titolo)
        self.assertIsNone(f.conflitti[0].sua)


if __name__ == "__main__":
    unittest.main(verbosity=2)
