r"""
Test sulla fusione fra PC e telefono (`app/merge.py`): vince l'ultima modifica.

Il grosso sta in `vettore/fusione.json`, un elenco di casi ognuno col suo
*perche'*: leggerlo e' il modo piu' veloce di capire cosa resta nelle due app
dopo un sync. Qui restano le proprieta' che valgono per tutti i casi (nessuna
voce viva e sepolta insieme, id unici) e quelle che un vettore non mostra: che
la fusione non tocchi cio' che riceve, e che `uguali` guardi il contenuto.

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
from app.merge import Istantanea, contenuto, fondi, uguali  # noqa: E402


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


def esegui(caso: dict):
    return fondi(istantanea(caso["pc"]), istantanea(caso["tel"]),
                 caso.get("base_categorie"), primo=bool(caso.get("primo")))


class TestVettoreFusione(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(_QUI, "vettore", "fusione.json"), encoding="utf-8") as f:
            cls.casi = json.load(f)["casi"]

    def test_ogni_caso_del_vettore(self):
        self.assertGreater(len(self.casi), 15, "il vettore si e' svuotato")
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                self._verifica(caso, esegui(caso))

    def _verifica(self, caso, f):
        atteso = caso["atteso"]
        if "titoli" in atteso:
            self.assertEqual(atteso["titoli"], sorted(c.title for c in f.entries), "voci vive")
        if "lapidi" in atteso:
            self.assertEqual(atteso["lapidi"], sorted(t["uid"] for t in f.tombstones), "lapidi")
        if "categorie" in atteso:
            self.assertEqual(atteso["categorie"], f.categories, "categorie")
        for lato in ("sul_pc", "sul_telefono"):
            if lato in atteso:
                self.assertEqual(atteso[lato], getattr(f, lato), lato)
        per_uid = {c.uid: c for c in f.entries}
        for att in atteso.get("voci", []):
            ott = per_uid.get(att["uid"])
            self.assertIsNotNone(ott, f'voce «{att["uid"]}» mancante')
            for chiave, valore in att.items():
                if chiave == "fields":
                    self.assertEqual(valore, [[x.label, x.value] for x in ott.fields],
                                     f'campi di «{att["uid"]}»')
                elif chiave != "uid":
                    self.assertEqual(valore, getattr(ott, chiave), f'{chiave} di «{att["uid"]}»')

    def test_nessuna_voce_e_viva_e_sepolta_insieme(self):
        """Il vault direbbe due cose opposte, e il sync dopo impazzirebbe."""
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                f = esegui(caso)
                self.assertEqual(set(), {c.uid for c in f.entries} & {t["uid"] for t in f.tombstones})

    def test_gli_id_e_gli_uid_restano_unici(self):
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                f = esegui(caso)
                self.assertEqual(len(f.entries), len({c.id for c in f.entries}), "id doppi")
                self.assertEqual(len(f.entries), len({c.uid for c in f.entries}), "uid doppi")

    def test_rifondere_il_risultato_non_cambia_niente(self):
        """Dopo un sync le due parti hanno la stessa cosa: il giro seguente
        non deve trovare niente da fare, o il sync ripartirebbe all'infinito."""
        for caso in self.casi:
            with self.subTest(caso["nome"]):
                f = esegui(caso)
                fatto = Istantanea(f.entries, f.tombstones, f.categories)
                g = fondi(fatto, fatto, f.categories)
                self.assertTrue(uguali(fatto, Istantanea(g.entries, g.tombstones, g.categories)))
                zero = {"aggiunte": 0, "aggiornate": 0, "cancellate": 0}
                self.assertEqual((zero, zero), (g.sul_pc, g.sul_telefono))


class TestFusionePura(unittest.TestCase):
    """La fusione non deve toccare niente di quello che riceve: il PC la
    calcola prima di sapere se potrà scriverla (il vault può cambiare nel
    frattempo, e allora si butta)."""

    def test_gli_ingressi_non_vengono_modificati(self):
        pc = Istantanea([voce({"id": 1, "title": "Banca"}),
                         voce({"id": 2, "title": "Vecchia"})])
        tel = Istantanea([voce({"id": 2, "title": "Nuova", "uid": "u-nuova", "mod": 5})])
        prima = [(c.uid, c.id, c.title, c.rev) for c in pc.entries + tel.entries]
        fondi(pc, tel, primo=True)
        self.assertEqual(prima, [(c.uid, c.id, c.title, c.rev) for c in pc.entries + tel.entries])

    def test_due_vault_vuoti(self):
        f = fondi(Istantanea([]), Istantanea([]))
        self.assertEqual(([], [], []), (f.entries, f.tombstones, f.categories))


class TestUguali(unittest.TestCase):

    def test_id_e_ordine_non_contano(self):
        a = Istantanea([voce({"id": 1, "title": "A", "uid": "u1"}),
                        voce({"id": 2, "title": "B", "uid": "u2"})])
        b = Istantanea([voce({"id": 7, "title": "B", "uid": "u2"}),
                        voce({"id": 3, "title": "A", "uid": "u1"})])
        self.assertTrue(uguali(a, b))

    def test_una_password_cambiata_si_vede(self):
        """Se il confronto non guardasse i valori, il PC direbbe «uguale» e il
        telefono resterebbe con la password vecchia."""
        a = voce({"id": 1, "title": "Banca", "fields": [["password", "vecchia"]]})
        b = voce({"id": 1, "title": "Banca", "fields": [["password", "nuova"]]})
        self.assertNotEqual(contenuto(a), contenuto(b))
        self.assertFalse(uguali(Istantanea([a]), Istantanea([b])))

    def test_lapidi_e_categorie_contano(self):
        a = Istantanea([], [{"uid": "u1", "rev": 2, "mod": 1}], ["Casa"])
        self.assertFalse(uguali(a, Istantanea([], [], ["Casa"])))
        self.assertFalse(uguali(a, Istantanea([], [{"uid": "u1", "rev": 2, "mod": 1}], [])))


if __name__ == "__main__":
    unittest.main(verbosity=2)
