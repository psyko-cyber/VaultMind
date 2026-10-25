r"""
Test su search.py, per la parte che il database mostra accanto a una voce:
le «vicine nel vault».

Si usa il vettorizzatore a n-grammi (`_HashingNgram`), non il modello vero:
e' deterministico, non scarica niente, e la geometria che si prova (coseno
fra vettori normalizzati, la voce stessa esclusa) e' la stessa.
"""

from __future__ import annotations
import os
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app.crypto_store import Credential, Field  # noqa: E402
from app.embedding import _HashingNgram  # noqa: E402
from app.search import SearchIndex  # noqa: E402


def _voce(i, titolo, *tag):
    return Credential(id=i, title=titolo, tags=list(tag),
                      fields=[Field("utente", f"utente{i}"),
                              Field("password", "non-entra-nell-indice")])


class TestVicine(unittest.TestCase):
    def setUp(self):
        self.indice = SearchIndex(_HashingNgram())
        self.indice.build([
            _voce(1, "Banca Intesa", "banca", "conto"),
            _voce(2, "Banca Sella", "banca", "conto"),
            _voce(3, "Netflix", "streaming"),
            _voce(4, "Disney Plus", "streaming"),
            _voce(5, "Wifi di casa", "rete"),
        ])

    def test_la_piu_vicina_e_quella_che_somiglia(self):
        vicine = self.indice.vicine(1)
        self.assertEqual(vicine[0].cred.id, 2)

    def test_la_voce_non_e_vicina_a_se_stessa(self):
        for i in range(1, 6):
            self.assertNotIn(i, [r.cred.id for r in self.indice.vicine(i, k=10)])

    def test_al_massimo_k_e_in_ordine(self):
        vicine = self.indice.vicine(3, k=3)
        self.assertEqual(len(vicine), 3)
        punteggi = [r.score for r in vicine]
        self.assertEqual(punteggi, sorted(punteggi, reverse=True))
        self.assertTrue(all(-1.0001 <= p <= 1.0001 for p in punteggi))

    def test_voce_sconosciuta_o_indice_vuoto(self):
        self.assertEqual(self.indice.vicine(99), [])
        vuoto = SearchIndex(_HashingNgram())
        vuoto.build([])
        self.assertEqual(vuoto.vicine(1), [])


if __name__ == "__main__":
    unittest.main()
