r"""
L'import da CSV di altri password manager, uguale sul PC e sul telefono.

Il telefono ha lo stesso parser in Dart (`mobile/lib/import_csv.dart`) per chi
non ha un PC: un export di Chrome, Bitwarden o LastPass ce l'ha chiunque. Due
implementazioni dello stesso formato divergono in silenzio, e la divergenza
si vede solo quando un amico importa 300 voci e ne trova la meta' storte.

Per questo i casi stanno in `tests/vettore/import/`, uno per gestore, con dati
finti, e `atteso.json` e' quello che ne cava QUESTO modulo. Il test Dart
(`mobile/test/import_csv_test.dart`) legge gli stessi file e deve ottenere lo
stesso `atteso.json`, campo per campo.

Cambiato il parser di proposito? Si riscrive l'atteso e si guarda il diff:

    py -3 tests\test_import_csv.py --scrivi

I file sono `-text` (`.gitattributes` nella cartella): un CSV con un a capo
dentro le virgolette deve arrivare al test byte per byte, senza che git gli
cambi i fine riga.
"""

from __future__ import annotations
import json
import os
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_QUI)
sys.path.insert(0, os.path.join(_REPO, "VaultMind_Windows"))

from app.import_csv import parse_csv  # noqa: E402

_DIR = os.path.join(_QUI, "vettore", "import")
_ATTESO = os.path.join(_DIR, "atteso.json")


def _calcola() -> dict:
    out = {}
    for nome in sorted(os.listdir(_DIR)):
        if not nome.endswith(".csv"):
            continue
        # newline="" come fa il server, che riceve il testo cosi' com'e':
        # gli a capo dentro le virgolette restano quelli del file.
        with open(os.path.join(_DIR, nome), encoding="utf-8", newline="") as f:
            out[nome] = parse_csv(f.read())
    return out


class TestImportCsv(unittest.TestCase):
    def test_atteso_aggiornato(self):
        with open(_ATTESO, encoding="utf-8") as f:
            atteso = json.load(f)
        self.assertEqual(_calcola(), atteso,
                         "il parser e' cambiato: rigenera con --scrivi e "
                         "controlla il diff (lo usa anche il test Dart)")

    def test_otpauth_diventa_solo_il_secret(self):
        # Nel vault va solo il base32: e' quello che il calcolo del codice
        # si aspetta, sul PC come sul telefono.
        r = parse_csv("name,login_totp\nX,otpauth://totp/X?secret=ABC&issuer=X\n")
        self.assertEqual(r["entries"][0]["fields"],
                         [{"label": "OTP (2FA)", "value": "ABC"}])

    def test_colonne_di_servizio_ignorate(self):
        # Firefox e KeePassXC esportano date e guid: come campi della voce
        # sarebbero solo rumore.
        r = parse_csv('"url","username","password","guid","timeCreated"\n'
                      '"https://a.it","u","p","{1}","170"\n')
        etichette = [f["label"] for f in r["entries"][0]["fields"]]
        self.assertEqual(etichette, ["URL", "Utente", "Password"])

    def test_vuoto(self):
        self.assertEqual(parse_csv("")["entries"], [])
        self.assertEqual(parse_csv("﻿  \n")["entries"], [])


if __name__ == "__main__":
    if "--scrivi" in sys.argv:
        with open(_ATTESO, "w", encoding="utf-8", newline="\n") as f:
            json.dump(_calcola(), f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("scritto", _ATTESO)
    else:
        unittest.main()
