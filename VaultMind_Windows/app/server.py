"""
server.py — App web locale (FastAPI), in ascolto SOLO su 127.0.0.1.

La sessione (chiave derivata + indice) vive in RAM nel processo, per la durata
dell'esecuzione. Nessun endpoint è esposto sulla rete: il bind è loopback.
"""

from __future__ import annotations
import contextlib
import os
import sys
import json
import secrets
import hashlib
import threading
import time
from pathlib import Path
from typing import List, Optional, Any

from fastapi import FastAPI, HTTPException, UploadFile, File, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .crypto_store import (VaultStore, WrongPassword, VaultCorrupted,
                           copia_di_sicurezza, elenco_copie, cartella_copie,
                           sostituisci_vault)
from .embedding import Embeddings
from .search import SearchIndex, interpret
from .import_parse import heuristic_extract
from .import_csv import parse_csv
from .sync_app import SyncApp
from .sync_net import RifiutoSync
from . import sync_net
from . import __version__
from . import aggiornamenti
from . import llm
from . import master as regole_master
from . import totp
from . import transcribe

WEB_DIR = Path(__file__).parent / "web"
DEFAULT_VAULT = os.environ.get("VAULTMIND_FILE", str(Path.home() / ".vaultmind" / "vault.json"))

@contextlib.asynccontextmanager
async def _vita(_app):
    _stampa_avvio()
    yield


# Niente /docs, /redoc, /openapi.json: rispondevano senza token, elencavano
# ogni endpoint, e /docs carica script da un CDN — una connessione in uscita
# che l'app promette di non fare.
app = FastAPI(title="VaultMind (local)", lifespan=_vita,
              docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")

# ---- stato di processo (singolo utente locale) ----
class Session:
    def __init__(self):
        self.store: Optional[VaultStore] = None
        self.index: Optional[SearchIndex] = None
        self.embeddings: Optional[Embeddings] = None
        self.index_dirty: bool = False   # indice da riallineare prima della prossima ricerca
        # L'ultima volta che l'utente ha toccato la pagina (vedi `_guardiano`).
        self.attivo: float = 0.0

S = Session()


# ---------------- modelli richiesta ----------------
class UnlockIn(BaseModel):
    master: str

class QueryIn(BaseModel):
    text: str

class FieldIn(BaseModel):
    label: str
    value: str

class AddIn(BaseModel):
    title: str
    fields: List[FieldIn] = []
    tags: str = ""
    critical: bool = False
    category: str = ""

class UpdateIn(BaseModel):
    id: int
    title: str
    fields: List[FieldIn] = []
    tags: str = ""
    critical: bool = False
    category: str = ""

class ImportParseIn(BaseModel):
    text: str

class ImportCsvIn(BaseModel):
    content: str

class ImportEntry(BaseModel):
    title: str = ""
    fields: List[FieldIn] = []
    tags: List[str] = []

class ImportCommitIn(BaseModel):
    entries: List[ImportEntry]
    # False = blocco intermedio di un import grande: salva ma non ricostruire
    # l'indice (lo si fa una volta sola, sull'ultimo blocco).
    rebuild: bool = True

class RestoreIn(BaseModel):
    content: str  # contenuto del file di backup (JSON cifrato)

class TotpIn(BaseModel):
    cred_id: int


# ---------------- helper ----------------
def _ensure_embeddings() -> Embeddings:
    if S.embeddings is None:
        S.embeddings = Embeddings()
    return S.embeddings

def _rebuild_index():
    assert S.store is not None
    emb = _ensure_embeddings()
    S.index = SearchIndex(emb)
    S.index.build(S.store.entries)
    S.index_dirty = False

def _require_unlocked():
    if S.store is None or not S.store.unlocked or S.index is None:
        raise HTTPException(status_code=401, detail="Vault bloccato.")

def _require_index():
    """Riallinea l'indice se un import a blocchi lo ha invalidato.
    Ricostruirlo a ogni blocco costerebbe quanto l'import stesso: si paga
    una volta sola, e solo se serve davvero (cioè prima di una ricerca)."""
    if S.index_dirty:
        _rebuild_index()


# ---------------- endpoints ----------------
# ---- chi riceve la pagina col token ----
# La pagina porta dentro UI_TOKEN, cioè l'accesso pieno alle API. La
# same-origin policy impedisce a un SITO di leggerla, ma non a un PROGRAMMA:
# fino alla 7.2 bastava una GET a "/" — da qualunque processo, anche di un
# altro utente Windows sullo stesso PC, perché il loopback è della macchina e
# non della sessione — per avere il token e, a vault aperto, tutte le voci
# (pentest del 10/11/2026, punto A1).
#
# Adesso la pagina col token la riceve solo:
#   - chi presenta un **segreto d'avvio**: monouso, a scadenza, mai scritto su
#     disco. Lo fabbrica `nuovo_avvio()`, che può chiamare solo chi sta in
#     questo processo: il launcher, che ci apre la finestra;
#   - chi ha il **cookie** che quella prima risposta consegna. Serve perché la
#     pagina si ricarica da sola (`location.reload()` al blocco), e a quel
#     punto il segreto è già speso.
# Chiunque altro riceve una pagina che spiega da dove si apre VaultMind.
#
# Le API non cambiano: vogliono l'header col token, e il token ora non si può
# più chiedere. Il cookie da solo non apre niente.
#
# Limite: un programma che gira come lo stesso utente può ancora leggere la
# memoria di questo processo. Qui si chiude la strada che non richiedeva
# nessuna capacità, e quella dell'altro utente.
COOKIE_SESSIONE = "vm_sessione"
_SESSIONE = secrets.token_urlsafe(32)
VALIDITA_AVVIO_S = 120
_avvii: dict = {}                    # segreto -> scadenza (time.time())
_avvii_lucchetto = threading.Lock()


def nuovo_avvio(validita: float = VALIDITA_AVVIO_S) -> str:
    """Un segreto d'avvio nuovo, da mettere in `/?avvio=<segreto>`. Vale una
    volta sola e per poco: quanto basta alla finestra per caricarsi."""
    s = secrets.token_urlsafe(32)
    with _avvii_lucchetto:
        adesso = time.time()
        for vecchio in [k for k, scade in _avvii.items() if scade < adesso]:
            del _avvii[vecchio]
        _avvii[s] = adesso + validita
    return s


def _uguali(a: str, b: str) -> bool:
    """Confronto a tempo costante fra due stringhe arrivate da fuori.
    `compare_digest` sulle `str` solleva se trova un carattere non ASCII, e un
    header può contenerne: sui byte non succede (era un 500 invece di un 401)."""
    return secrets.compare_digest(a.encode("utf-8", "surrogatepass"),
                                  b.encode("utf-8", "surrogatepass"))


def _spendi_avvio(s: str) -> bool:
    with _avvii_lucchetto:
        adesso = time.time()
        for k in list(_avvii):
            if _uguali(k, s):
                return _avvii.pop(k) >= adesso   # speso anche se scaduto
    return False


def _stampa_avvio() -> None:
    """Chi lancia il server a mano (`python -m uvicorn app.server:app`, per
    provare senza build) non ha un launcher che gli apra la finestra: gli si
    scrive l'indirizzo nel terminale. Mai nell'exe: lì l'uscita è il file di
    log, e un segreto in un file è proprio quello che si vuole evitare."""
    if getattr(sys, "frozen", False):
        return
    try:
        print(f"VaultMind: apri la pagina con  /?avvio={nuovo_avvio(600)}  "
              "(vale una volta, per 10 minuti)", flush=True)
    except Exception:
        pass


_PAGINA_CHIUSA = """<!doctype html><html lang="it"><meta charset="utf-8">
<title>VaultMind</title>
<body style="font-family:system-ui,sans-serif;background:#0A0E1A;color:#C9D1E8;
display:grid;place-items:center;height:100vh;margin:0">
<div style="max-width:420px;padding:24px;text-align:center;line-height:1.6">
<h1 style="font-size:20px;color:#fff">VaultMind si apre dalla sua finestra</h1>
<p>Questa pagina non si può aprire da un browser o da un altro programma.
Usa l'icona di VaultMind: se l'app è già aperta, torna alla sua finestra.</p>
</div></body></html>"""


def _csp(nonce: str = "") -> str:
    """Nessun XSS trovato, ma se un giorno un titolo finisse in `innerHTML`
    questa riga è ciò che impedirebbe allo script di partire. Gli stili in
    linea restano ammessi: la pagina ne è piena e non eseguono niente."""
    script = f"'self' 'nonce-{nonce}'" if nonce else "'none'"
    return ("default-src 'self'; "
            f"script-src {script}; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob:; font-src 'self' data:; "
            "media-src 'self' blob:; connect-src 'self'; "
            "object-src 'none'; base-uri 'none'; form-action 'self'; "
            "frame-ancestors 'none'")


@app.get("/", response_class=HTMLResponse)
def home(request: Request, avvio: str = ""):
    primo = bool(avvio) and _spendi_avvio(avvio)
    if not primo and not _uguali(request.cookies.get(COOKIE_SESSIONE, ""), _SESSIONE):
        return HTMLResponse(_PAGINA_CHIUSA, status_code=403,
                            headers={"Content-Security-Policy": _csp()})
    nonce = secrets.token_urlsafe(16)
    html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    html = html.replace("__VM_TOKEN__", UI_TOKEN)
    # Lo script in linea è uno solo: è l'unico che la CSP lascia partire.
    html = html.replace("<script>", f'<script nonce="{nonce}">', 1)
    risposta = HTMLResponse(html, headers={"Content-Security-Policy": _csp(nonce)})
    if primo:
        # HttpOnly: uno script non lo legge. SameSite=Strict: un sito non lo
        # fa partire. Senza scadenza: muore con la finestra.
        risposta.set_cookie(COOKIE_SESSIONE, _SESSIONE, httponly=True,
                            samesite="strict", path="/")
    return risposta


@app.get("/api/status")
def status():
    return {
        "exists": VaultStore(DEFAULT_VAULT).exists(),
        "unlocked": bool(S.store and S.store.unlocked),
        "file": DEFAULT_VAULT,
        "audio_ready": transcribe.available(),
        "llm": llm.available(),
    }


# ---------------- impostazioni (preferenze non sensibili) ----------------
SETTINGS_PATH = os.path.join(os.path.dirname(DEFAULT_VAULT), "settings.json")
_DEFAULT_SETTINGS = {
    "autolock_minutes": 10,      # 0 = disattivato
    "use_ollama": True,          # se False, mind usa solo i template
    "mic_enabled": True,         # input vocale
    "gen_length": 20,            # default generatore password
    "gen_symbols": True,
    # Vuoto e non "dark": prima di ogni salvataggio il default finiva nel file
    # come se fosse una scelta, e dal 7.1 la pagina si fida di quello che
    # trova qui (vedi `PREF_SERVER` in index.html).
    "theme": "",
    # L'unica connessione in uscita dell'app. Acceso: una GET anonima a GitHub
    # ogni 12 ore per sapere se c'è una versione nuova. Spento: nessuna.
    "aggiornamenti": True,
}

#: Chi legge, cambia e riscrive le impostazioni lo fa tenendo questo: da
#: quando anche una richiesta dell'estensione le scrive (l'ultimo uso), due
#: scritture insieme si mangerebbero l'una l'altra.
_impostazioni = threading.RLock()

def _load_settings() -> dict:
    s = dict(_DEFAULT_SETTINGS)
    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
            s.update(json.load(f))
    except Exception:
        pass
    return s

def _save_settings(s: dict) -> None:
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
        json.dump(s, f, indent=2)


# ---------------- sicurezza: chi può parlare con questo server ----------------
# Il bind su 127.0.0.1 tiene fuori la RETE, non il BROWSER: qualsiasi pagina
# web aperta può INVIARE richieste al loopback anche senza poterne leggere le
# risposte — e un POST cieco su /api/clear o /api/delete farebbe danni con il
# vault sbloccato. Tre serrature, tutte necessarie:
#   1. header X-VaultMind-Token su ogni /api/*. La UI lo riceve dentro l'HTML
#      servito da "/" (che nessun altro sito può leggere, e che dal 10/11/2026
#      nessun altro programma può chiedere: vedi `home()`); un sito terzo non
#      può nemmeno inviare un header custom senza un preflight CORS, che qui
#      viene rifiutato.
#   2. controllo dell'header Host: chiude il DNS rebinding (attacker.com che
#      risolve a 127.0.0.1 arriva col Host sbagliato).
#   3. le estensioni browser abbinate hanno un token SEPARATO, legato alla
#      loro origine e limitato a EXT_ALLOWED: dal browser solo lettura, mai
#      scrittura sul vault.
UI_TOKEN = secrets.token_urlsafe(32)

# endpoint concessi a un token di estensione (sola lettura + stato)
EXT_ALLOWED = {"/api/status", "/api/query", "/api/reveal", "/api/totp", "/api/list"}

_EXT_SCHEMES = ("chrome-extension://", "moz-extension://")

#: Il corpo più grande che ha senso: un backup da ripristinare o un audio da
#: trascrivere. Lo stesso tetto di un messaggio del sync.
MAX_CORPO = 64 * 1024 * 1024

# codice di abbinamento in corso: solo in RAM, mai su disco
_pairing: dict = {}


def _hash_token(tok: str) -> str:
    return hashlib.sha256(tok.encode("utf-8")).hexdigest()

def _ext_registry() -> list:
    return list(_load_settings().get("extensions", []))

#: Un'estensione che non legge niente per così tanti giorni perde l'accesso
#: e va abbinata di nuovo (trenta secondi, col codice). Il suo token vale
#: tutto il vault in lettura e sta nel profilo del browser: quello di un
#: browser che non si usa più — un profilo vecchio, un PC passato a un altro —
#: non deve restare buono per sempre (pentest del 10/11/2026, M6).
EXT_SCADENZA_GIORNI = 30
#: L'ultimo uso si scrive su disco al massimo una volta ogni tanto: basta per
#: dire «usata oggi», e non riscrive il file a ogni richiesta.
_EXT_SEGNA_OGNI_S = 3600


def _ext_ultimo_uso(e: dict) -> float:
    """Quando l'estensione ha letto l'ultima volta; 0 se non si sa.

    Quelle abbinate prima che la scadenza esistesse non hanno `last_used`, e
    NON si conta da `created`: chi l'ha abbinata due mesi fa e la usa ogni
    giorno verrebbe buttato fuori al primo uso dopo l'aggiornamento. Per
    loro il conto parte dalla prima lettura che si vede."""
    try:
        return float(e["last_used"])
    except Exception:
        return 0.0


def _ext_for_token(tok: str):
    """L'estensione abbinata per questo token, o None. Su disco sta solo
    l'hash: chi legge settings.json non ricava il token.

    Chi non si fa vivo da `EXT_SCADENZA_GIORNI` viene tolto qui, al primo
    tentativo: da quel momento il suo token non è più niente."""
    if not tok:
        return None
    h = _hash_token(tok)
    for e in _ext_registry():
        if not _uguali(h, str(e.get("token_hash", ""))):
            continue
        ora = time.time()
        ultimo = _ext_ultimo_uso(e)
        if ultimo and ora - ultimo < _EXT_SEGNA_OGNI_S:
            return e
        with _impostazioni:
            s = _load_settings()
            resto = [x for x in s.get("extensions", []) if x.get("token_hash") != e.get("token_hash")]
            # `ultimo == 0`: abbinata prima che la scadenza esistesse. Non è
            # un motivo per buttarla fuori: da adesso si conta.
            scaduta = bool(ultimo) and ora - ultimo > EXT_SCADENZA_GIORNI * 86400
            if not scaduta:
                e = dict(e, last_used=ora)
                resto.append(e)
            s["extensions"] = resto
            try:
                _save_settings(s)
            except OSError:
                pass   # disco pieno o file bloccato: non è colpa di chi legge
        return None if scaduta else e
    return None

def _origin_paired(origin: str) -> bool:
    return any(e.get("origin") == origin for e in _ext_registry())

def _cors_headers(origin: str) -> dict:
    """Solo per l'estensione abbinata (Chrome bypassa CORS con host_permissions,
    Firefox no: rispondere non costa nulla e tiene aperta quella strada)."""
    return {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Headers": "Content-Type, X-VaultMind-Token",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Vary": "Origin",
    }


@app.middleware("http")
async def _guardia(request: Request, call_next):
    # serratura 2: solo loopback esplicito, chiunque altro non esiste
    host = (request.headers.get("host") or "").rsplit(":", 1)[0].strip("[]").lower()
    if host not in ("127.0.0.1", "localhost", "::1"):
        return JSONResponse({"detail": "Host non consentito."}, status_code=403)

    # Un corpo senza misura il server lo leggerebbe tutto in memoria prima di
    # guardare chi lo manda (pentest del 10/11/2026, B8). La pagina e
    # l'estensione dichiarano sempre la lunghezza: chi non lo fa non è loro.
    if request.method in ("POST", "PUT", "PATCH"):
        lunga = request.headers.get("content-length")
        if lunga is None:
            if "chunked" in (request.headers.get("transfer-encoding") or "").lower():
                return JSONResponse({"detail": "Serve Content-Length."}, status_code=411)
        elif not lunga.isdigit() or int(lunga) > MAX_CORPO:
            return JSONResponse({"detail": "Richiesta troppo grande."}, status_code=413)

    path = request.url.path
    if not path.startswith("/api/"):
        # "/" e /static: è la pagina stessa. Chi riceve quella col token lo
        # decide `home()`; qui solo le intestazioni che valgono per tutte.
        resp = await call_next(request)
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["X-Frame-Options"] = "DENY"       # nessun sito la incornicia
        resp.headers["Referrer-Policy"] = "no-referrer"
        if path == "/":
            # La pagina contiene il token: non deve restare in nessuna cache.
            resp.headers["Cache-Control"] = "no-store"
        return resp

    origin = request.headers.get("origin", "")

    # preflight CORS: risposta utile solo all'estensione abbinata (o in
    # abbinamento, per il solo claim); per ogni altra origine è un rifiuto
    if request.method == "OPTIONS":
        if _origin_paired(origin) or (path == "/api/pair/claim" and origin.startswith(_EXT_SCHEMES)):
            return PlainTextResponse("", headers=_cors_headers(origin))
        return PlainTextResponse("Origine non autorizzata.", status_code=403)

    # unico endpoint senza token: protetto dal codice mostrato nell'app,
    # dal limite di tentativi e dal requisito di origine estensione
    if path == "/api/pair/claim":
        resp = await call_next(request)
        if origin.startswith(_EXT_SCHEMES):
            for k, v in _cors_headers(origin).items():
                resp.headers[k] = v
        return resp

    tok = request.headers.get("x-vaultmind-token", "")
    if _uguali(tok, UI_TOKEN):
        return await call_next(request)   # la UI dell'app: accesso pieno

    ext = _ext_for_token(tok)
    if ext is not None:
        # serratura 3: il token vale solo dall'origine con cui fu abbinato...
        if origin and origin != ext.get("origin"):
            return JSONResponse({"detail": "Origine diversa da quella abbinata."}, status_code=403)
        # ...e solo in lettura
        if path not in EXT_ALLOWED:
            return JSONResponse({"detail": "L'estensione ha accesso in sola lettura."}, status_code=403)
        resp = await call_next(request)
        if origin:
            for k, v in _cors_headers(origin).items():
                resp.headers[k] = v
        return resp

    return JSONResponse({"detail": "Richiesta non autorizzata."}, status_code=401)


# ---------------- abbinamento estensione browser ----------------
@app.post("/api/pair/start")
def pair_start():
    """Genera il codice di abbinamento e lo consegna alla UI: il codice si
    legge NELL'APP, quindi autorizza chi controlla l'app — una pagina web non
    può né vederlo né spendere i 5 tentativi senza un'origine da estensione."""
    _require_unlocked()
    code = "".join(secrets.choice("0123456789") for _ in range(6))
    _pairing.clear()
    _pairing.update({"code": code, "expires": time.time() + 120, "attempts": 0})
    return {"code": code, "expires_in": 120}


class PairClaimIn(BaseModel):
    code: str
    name: str = "Estensione browser"

@app.post("/api/pair/claim")
def pair_claim(body: PairClaimIn, request: Request):
    origin = request.headers.get("origin", "")
    if not origin.startswith(_EXT_SCHEMES):
        raise HTTPException(status_code=403, detail="L'abbinamento è riservato alle estensioni browser.")
    if not _pairing or time.time() > _pairing.get("expires", 0):
        _pairing.clear()
        raise HTTPException(status_code=400, detail="Nessun codice attivo. In VaultMind: Impostazioni → Estensione browser → Associa.")
    _pairing["attempts"] = _pairing.get("attempts", 0) + 1
    if _pairing["attempts"] > 5:
        _pairing.clear()
        raise HTTPException(status_code=429, detail="Troppi tentativi: genera un nuovo codice nell'app.")
    if not _uguali(body.code.strip(), _pairing["code"]):
        raise HTTPException(status_code=403, detail="Codice errato.")
    _pairing.clear()
    token = secrets.token_urlsafe(32)
    with _impostazioni:
        s = _load_settings()
        # ri-abbinare la stessa estensione sostituisce il token vecchio
        exts = [e for e in s.get("extensions", []) if e.get("origin") != origin]
        exts.append({
            "name": (body.name.strip() or "Estensione browser")[:60],
            "origin": origin,
            "token_hash": _hash_token(token),
            "created": time.strftime("%d/%m/%Y %H:%M"),
            "last_used": time.time(),
        })
        s["extensions"] = exts
        _save_settings(s)
    return {"ok": True, "token": token}


def _cartella_estensione() -> Optional[str]:
    """Dove sta la cartella da dare a "Carica estensione non pacchettizzata".

    L'installer la mette accanto all'eseguibile; in sviluppo sta nel repo.
    Serve perché l'utente altrimenti deve andarla a cercare a mano dentro
    %LOCALAPPDATA%, che non è un posto che si indovina.
    """
    candidati = []
    if getattr(sys, "frozen", False):
        exe = Path(sys.executable)
        candidati.append(exe.parent / "estensione")      # app installata
        candidati.append(exe.parents[2] / "extension")   # exe in dist\, repo sopra
    candidati.append(Path(__file__).resolve().parents[2] / "extension")  # sorgente
    for c in candidati:
        if (c / "manifest.json").is_file():
            return str(c)
    return None


@app.get("/api/pair/list")
def pair_list():
    """Per le impostazioni: quali estensioni sono abbinate (mai gli hash), più
    il percorso della cartella da caricare nel browser."""
    _require_unlocked()
    return {"extensions": [{"name": e.get("name"), "origin": e.get("origin"),
                            "created": e.get("created"),
                            "last_used": _ext_ultimo_uso(e) or None}
                           for e in _ext_registry()],
            "scadenza_giorni": EXT_SCADENZA_GIORNI,
            "folder": _cartella_estensione()}


class PairRevokeIn(BaseModel):
    origin: str

@app.post("/api/pair/revoke")
def pair_revoke(body: PairRevokeIn):
    _require_unlocked()
    with _impostazioni:
        s = _load_settings()
        before = s.get("extensions", [])
        s["extensions"] = [e for e in before if e.get("origin") != body.origin]
        _save_settings(s)
    return {"ok": True, "removed": len(before) - len(s["extensions"])}


@app.get("/api/settings")
def get_settings():
    s = _load_settings()
    # gli abbinamenti hanno il loro endpoint (/api/pair/list): qui non servono
    # e conterrebbero gli hash dei token
    s.pop("extensions", None)
    # arricchisce con lo stato reale dei componenti (sola lettura)
    s["_ollama_available"] = llm.available()
    s["_audio_available"] = transcribe.available()
    s["_versione"] = __version__
    return s


class SettingsIn(BaseModel):
    autolock_minutes: int | None = None
    use_ollama: bool | None = None
    mic_enabled: bool | None = None
    gen_length: int | None = None
    gen_symbols: bool | None = None
    theme: str | None = None
    aggiornamenti: bool | None = None
    # Lo sfondo di ogni sezione e le voci aperte di recente (solo gli id: senza
    # il vault non dicono niente). Stavano nel localStorage, che la finestra
    # perde a ogni chiusura: pywebview apre WebView2 in modalita' privata.
    sfondi: dict[str, str] | None = None
    recenti: list[int] | None = None

def _impostazione_strana(k: str, v) -> Optional[str]:
    """Perché questo valore non si salva, o `None`. Il file delle impostazioni
    lo rilegge la pagina a ogni avvio e ci costruisce l'interfaccia: un valore
    assurdo (un blocco automatico fra un miliardo di minuti, un tema lungo un
    megabyte) resterebbe lì a ogni riapertura (pentest del 10/11/2026, B4)."""
    if k == "autolock_minutes" and not 0 <= v <= 24 * 60:
        return f"Blocco automatico fra 0 e 1440 minuti (letto: {v})."
    if k == "gen_length" and not 4 <= v <= 128:
        return f"Lunghezza del generatore fra 4 e 128 (letto: {v})."
    if k == "theme" and len(v) > 40:
        return "Nome del tema troppo lungo."
    if k == "sfondi" and (len(v) > 50 or any(len(a) > 80 or len(b) > 80 for a, b in v.items())):
        return "Troppi sfondi, o nomi troppo lunghi."
    if k == "recenti" and len(v) > 200:
        return f"Troppe voci recenti ({len(v)})."
    return None


@app.post("/api/settings")
def set_settings(body: SettingsIn):
    nuove = {k: v for k, v in body.model_dump().items() if v is not None}
    for k, v in nuove.items():
        strana = _impostazione_strana(k, v)
        if strana:
            raise HTTPException(status_code=400, detail=strana)
    with _impostazioni:
        s = _load_settings()
        s.update(nuove)
        _save_settings(s)
    # come la GET: gli hash dei token delle estensioni non escono
    fuori = dict(s)
    fuori.pop("extensions", None)
    return {"ok": True, "settings": fuori}


class ChangeMasterIn(BaseModel):
    old_master: str
    new_master: str

@app.post("/api/change_master")
def change_master(body: ChangeMasterIn):
    _require_unlocked()
    debole = regole_master.troppo_debole(body.new_master)
    if debole:
        raise HTTPException(status_code=400, detail=debole)
    try:
        S.store.change_master(body.old_master, body.new_master)
    except WrongPassword as e:
        raise HTTPException(status_code=403, detail=str(e))
    return {"ok": True}


# ---------------- freno ai tentativi sulla master ----------------
# Chi ha già il file del vault prova le password per conto suo, e qui non
# passa. Questo freno è per chi ha solo la finestra aperta davanti (o il token
# della pagina): senza, una prova sbagliata costava sei centesimi di secondo
# (pentest del 10/11/2026, M5). Le prime sbagliate sono gratis, perché le dita
# sbagliano; poi ogni errore raddoppia l'attesa, fino a cinque minuti. Solo in
# RAM: riavviare l'app azzera il conto, e a quel punto chi prova ha già di
# meglio da fare col file.
TENTATIVI_GRATIS = 5
ATTESA_MASSIMA_S = 300
_freno = {"sbagliate": 0, "fino": 0.0}
_freno_lock = threading.Lock()


def _freno_attesa() -> int:
    """Quanti secondi mancano prima di poter riprovare (0 = si può)."""
    with _freno_lock:
        return max(0, int(_freno["fino"] - time.time() + 0.999))


def _freno_sbagliata() -> None:
    with _freno_lock:
        _freno["sbagliate"] += 1
        oltre = _freno["sbagliate"] - TENTATIVI_GRATIS
        if oltre >= 0:
            _freno["fino"] = time.time() + min(ATTESA_MASSIMA_S, 5 * 2 ** min(oltre, 10))


def _freno_azzera() -> None:
    with _freno_lock:
        _freno["sbagliate"] = 0
        _freno["fino"] = 0.0


# ---------------- blocco automatico, deciso qui ----------------
# Fino alla 7.2 il vault lo bloccava un timer nella pagina. Se la pagina non
# girava — finestra ferma, scheda chiusa quando l'app è aperta nel browser,
# PC tornato dalla sospensione con la pagina congelata — la chiave restava in
# memoria e l'estensione continuava a leggere (pentest del 10/11/2026, M4).
# Adesso la pagina dice «l'utente c'è» (`/api/vivo`, al massimo ogni 30 s) e
# il conto lo tiene il server. Il timer della pagina resta: scatta per primo
# e ricarica la schermata; questo è il fondo, un minuto dopo.
MARGINE_BLOCCO_S = 60
_guardiano_vivo = threading.Event()


def _scaduto(ora: Optional[float] = None) -> bool:
    """Vault aperto e nessuno alla pagina da più del blocco automatico?"""
    if S.store is None or not S.attivo:
        return False
    try:
        minuti = int(_load_settings().get("autolock_minutes") or 0)
    except Exception:
        minuti = int(_DEFAULT_SETTINGS["autolock_minutes"])
    if minuti <= 0:
        return False   # «Mai»: una scelta dell'utente, vale anche qui
    return (ora or time.time()) - S.attivo > minuti * 60 + MARGINE_BLOCCO_S


def _guardiano() -> None:
    # L'orologio da muro e non `monotonic`: un'ora di sospensione deve contare.
    while True:
        time.sleep(15)
        try:
            if _scaduto():
                lock()
        except Exception:
            pass   # il guardiano non deve morire: riprova al prossimo giro


def _avvia_guardiano() -> None:
    if _guardiano_vivo.is_set():
        return
    _guardiano_vivo.set()
    threading.Thread(target=_guardiano, name="blocco-automatico", daemon=True).start()


@app.post("/api/vivo")
def vivo():
    """La pagina: l'utente ha toccato qualcosa. Non riapre niente: se il
    vault è già stato bloccato risponde 401 e la pagina torna alla serratura."""
    _require_unlocked()
    S.attivo = time.time()
    return {"ok": True}


@app.post("/api/unlock")
def unlock(body: UnlockIn):
    store = VaultStore(DEFAULT_VAULT)
    created = False
    if store.exists():
        attesa = _freno_attesa()
        if attesa:
            raise HTTPException(
                status_code=429,
                detail=f"Troppi tentativi sbagliati: riprova tra {attesa} secondi.")
        try:
            store.unlock(body.master)
        except WrongPassword:
            _freno_sbagliata()
            attesa = _freno_attesa()
            raise HTTPException(
                status_code=403,
                detail="Master password errata." + (
                    f" Prossimo tentativo tra {attesa} secondi." if attesa else ""))
        except VaultCorrupted:
            # Riprovare la password su un file danneggiato non porta da nessuna
            # parte: va detto subito qual è la strada giusta.
            raise HTTPException(
                status_code=422,
                detail="Il file del vault risulta danneggiato o incompleto. "
                       "La password non c'entra: ripristina un backup con "
                       "“Ripristina da backup” qui sotto.",
            )
    else:
        # creazione del vault: qui la password non si "verifica", si FISSA.
        # Una password debole scelta per sbaglio resterebbe l'unica chiave.
        debole = regole_master.troppo_debole(body.master)
        if debole:
            raise HTTPException(status_code=400, detail=debole)
        os.makedirs(os.path.dirname(DEFAULT_VAULT), exist_ok=True)
        store.create(body.master)
        created = True
    if not created:
        # Una copia del vault com'era all'apertura, se è cambiato dall'ultima:
        # la password è appena stata verificata, quindi è una copia che si
        # apre. Se non riesce non è un motivo per non aprire.
        try:
            copia_di_sicurezza(DEFAULT_VAULT, "apertura")
        except Exception:
            pass
    _freno_azzera()
    S.store = store
    S.attivo = time.time()
    _avvia_guardiano()
    _rebuild_index()
    # Il sync gira INSIEME al vault e si ferma con lui: senza chiave non c'è
    # niente da sincronizzare. Il primo giro parte subito, in sottofondo: lo
    # sblocco non deve aspettare la rete.
    SYNC.avvia()
    return {
        "ok": True,
        "created": created,
        "count": len(store.entries),
        "embedding_backend": _ensure_embeddings().backend,
        "llm": llm.available(),
        "audio_ready": transcribe.available(),
    }


@app.post("/api/query")
def query(body: QueryIn):
    _require_unlocked()
    _require_index()
    _use_llm = _load_settings().get("use_ollama", True)
    results = S.index.query(body.text)
    kind, picks = interpret(results)

    if kind == "none":
        txt = body.text.strip()
        looks_like_question = (
            "?" in txt or len(txt.split()) >= 4 or
            any(txt.lower().startswith(w) for w in
                ("come", "cosa", "perché", "perche", "puoi", "mi ", "vorrei",
                 "quanti", "quante", "spiega", "aiuto", "consiglia", "genera"))
        )
        if looks_like_question and _use_llm:
            titles = [c.title for c in S.index.creds][:8]
            reply = llm.chat(txt, context={"num_entries": len(S.index.creds),
                                            "sample_titles": titles})
            if reply:
                return {"kind": "chat", "reply": reply, "results": []}
        return {"kind": "none", "reply": "Non trovo niente che somigli abbastanza. Prova con il nome del servizio, o con una parola che hai messo nei tag.", "results": []}

    titles = [r.cred.title for r in picks]
    if kind == "ambiguous":
        reply = (llm.phrase(body.text, titles, kind="ambiguous") if _use_llm else None) or f"Ho trovato {len(picks)} voci simili. Quale intendevi?"
        return {"kind": "ambiguous", "reply": reply,
                "results": [r.cred.public() | {"score": round(r.score, 3)} for r in picks]}

    cred = picks[0].cred
    reply = (llm.phrase(body.text, titles, kind="single") if _use_llm else None) or "Ecco cosa ho trovato:"
    return {"kind": "single", "reply": reply,
            "results": [{"id": cred.id, "title": cred.title,
                         "fields": [{"label": f.label, "value": f.value} for f in cred.fields],
                         "tags": cred.tags, "critical": cred.critical,
                         "category": cred.category, "mod": cred.mod,
                         "score": round(picks[0].score, 3)}]}


@app.post("/api/reveal")
def reveal(body: QueryIn):
    """Restituisce una singola voce per id (usata dopo una scelta in ambiguità)."""
    _require_unlocked()
    try:
        cred_id = int(body.text)
    except ValueError:
        raise HTTPException(status_code=400, detail="id non valido")
    cred = S.store.get(cred_id)
    if not cred:
        raise HTTPException(status_code=404, detail="voce non trovata")
    return {"id": cred.id, "title": cred.title,
            "fields": [{"label": f.label, "value": f.value} for f in cred.fields],
            "tags": cred.tags, "critical": cred.critical,
            "category": cred.category, "mod": cred.mod}


@app.post("/api/add")
def add(body: AddIn):
    _require_unlocked()
    tags = [t.strip().lower() for t in body.tags.split(",") if t.strip()]
    fields = [{"label": f.label.strip(), "value": f.value} for f in body.fields if f.label.strip() or f.value]
    try:
        cred = S.store.add(body.title.strip(), fields, tags, body.critical, body.category)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    _rebuild_index()
    SYNC.programma_sync()
    return {"ok": True, "id": cred.id, "count": len(S.store.entries)}


@app.post("/api/update")
def update(body: UpdateIn):
    """Modifica una voce esistente (per completare credenziali o accorpare il 2FA)."""
    _require_unlocked()
    tags = [t.strip().lower() for t in body.tags.split(",") if t.strip()]
    fields = [{"label": f.label.strip(), "value": f.value} for f in body.fields if f.label.strip() or f.value]
    try:
        cred = S.store.update(body.id, body.title.strip(), fields, tags,
                              body.critical, body.category)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if cred is None:
        raise HTTPException(status_code=404, detail="voce non trovata")
    _rebuild_index()
    SYNC.programma_sync()
    return {"ok": True, "id": cred.id, "count": len(S.store.entries)}


def _normalize_entry(e: dict) -> dict:
    """Uniforma una voce estratta (da LLM o euristica) ai campi attesi dalla UI."""
    title = str(e.get("title") or "").strip()
    raw_fields = e.get("fields") or []
    fields = []
    for f in raw_fields:
        if not isinstance(f, dict):
            continue
        label = str(f.get("label") or "").strip()
        value = str(f.get("value") or "").strip()
        if label or value:
            fields.append({"label": label or "Valore", "value": value})
    tags = e.get("tags") or []
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",")]
    tags = [str(t).strip().lower() for t in tags if str(t).strip()]
    if not title:
        title = fields[0]["value"] if fields else "voce senza titolo"
    return {"title": title, "fields": fields, "tags": tags}


@app.post("/api/import_parse")
def import_parse(body: ImportParseIn):
    """Analizza un blob di testo e PROPONE delle voci (non salva nulla)."""
    _require_unlocked()
    text = body.text.strip()
    if not text:
        return {"source": "none", "entries": []}

    def _pulisci(parsed):
        out = [_normalize_entry(e) for e in (parsed or []) if isinstance(e, dict)]
        return [e for e in out if e["fields"]]

    entries, source = [], "euristica"
    # Rispetta l'interruttore "mind" delle impostazioni: chi lo spegne non si
    # aspetta di aspettare l'LLM anche qui.
    if _load_settings().get("use_ollama", True):
        entries = _pulisci(llm.extract_entries(text))
        if entries:
            source = "llm"

    # Rete di sicurezza: se l'LLM non ha prodotto NIENTE di utilizzabile
    # (risposta fuori formato, troncata, o timeout) si usa comunque il parser
    # locale, invece di rispondere "nessuna voce riconosciuta".
    if not entries:
        entries = _pulisci(heuristic_extract(text))
        source = "euristica"

    return {"source": source, "entries": entries}


@app.post("/api/import_csv")
def import_csv_endpoint(body: ImportCsvIn):
    """Analizza un export CSV (Bitwarden/1Password/KeePass o generico) e PROPONE
    le voci. Non salva nulla: la conferma avviene poi via /api/import_commit."""
    _require_unlocked()
    result = parse_csv(body.content)
    entries = [_normalize_entry(e) for e in result.get("entries", []) if isinstance(e, dict)]
    entries = [e for e in entries if e["fields"]]
    return {"source": result.get("source", "csv"), "entries": entries}


@app.post("/api/import_commit")
def import_commit(body: ImportCommitIn):
    """Salva nel vault le voci confermate dall'utente.

    Gli import grandi (export CSV da centinaia di voci) arrivano a blocchi, così
    la UI può mostrare l'avanzamento: ogni blocco è una sola riscrittura cifrata
    del vault, e l'indice si ricostruisce solo sull'ultimo (`rebuild`).
    """
    _require_unlocked()
    items = []
    con_2fa = 0
    for e in body.entries:
        fields = [{"label": f.label.strip(), "value": f.value} for f in e.fields if f.label.strip() or f.value]
        title = e.title.strip() or (fields[0]["value"] if fields else "voce senza titolo")
        tags = [t.strip().lower() for t in e.tags if t.strip()]
        # Un export di Bitwarden porta dentro anche i secret TOTP, in silenzio:
        # vanno contati per poterlo dire all'utente a fine import.
        if any(totp.is_otp_label(f["label"]) and (f["value"] or "").strip() for f in fields):
            con_2fa += 1
        items.append({"title": title, "fields": fields, "tags": tags})
    if items:
        S.store.add_many(items)
    if body.rebuild:
        _rebuild_index()
        # Solo alla fine dell'import, non a ogni blocco: un CSV da 800 voci
        # arriva in decine di chiamate, e ognuna farebbe partire uno scambio.
        SYNC.programma_sync()
    else:
        S.index_dirty = True
    return {"ok": True, "saved": len(items), "with_2fa": con_2fa,
            "count": len(S.store.entries)}


@app.post("/api/backup_save")
def backup_save():
    """Salva il vault cifrato su disco e RESTITUISCE IL PERCORSO ESATTO.

    Serve perché nella finestra pywebview un download normale finisce in
    Download senza dirlo a nessuno: il JavaScript non può conoscere il percorso,
    e l'utente si ritrova con "backup scaricato" senza sapere dove. Qui il file
    lo scrive il server, che quindi sa esattamente dove sta.

    Il nome porta la data: un backup non deve mai sovrascriverne uno precedente
    in silenzio — è l'unica copia recuperabile del vault.
    """
    _require_unlocked()
    if not os.path.exists(DEFAULT_VAULT):
        raise HTTPException(status_code=404, detail="Nessun vault da esportare.")
    # Su Windows la cartella su disco resta "Downloads" anche in italiano;
    # se manca (o su altri sistemi) si ripiega sulla home.
    dest_dir = Path.home() / "Downloads"
    if not dest_dir.is_dir():
        dest_dir = Path.home()
    nome = f"vaultmind-backup-{time.strftime('%Y%m%d-%H%M')}.json"
    dest = dest_dir / nome
    if dest.exists():                       # due backup nello stesso minuto
        dest = dest_dir / f"vaultmind-backup-{time.strftime('%Y%m%d-%H%M%S')}.json"
    dest.write_text(Path(DEFAULT_VAULT).read_text(encoding="utf-8"), encoding="utf-8")
    return {"ok": True, "path": str(dest), "name": dest.name}


@app.post("/api/restore")
def restore(body: RestoreIn):
    """
    Ripristina un file di backup (vault cifrato) su questa macchina.
    Va eseguito a vault BLOCCATO: dopo il ripristino si sblocca con la master
    password usata sul dispositivo di origine. Il contenuto resta cifrato.
    """
    return _ripristina(body.content)


def _ripristina(testo: str) -> dict:
    """Il ripristino vero, da un file scelto o da una copia automatica.

    Il vault che c'era non si butta: finisce in `copie/` (motivo
    `ripristino`) prima che il nuovo prenda il suo posto, e se quella copia
    non si riesce a fare non si ripristina niente. Chi ha scelto il file
    sbagliato deve poter tornare indietro.
    """
    if S.store is not None and S.store.unlocked:
        raise HTTPException(status_code=400, detail="Blocca il vault prima di ripristinare un backup.")
    try:
        copia = sostituisci_vault(DEFAULT_VAULT, testo)
    except VaultCorrupted:
        raise HTTPException(status_code=400,
                            detail="File di backup non valido: non è un vault di VaultMind. "
                                   "Il vault che c'era non è stato toccato.")
    except OSError as exc:
        raise HTTPException(status_code=500,
                            detail="Non sono riuscito a mettere da parte il vault attuale, "
                                   f"quindi non ho ripristinato niente ({exc}).")
    return {"ok": True, "copia": os.path.basename(copia) if copia else None}


@app.get("/api/copie")
def copie():
    """Le copie automatiche del vault, per la schermata di blocco: «il vault è
    danneggiato» o «ho svuotato tutto» devono avere una strada che non sia
    andare a cercare un file in una cartella nascosta."""
    return {"copie": elenco_copie(DEFAULT_VAULT)}


class CopiaIn(BaseModel):
    nome: str

@app.post("/api/copie/ripristina")
def copie_ripristina(body: CopiaIn):
    # Il nome si cerca nell'elenco e non si usa come percorso: quello che
    # arriva da fuori non deve poter indicare un file qualunque del disco.
    if not any(c["nome"] == body.nome for c in elenco_copie(DEFAULT_VAULT)):
        raise HTTPException(status_code=404, detail="Questa copia non c'è più.")
    try:
        testo = Path(cartella_copie(DEFAULT_VAULT), body.nome).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        raise HTTPException(status_code=400, detail="Questa copia non si riesce a leggere.")
    return _ripristina(testo)


@app.post("/api/totp")
def totp_codes(body: TotpIn):
    """Calcola i codici 2FA correnti per i campi 'secret OTP' della voce.
    Tutto in locale: è solo HMAC-SHA1 del tempo con il secret salvato."""
    _require_unlocked()
    cred = S.store.get(body.cred_id)
    if not cred:
        raise HTTPException(status_code=404, detail="voce non trovata")
    return {"id": cred.id, "otp": totp.codes_for(cred)}


@app.post("/api/vicine")
def vicine(body: TotpIn):
    """Le tre voci piu' simili a questa, per il dettaglio nel database: lo
    stesso spazio vettoriale della chat, cosi' si vede cosa la ricerca
    considera vicino. Solo titoli e categoria, mai i valori. Non e' in
    EXT_ALLOWED: all'estensione non serve."""
    _require_unlocked()
    _require_index()
    return {"vicine": [{"id": r.cred.id, "title": r.cred.title,
                        "category": r.cred.category,
                        "score": round(max(0.0, r.score), 3)}
                       for r in S.index.vicine(body.cred_id)]}


@app.post("/api/transcribe")
async def transcribe_audio(file: UploadFile = File(...)):
    """Trascrive audio (microfono) in locale con Whisper, se installato."""
    _require_unlocked()
    if not transcribe.available():
        raise HTTPException(
            status_code=503,
            detail="Trascrizione vocale non disponibile. Installa il modulo audio: "
                   "pip install -r requirements-audio.txt (scarica il modello al primo uso).",
        )
    data = await file.read()
    suffix = os.path.splitext(file.filename or "")[1] or ".webm"
    try:
        text = transcribe.transcribe_bytes(data, suffix=suffix)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Trascrizione fallita: {exc}")
    return {"text": text}


@app.get("/api/list")
def list_entries():
    """Restituisce tutte le voci (con campi) per il Database GUI."""
    _require_unlocked()
    result = []
    for c in S.store.entries:
        result.append({
            "id": c.id,
            "title": c.title,
            "tags": c.tags,
            "critical": c.critical,
            "category": c.category,
            "mod": c.mod,
            "fields": [{"label": f.label, "value": f.value} for f in c.fields],
        })
    return {"entries": result, "count": len(result),
            "categories": S.store.categories}


# ---------------------------------------------------------------- categorie
# Raggruppamenti scelti A MANO. Non si deducono mai dai tag: quelli di un
# import sono spesso parole ricavate dal titolo, e raggrupparci sopra darebbe
# centinaia di sezioni da una voce sola. Vivono nel vault, così viaggiano col
# backup e il telefono se le ritrova già fatte.

class CategoryIn(BaseModel):
    name: str

class CategoryRenameIn(BaseModel):
    old: str
    new: str

class SetCategoryIn(BaseModel):
    ids: List[int]
    name: str = ""   # vuoto = toglie la categoria


# -------------------------------------------------------- sincronizzazione
# Il motore sta in sync_app/sync_net/merge: qui ci sono solo gli endpoint. Il
# PC non ascolta sulla rete: chiama lui i telefoni collegati (vedi sync_net),
# e FastAPI resta su 127.0.0.1.

# Porta e indirizzi del telefono si spostano solo per provare l'app contro un
# telefono finto sullo stesso PC (`tests/telefono_finto.py`): su 127.0.0.1,
# perché un programma che ascolta su tutte le schede fa comparire l'avviso
# del firewall. Chi non tocca le variabili non se ne accorge.
_PORTA_SYNC = int(os.environ.get("VAULTMIND_SYNC_PORT", sync_net.PORTA_SYNC))
_INDIRIZZI_PROVA = [h.strip() for h in
                    os.environ.get("VAULTMIND_SYNC_INDIRIZZI", "").split(",") if h.strip()]


def _vault_cambiato_da_fuori() -> None:
    """Il sync ha cambiato il vault mentre l'app era aperta.

    L'indice va rifatto, altrimenti la voce arrivata dal telefono sta nel vault
    ma la chat non la trova, e sembra che il sync non sia arrivato. Si segna e
    basta: `_ensure_index()` lo rifà prima della prossima ricerca. La pagina
    aperta se ne accorge da sola con `/api/sync/novita`.
    """
    S.index_dirty = True


SYNC = SyncApp(store_di=lambda: S.store,
               leggi_impostazioni=_load_settings,
               salva_impostazioni=_save_settings,
               porta=_PORTA_SYNC,
               dopo_fusione=_vault_cambiato_da_fuori,
               reti=(lambda: [_INDIRIZZI_PROVA]) if _INDIRIZZI_PROVA else None)


class SyncImpostaIn(BaseModel):
    nome: Optional[str] = None
    acceso: Optional[bool] = None

class SyncScollegaIn(BaseModel):
    id: str


@app.get("/api/sync/stato")
def sync_stato():
    _require_unlocked()
    return {
        "acceso": SYNC.acceso,
        "nome": SYNC.nome,
        "telefoni": SYNC.telefoni(),
        "collegamento": SYNC.stato_collegamento(),
        "ultimo": SYNC.ultimo,
    }


@app.get("/api/sync/novita")
def sync_novita():
    """Com'è messo il sync, in pochi numeri. La pagina lo chiede in
    continuazione: qui dentro non si tocca la rete.

    Esiste perché le voci che arrivano dal telefono le scrive il filo del
    sync, e la pagina aperta non ha nessun altro modo di saperlo.
    """
    _require_unlocked()
    return {
        "revisione": SYNC.revisione,
        "ultimo": SYNC.ultimo,
        "telefoni": len(SYNC.telefoni()),
    }


@app.post("/api/sync/adesso")
def sync_adesso():
    """Il sync subito con tutti i telefoni collegati, cercando anche chi non
    risponde all'ultimo indirizzo. È il pulsante nella barra."""
    _require_unlocked()
    return SYNC.sincronizza_adesso()


@app.post("/api/sync/imposta")
def sync_imposta(body: SyncImpostaIn):
    _require_unlocked()
    SYNC.imposta(nome=body.nome, acceso=body.acceso)
    return {"ok": True, "acceso": SYNC.acceso, "nome": SYNC.nome}


@app.post("/api/sync/collega")
def sync_collega():
    """Il QR per collegare un telefono: una chiave nuova, valida finché la
    finestra resta aperta. Il testo del QR torna anche in chiaro, per chi
    prova l'app con il telefono finto."""
    _require_unlocked()
    try:
        return SYNC.inizia_collegamento()
    except RifiutoSync as exc:
        raise HTTPException(status_code=409, detail=str(exc))


@app.post("/api/sync/collega_ferma")
def sync_collega_ferma():
    _require_unlocked()
    SYNC.ferma_collegamento()
    return {"ok": True}


@app.post("/api/sync/scollega")
def sync_scollega(body: SyncScollegaIn):
    _require_unlocked()
    return {"ok": SYNC.scollega(body.id)}


@app.get("/api/categories")
def categories():
    _require_unlocked()
    conteggio = S.store.count_by_category()
    return {"categories": [{"name": c, "count": conteggio.get(c, 0)}
                           for c in S.store.categories],
            "uncategorized": conteggio.get("", 0)}


@app.post("/api/category_add")
def category_add(body: CategoryIn):
    _require_unlocked()
    try:
        nome = S.store.add_category(body.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    SYNC.programma_sync()
    return {"ok": True, "name": nome}


@app.post("/api/category_rename")
def category_rename(body: CategoryRenameIn):
    _require_unlocked()
    try:
        nome = S.store.rename_category(body.old, body.new)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if nome is None:
        raise HTTPException(status_code=404, detail="categoria non trovata")
    _rebuild_index()   # la categoria entra nell'indice della ricerca
    SYNC.programma_sync()
    return {"ok": True, "name": nome}


@app.post("/api/category_delete")
def category_delete(body: CategoryIn):
    """Elimina la categoria. Le voci NON si toccano: restano nel vault senza
    categoria. Cancellare un raggruppamento non può cancellare le password che
    raggruppava."""
    _require_unlocked()
    liberate = S.store.delete_category(body.name)
    _rebuild_index()
    SYNC.programma_sync()
    return {"ok": True, "freed": liberate}


@app.post("/api/set_category")
def set_category(body: SetCategoryIn):
    """Assegna la categoria a più voci con UNA sola riscrittura del vault:
    farlo voce per voce su 200 voci significherebbe 200 cifrature."""
    _require_unlocked()
    try:
        toccate = S.store.set_category(body.ids, body.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if toccate:
        _rebuild_index()
        SYNC.programma_sync()
    return {"ok": True, "changed": toccate}


@app.delete("/api/delete/{cred_id}")
def delete_entry(cred_id: int):
    """Elimina una singola voce dal vault per id."""
    _require_unlocked()
    cred = S.store.get(cred_id)
    if not cred:
        raise HTTPException(status_code=404, detail="Voce non trovata.")
    S.store.delete(cred_id)
    _rebuild_index()
    SYNC.programma_sync()
    return {"ok": True, "count": len(S.store.entries)}


@app.post("/api/clear")
def clear_all():
    """Svuota completamente il vault (tutte le voci). Richiede vault sbloccato.
    La conferma esplicita avviene lato UI: qui si esegue e basta."""
    _require_unlocked()
    removed = len(S.store.entries)
    S.store.clear()
    _rebuild_index()
    SYNC.programma_sync()
    return {"ok": True, "removed": removed, "count": len(S.store.entries)}


class OpenUrlIn(BaseModel):
    url: str

@app.post("/api/open_url")
def open_url(body: OpenUrlIn):
    """Apre un URL nel browser di SISTEMA.

    Serve perché nella finestra nativa (pywebview) un link normale navigherebbe
    la finestra dell'app, portandola via dal vault. Solo http/https: qualunque
    altro schema (file:, javascript:, ...) trasformerebbe un campo del vault in
    un modo per eseguire cose sulla macchina.
    """
    _require_unlocked()
    u = (body.url or "").strip()
    if not u.lower().startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="Sono ammessi solo indirizzi http:// o https://")
    import webbrowser
    webbrowser.open(u)
    return {"ok": True}


# ---------------- aggiornamenti dell'app ----------------
# Il perché e i vincoli stanno in aggiornamenti.py. Qui c'è solo la colla:
# quando si chiede a GitHub, cosa si ricorda, e chi lancia il setup.
#
# Lo stato del download vive in RAM e non su disco: riguarda questa sessione, e
# appena il setup parte questo processo non esiste più.
_AGG: dict = {"fase": "fermo", "percento": 0, "errore": None}


def _agg_rinviata(s: dict, versione: str) -> bool:
    """«Più tardi» su una versione precisa non si ripropone per RINVIO_ORE."""
    return (s.get("agg_rinviata") == versione and
            aggiornamenti.ora_ms() - int(s.get("agg_rinviata_quando") or 0)
            < aggiornamenti.RINVIO_ORE * 3600_000)


def _agg_controlla(forza: bool = False) -> tuple:
    """`(novità, risposto)`: la novità da mostrare, dalla rete o da quello che
    si sapeva già.

    Non solleva mai. Quando la rete non risponde si tiene l'ultima risposta
    buona, così chi ha visto l'avviso ieri lo rivede anche offline — è ancora
    vero.

    `risposto` False vuol dire «non lo so»: nessuna rete, o un proxy che ha
    risposto qualcosa che non è una release. Serve a una cosa sola, e
    importante: chi ha **premuto un pulsante** merita una risposta onesta, e
    «hai già l'ultima versione» detto senza connessione è una bugia. Il
    controllo automatico non lo guarda: lì il silenzio è giusto.
    """
    s = _load_settings()
    if not s.get("aggiornamenti", True):
        return None, True
    risposto = True
    vecchio = (aggiornamenti.ora_ms() - int(s.get("agg_controllo") or 0)
               >= aggiornamenti.INTERVALLO_ORE * 3600_000)
    if forza or vecchio:
        info = aggiornamenti.cerca()
        risposto = info is not None
        # Rilettura: fra l'inizio della richiesta e adesso l'utente può aver
        # salvato un'altra impostazione, e scrivere il dizionario vecchio la
        # cancellerebbe.
        s = _load_settings()
        s["agg_controllo"] = aggiornamenti.ora_ms()
        if info is not None:
            s["agg_trovata"] = info if aggiornamenti.piu_recente(info["versione"], __version__) else None
        _save_settings(s)
    trovata = s.get("agg_trovata")
    if not isinstance(trovata, dict):
        return None, risposto
    # Dopo un aggiornamento riuscito la nota resta nelle impostazioni: è questo
    # confronto, non la cancellazione, a farla smettere di comparire.
    if not aggiornamenti.piu_recente(str(trovata.get("versione") or ""), __version__):
        return None, risposto
    return trovata, risposto


@app.get("/api/aggiornamento")
def aggiornamento(forza: bool = False):
    """Stato per la pagina. La chiama lo sblocco e poi ogni sei ore.

    Il controllo di rete avviene QUI, ma nessuno aspetta questa risposta per
    usare l'app: la pagina la chiede e se ne dimentica. Senza connessione la
    richiesta finisce in timeout dopo 8 secondi e torna «niente di nuovo».
    """
    nuova, risposto = _agg_controlla(forza=forza)
    s = _load_settings()
    fuori = {
        "versione": __version__,
        "attiva": bool(s.get("aggiornamenti", True)),
        "risposto": risposto,
        "pagina": aggiornamenti.PAGINA_RELEASE,
        "fase": _AGG["fase"],
        "percento": _AGG["percento"],
        "errore": _AGG["errore"],
        "nuova": None,
    }
    if nuova:
        fuori["nuova"] = {
            "versione": nuova.get("versione"),
            "note": aggiornamenti.note_pulite(str(nuova.get("note") or "")),
            "pagina": nuova.get("pagina") or aggiornamenti.PAGINA_RELEASE,
            "scaricabile": aggiornamenti.installabile(nuova),
            "rinviata": _agg_rinviata(s, str(nuova.get("versione") or "")),
        }
    return fuori


class RinviaIn(BaseModel):
    versione: str

@app.post("/api/aggiornamento/rinvia")
def aggiornamento_rinvia(body: RinviaIn):
    s = _load_settings()
    s["agg_rinviata"] = body.versione
    s["agg_rinviata_quando"] = aggiornamenti.ora_ms()
    _save_settings(s)
    return {"ok": True}


def _agg_lavora(info: dict) -> None:
    """Scarica, verifica, lancia. Gira in un thread: l'ultima riga chiude
    l'app, e una richiesta HTTP in attesa morirebbe con lei."""
    _AGG.update(fase="scarico", percento=0, errore=None)
    try:
        percorso = aggiornamenti.scarica(
            info, su_progresso=lambda v: _AGG.update(percento=int(v * 100)))
    except Exception as exc:
        _AGG.update(fase="errore", errore=str(exc) or "Download non riuscito.")
        return
    _AGG.update(fase="installo", percento=100)
    try:
        if not aggiornamenti.installa(percorso):
            _AGG.update(fase="errore",
                        errore="Windows non ha avviato il programma di installazione.")
    except Exception as exc:
        _AGG.update(fase="errore", errore=str(exc))


@app.post("/api/aggiornamento/installa")
def aggiornamento_installa():
    """Avvia l'aggiornamento e risponde subito.

    Il setup silenzioso **chiude VaultMind** e lo riapre aggiornato: la
    risposta deve essere già partita quando succede, quindi il lavoro vero sta
    in un thread e la pagina guarda l'avanzamento con /api/aggiornamento.
    """
    _require_unlocked()
    if _AGG["fase"] in ("scarico", "installo"):
        return {"ok": True, "fase": _AGG["fase"]}
    nuova, _ = _agg_controlla()
    if not nuova:
        raise HTTPException(status_code=400, detail="Non c'è nessuna versione più recente da installare.")
    if not aggiornamenti.installabile(nuova):
        raise HTTPException(status_code=400,
                            detail="Questa release non allega il setup firmato di Windows: scaricalo dalla pagina.")
    threading.Thread(target=_agg_lavora, args=(nuova,), daemon=True).start()
    return {"ok": True, "fase": "scarico"}


@app.post("/api/lock")
def lock():
    SYNC.ferma()          # prima il sync, poi la chiave
    if S.store:
        S.store.lock()
    S.store = None
    S.index = None
    S.index_dirty = False
    S.attivo = 0.0
    return {"ok": True}
