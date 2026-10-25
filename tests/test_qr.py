r"""
Test sul QR che il PC mostra per collegare il telefono (`app/qr.py`).

Un QR non si giudica guardandolo: lo si fa **leggere** a un programma scritto
da altri. Qui e' `web/jsQR.js`, lo stesso lettore che l'app usa per il 2FA,
eseguito con Node da `qr/leggi_qr.js`. Senza Node i test si dichiarano
*saltati*, non passati: la sola prova che conta resta il telefono che lo
inquadra, e un test verde finto la nasconderebbe.

    tests\run.ps1
"""

from __future__ import annotations
import json
import os
import shutil
import subprocess
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import qr  # noqa: E402
from app import sync_protocol as sp  # noqa: E402

_NODE = shutil.which("node")


def _leggi(testi):
    matrici = [[[1 if x else 0 for x in riga] for riga in qr.matrice(t)] for t in testi]
    uscita = subprocess.run([_NODE, os.path.join(_QUI, "qr", "leggi_qr.js")],
                            input=json.dumps(matrici).encode(), capture_output=True,
                            timeout=120, check=True).stdout
    return json.loads(uscita.decode("utf-8"))


@unittest.skipUnless(_NODE, "serve Node per far leggere il QR a jsQR")
class TestQrLeggibile(unittest.TestCase):

    def test_il_qr_del_collegamento(self):
        uri = sp.uri_abbinamento("0123456789abcdef", "PC di casa — studio", sp.nuova_chiave())
        self.assertEqual([uri], _leggi([uri]))

    def test_nomi_con_accenti_e_lunghi(self):
        testi = [sp.uri_abbinamento(sp.id_dispositivo(), nome, sp.nuova_chiave())
                 for nome in ("", "PC", "Portatile di Lucà", "è" * 40, "🔐 Studio")]
        self.assertEqual(testi, _leggi(testi))

    def test_ogni_misura_fino_alla_versione_12(self):
        """Ogni misura cambia versione, blocchi e maschera scelta: un errore
        in uno solo di questi pezzi rende illeggibili solo certi testi."""
        testi = [("vaultmind-" * 40)[:n] for n in range(1, 360, 11)]
        versioni = {(len(qr.matrice(t)) - 17) // 4 for t in testi}
        self.assertTrue({1, 7, 12} <= versioni, f"versioni provate: {sorted(versioni)}")
        self.assertEqual(testi, _leggi(testi))


class TestQrForma(unittest.TestCase):

    def test_quadrato_e_della_misura_giusta(self):
        m = qr.matrice("A")
        self.assertEqual(21, len(m))
        self.assertTrue(all(len(r) == 21 for r in m))

    def test_troppo_lungo(self):
        with self.assertRaises(ValueError):
            qr.matrice("x" * 3000)

    def test_svg_nero_su_bianco(self):
        s = qr.svg("vaultmind://abbina")
        self.assertTrue(s.startswith("<svg"))
        self.assertIn('fill="#fff"', s)
        self.assertIn('fill="#000"', s)


if __name__ == "__main__":
    unittest.main(verbosity=2)
