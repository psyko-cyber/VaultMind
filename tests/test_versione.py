r"""
Un numero di versione, tre file che lo dichiarano.

PC, telefono e release escono insieme e dallo stesso numero: `app/__init__.py`
e' l'originale, `mobile/pubspec.yaml` (dove serve anche ad Android come
`versionName`) e `mobile/lib/versione.dart` (dove l'app lo mostra e lo
confronta col tag su GitHub) devono dire la stessa cosa.

Non e' pignoleria: da quando le app controllano gli aggiornamenti, un numero
sbagliato in uno di questi file significa un dispositivo che non si aggiorna
mai, oppure che propone per sempre di installare la versione che ha gia'.
Fino al 25/10/2026 `__init__.py` diceva "0.1.0" mentre l'installer diceva 6.8,
e non succedeva niente: nessuno leggeva quel numero.

Lo stesso controllo lo rifa' `installer\rilascio.ps1` prima di pubblicare, che
e' l'ultimo momento utile; questo test e' il primo.

    tests\run.ps1
"""

from __future__ import annotations
import os
import re
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_QUI)
sys.path.insert(0, os.path.join(_REPO, "VaultMind_Windows"))

from app import __version__  # noqa: E402


def _pezzi(v: str) -> tuple:
    """"6.9" e "6.9.0" sono la stessa versione: tre pezzi per parte."""
    numeri = [int(p) for p in v.split(".") if p.isdigit()]
    return tuple((numeri + [0, 0, 0])[:3])


class TestVersioneUnica(unittest.TestCase):
    def _leggi(self, percorso: str, espressione: str) -> str:
        with open(os.path.join(_REPO, percorso), encoding="utf-8") as f:
            m = re.search(espressione, f.read(), re.M)
        self.assertIsNotNone(m, f"versione non trovata in {percorso}")
        return m.group(1)

    def test_pubspec_dice_lo_stesso_numero(self):
        pubspec = self._leggi("mobile/pubspec.yaml", r"^version:\s*([0-9.]+)\+")
        self.assertEqual(_pezzi(pubspec), _pezzi(__version__),
                         f"pubspec.yaml dice {pubspec}, app/__init__.py {__version__}")

    def test_il_versioncode_di_android_cresce(self):
        # Android rifiuta un APK con versionCode minore o uguale a quello
        # installato: l'aggiornamento dentro l'app si fermerebbe davanti a un
        # errore di sistema, dopo aver scaricato tutto.
        codice = int(self._leggi("mobile/pubspec.yaml", r"^version:\s*[0-9.]+\+(\d+)"))
        maggiore, minore, _ = _pezzi(__version__)
        self.assertGreaterEqual(codice, maggiore * 10 + minore,
                                "il numero dopo il + non segue la versione")

    def test_dart_dice_lo_stesso_numero(self):
        dart = self._leggi("mobile/lib/versione.dart", r"versioneApp\s*=\s*'([^']+)'")
        self.assertEqual(dart, __version__)

    def test_l_installer_non_scrive_un_numero_suo(self):
        # La versione la passa rilascio.ps1 (/DMyAppVersion): se qualcuno
        # rimettesse un #define qui, tornerebbero due numeri che divergono.
        with open(os.path.join(_REPO, "installer", "VaultMind.iss"),
                  encoding="utf-8", errors="replace") as f:
            iss = f.read()
        self.assertNotRegex(iss, r'(?m)^#define\s+MyAppVersion\s+"')
        self.assertIn("#ifndef MyAppVersion", iss)


if __name__ == "__main__":
    unittest.main()
