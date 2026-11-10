r"""
Chi può farsi dare la pagina col token, e chi può parlare con le API.

Nasce dal pentest del 10/11/2026 (punto A1): fino alla 7.2 una GET a "/" da
qualunque programma restituiva il token, e a vault aperto tutte le voci.
Qui si prova il server vero (`app.server.app`), chiamato come lo chiamerebbe
uvicorn ma senza rete: niente porte aperte, e niente `httpx` (che finirebbe
nell'exe).

    tests\run.ps1
"""

from __future__ import annotations
import asyncio
import os
import re
import shutil
import sys
import tempfile
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

server = None
_CARTELLA = None


def setUpModule():
    """Il server si importa QUI e non in cima al file.

    Legge il percorso del vault una volta sola, all'import: senza
    `VAULTMIND_FILE` punterebbe a ~/.vaultmind, cioè al vault vero. E
    `test_aggiornamenti` fa lo stesso gioco con una cartella sua, saltando i
    suoi test se trova il modulo già importato: `unittest discover` importa
    tutti i file prima di eseguirne uno, quindi un import in cima a questo
    file glieli faceva saltare tutti.

    Se il server è già stato importato da lui va bene lo stesso: questi test
    non scrivono niente, basta che non guardi il vault vero.
    """
    global server, _CARTELLA
    if "app.server" not in sys.modules:
        _CARTELLA = tempfile.mkdtemp(prefix="vm-accesso-")
        os.environ["VAULTMIND_FILE"] = os.path.join(_CARTELLA, "vault.json")
    from app import server as s
    vero = os.path.join(os.path.expanduser("~"), ".vaultmind")
    if os.path.abspath(s.DEFAULT_VAULT).startswith(os.path.abspath(vero)):
        raise unittest.SkipTest(f"il server guarda il vault vero: {s.DEFAULT_VAULT}")
    server = s


def tearDownModule():
    if _CARTELLA:
        os.environ.pop("VAULTMIND_FILE", None)
        shutil.rmtree(_CARTELLA, ignore_errors=True)


def chiama(metodo: str, percorso: str, intestazioni: dict | None = None,
           host: str = "127.0.0.1:8731"):
    """Una richiesta al server, senza rete. Torna (stato, intestazioni, corpo)."""
    path, _, query = percorso.partition("?")
    h = {"host": host, **{k.lower(): v for k, v in (intestazioni or {}).items()}}
    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": metodo, "scheme": "http", "path": path,
        "raw_path": path.encode(), "query_string": query.encode(),
        "root_path": "", "server": ("127.0.0.1", 8731),
        "client": ("127.0.0.1", 50000),
        "headers": [(k.encode(), v.encode("latin-1")) for k, v in h.items()],
    }
    fuori = {"stato": 0, "intestazioni": {}, "corpo": b""}

    chieste = []

    async def ricevi():
        # La richiesta una volta sola; dopo, chi chiede ancora (FileResponse
        # lo fa, per sapere se il client se n'è andato) aspetta e basta:
        # rispondere «disconnesso» gli fa troncare il file.
        chieste.append(1)
        if len(chieste) == 1:
            return {"type": "http.request", "body": b"", "more_body": False}
        await asyncio.Event().wait()     # un client che resta collegato

    async def manda(m):
        if m["type"] == "http.response.start":
            fuori["stato"] = m["status"]
            fuori["intestazioni"] = {k.decode().lower(): v.decode("latin-1")
                                     for k, v in m["headers"]}
        elif m["type"] == "http.response.body":
            fuori["corpo"] += m.get("body", b"")

    asyncio.run(server.app(scope, ricevi, manda))
    return fuori["stato"], fuori["intestazioni"], fuori["corpo"].decode("utf-8")


def cookie_di(intestazioni: dict) -> str:
    """`nome=valore` dalla Set-Cookie, da rimandare nell'header Cookie."""
    return intestazioni["set-cookie"].split(";", 1)[0]


class PaginaColToken(unittest.TestCase):

    def test_senza_niente_non_si_riceve_il_token(self):
        stato, _, corpo = chiama("GET", "/")
        self.assertEqual(stato, 403)
        self.assertNotIn(server.UI_TOKEN, corpo)

    def test_segreto_inventato_non_apre(self):
        stato, _, corpo = chiama("GET", "/?avvio=indovinato")
        self.assertEqual(stato, 403)
        self.assertNotIn(server.UI_TOKEN, corpo)

    def test_il_segreto_di_avvio_apre_una_volta_sola(self):
        s = server.nuovo_avvio()
        stato, h, corpo = chiama("GET", f"/?avvio={s}")
        self.assertEqual(stato, 200)
        self.assertIn(server.UI_TOKEN, corpo)
        self.assertIn("httponly", h["set-cookie"].lower())
        self.assertIn("samesite=strict", h["set-cookie"].lower())
        # Chi lo ha visto passare (un'altra finestra, la cronologia) non lo
        # può riusare.
        stato, _, corpo = chiama("GET", f"/?avvio={s}")
        self.assertEqual(stato, 403)
        self.assertNotIn(server.UI_TOKEN, corpo)

    def test_segreto_scaduto_non_apre(self):
        s = server.nuovo_avvio(validita=-1)
        stato, _, corpo = chiama("GET", f"/?avvio={s}")
        self.assertEqual(stato, 403)
        self.assertNotIn(server.UI_TOKEN, corpo)

    def test_il_cookie_permette_di_ricaricare(self):
        # `location.reload()` al blocco: il segreto è speso, resta il cookie.
        _, h, _ = chiama("GET", f"/?avvio={server.nuovo_avvio()}")
        stato, h2, corpo = chiama("GET", "/", {"Cookie": cookie_di(h)})
        self.assertEqual(stato, 200)
        self.assertIn(server.UI_TOKEN, corpo)
        self.assertNotIn("set-cookie", h2)

    def test_cookie_sbagliato_non_apre(self):
        for valore in ("x", "", "\xe9\xe8"):
            stato, _, corpo = chiama(
                "GET", "/", {"Cookie": f"{server.COOKIE_SESSIONE}={valore}"})
            self.assertEqual(stato, 403, valore)
            self.assertNotIn(server.UI_TOKEN, corpo)

    def test_il_cookie_da_solo_non_apre_le_api(self):
        _, h, _ = chiama("GET", f"/?avvio={server.nuovo_avvio()}")
        stato, _, _ = chiama("GET", "/api/status", {"Cookie": cookie_di(h)})
        self.assertEqual(stato, 401)

    def test_la_copia_statica_della_pagina_non_ha_il_token(self):
        stato, _, corpo = chiama("GET", "/static/index.html")
        self.assertEqual(stato, 200)
        self.assertNotIn(server.UI_TOKEN, corpo)
        self.assertIn("__VM_TOKEN__", corpo)


class Intestazioni(unittest.TestCase):

    def test_la_pagina_non_si_incornicia_e_non_resta_in_cache(self):
        _, h, corpo = chiama("GET", f"/?avvio={server.nuovo_avvio()}")
        self.assertEqual(h["x-frame-options"], "DENY")
        self.assertEqual(h["x-content-type-options"], "nosniff")
        self.assertEqual(h["cache-control"], "no-store")
        self.assertIn("frame-ancestors 'none'", h["content-security-policy"])
        # Il nonce della CSP è quello dell'unico script in linea: se non
        # tornano, la pagina si apre bianca.
        nonce = re.search(r"'nonce-([^']+)'", h["content-security-policy"]).group(1)
        self.assertEqual(re.findall(r'<script nonce="([^"]+)">', corpo), [nonce])
        self.assertNotIn("<script>", corpo)

    def test_la_pagina_chiusa_non_esegue_script(self):
        _, h, _ = chiama("GET", "/")
        self.assertIn("script-src 'none'", h["content-security-policy"])
        self.assertEqual(h["x-frame-options"], "DENY")


class Api(unittest.TestCase):

    def test_la_documentazione_automatica_non_esiste(self):
        for p in ("/docs", "/redoc", "/openapi.json"):
            self.assertEqual(chiama("GET", p)[0], 404, p)

    def test_token(self):
        self.assertEqual(chiama("GET", "/api/status")[0], 401)
        self.assertEqual(chiama("GET", "/api/status", {"X-VaultMind-Token": "x"})[0], 401)
        # Era un 500: `compare_digest` sulle stringhe non accetta gli accenti.
        self.assertEqual(
            chiama("GET", "/api/status", {"X-VaultMind-Token": "\xe9\xe8"})[0], 401)
        self.assertEqual(
            chiama("GET", "/api/status", {"X-VaultMind-Token": server.UI_TOKEN})[0], 200)

    def test_host_estraneo(self):
        for host in ("evil.com", "localhost.evil.com", "127.0.0.1.evil.com:8731"):
            stato, _, _ = chiama("GET", f"/?avvio={server.nuovo_avvio()}", host=host)
            self.assertEqual(stato, 403, host)


if __name__ == "__main__":
    unittest.main()
