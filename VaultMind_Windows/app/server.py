"""
server.py — App web locale (FastAPI), in ascolto SOLO su 127.0.0.1.

La sessione (chiave derivata + indice) vive in RAM nel processo, per la durata
dell'esecuzione. Nessun endpoint è esposto sulla rete: il bind è loopback.
"""

from __future__ import annotations
import os
import sys
import json
import secrets
import hashlib
import time
from pathlib import Path
from typing import List, Optional, Any

from fastapi import FastAPI, HTTPException, UploadFile, File, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .crypto_store import VaultStore, WrongPassword, VaultCorrupted
from .embedding import Embeddings
from .search import SearchIndex, interpret
from .import_parse import heuristic_extract
from .import_csv import parse_csv
from .sync_app import SyncApp
from .sync_net import RifiutoSync
from . import sync_net
from . import llm
from . import totp
from . import transcribe

WEB_DIR = Path(__file__).parent / "web"
DEFAULT_VAULT = os.environ.get("VAULTMIND_FILE", str(Path.home() / ".vaultmind" / "vault.json"))

app = FastAPI(title="VaultMind (local)")
app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")

# ---- stato di processo (singolo utente locale) ----
class Session:
    def __init__(self):
        self.store: Optional[VaultStore] = None
        self.index: Optional[SearchIndex] = None
        self.embeddings: Optional[Embeddings] = None
        self.index_dirty: bool = False   # indice da riallineare prima della prossima ricerca

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
@app.get("/", response_class=HTMLResponse)
def home():
    # La pagina riceve il token di sessione: nessun altro sito può leggere
    # questo HTML (same-origin policy), quindi nessun altro sito può parlare
    # con le API. Vale per pywebview e per il fallback browser.
    html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    return html.replace("__VM_TOKEN__", UI_TOKEN)


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
    "theme": "dark",
}

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
#      servito da "/" (che nessun altro sito può leggere); un sito terzo non
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

# codice di abbinamento in corso: solo in RAM, mai su disco
_pairing: dict = {}


def _hash_token(tok: str) -> str:
    return hashlib.sha256(tok.encode("utf-8")).hexdigest()

def _ext_registry() -> list:
    return list(_load_settings().get("extensions", []))

def _ext_for_token(tok: str):
    """L'estensione abbinata per questo token, o None. Su disco sta solo
    l'hash: chi legge settings.json non ricava il token."""
    if not tok:
        return None
    h = _hash_token(tok)
    for e in _ext_registry():
        if secrets.compare_digest(h, str(e.get("token_hash", ""))):
            return e
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

    path = request.url.path
    if not path.startswith("/api/"):
        return await call_next(request)   # "/" e /static: è la pagina stessa

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
    if secrets.compare_digest(tok, UI_TOKEN):
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
    if not secrets.compare_digest(body.code.strip(), _pairing["code"]):
        raise HTTPException(status_code=403, detail="Codice errato.")
    _pairing.clear()
    token = secrets.token_urlsafe(32)
    s = _load_settings()
    # ri-abbinare la stessa estensione sostituisce il token vecchio
    exts = [e for e in s.get("extensions", []) if e.get("origin") != origin]
    exts.append({
        "name": (body.name.strip() or "Estensione browser")[:60],
        "origin": origin,
        "token_hash": _hash_token(token),
        "created": time.strftime("%d/%m/%Y %H:%M"),
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
                            "created": e.get("created")} for e in _ext_registry()],
            "folder": _cartella_estensione()}


class PairRevokeIn(BaseModel):
    origin: str

@app.post("/api/pair/revoke")
def pair_revoke(body: PairRevokeIn):
    _require_unlocked()
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
    return s


class SettingsIn(BaseModel):
    autolock_minutes: int | None = None
    use_ollama: bool | None = None
    mic_enabled: bool | None = None
    gen_length: int | None = None
    gen_symbols: bool | None = None
    theme: str | None = None

@app.post("/api/settings")
def set_settings(body: SettingsIn):
    s = _load_settings()
    for k, v in body.model_dump().items():
        if v is not None:
            s[k] = v
    _save_settings(s)
    return {"ok": True, "settings": s}


class ChangeMasterIn(BaseModel):
    old_master: str
    new_master: str

@app.post("/api/change_master")
def change_master(body: ChangeMasterIn):
    _require_unlocked()
    if len(body.new_master) < 8:
        raise HTTPException(status_code=400, detail="La nuova password deve avere almeno 8 caratteri.")
    try:
        S.store.change_master(body.old_master, body.new_master)
    except WrongPassword as e:
        raise HTTPException(status_code=403, detail=str(e))
    return {"ok": True}


@app.post("/api/unlock")
def unlock(body: UnlockIn):
    store = VaultStore(DEFAULT_VAULT)
    created = False
    if store.exists():
        try:
            store.unlock(body.master)
        except WrongPassword:
            raise HTTPException(status_code=403, detail="Master password errata.")
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
        if len(body.master) < 8:
            raise HTTPException(
                status_code=400,
                detail="Scegli una master password di almeno 8 caratteri: è l'unica chiave del vault.",
            )
        os.makedirs(os.path.dirname(DEFAULT_VAULT), exist_ok=True)
        store.create(body.master)
        created = True
    S.store = store
    _rebuild_index()
    # Il sync si apre INSIEME al vault e si chiude con lui: senza chiave non
    # c'è niente da sincronizzare, e restare in ascolto sarebbe solo una porta
    # aperta che non serve a nessuno.
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
        return {"kind": "none", "reply": "Nessuna corrispondenza nel vault. Prova un altro termine o aggiungi la voce col pulsante +.", "results": []}

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
            "tags": cred.tags, "critical": cred.critical}


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
    if S.store is not None and S.store.unlocked:
        raise HTTPException(status_code=400, detail="Blocca il vault prima di ripristinare un backup.")
    try:
        blob = json.loads(body.content)
        assert {"kdf", "nonce", "ciphertext"} <= set(blob.keys())
    except Exception:
        raise HTTPException(status_code=400, detail="File di backup non valido.")
    os.makedirs(os.path.dirname(DEFAULT_VAULT), exist_ok=True)
    Path(DEFAULT_VAULT).write_text(body.content, encoding="utf-8")
    return {"ok": True}


@app.post("/api/totp")
def totp_codes(body: TotpIn):
    """Calcola i codici 2FA correnti per i campi 'secret OTP' della voce.
    Tutto in locale: è solo HMAC-SHA1 del tempo con il secret salvato."""
    _require_unlocked()
    cred = S.store.get(body.cred_id)
    if not cred:
        raise HTTPException(status_code=404, detail="voce non trovata")
    return {"id": cred.id, "otp": totp.codes_for(cred)}


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
# Il motore sta in sync_app/sync_net/merge: qui ci sono solo gli endpoint.
# L'ascoltatore vive insieme al vault (vedi /api/unlock e /api/lock) e non ha
# niente a che vedere col server FastAPI, che resta su 127.0.0.1.

# Le porte si possono spostare con due variabili d'ambiente. Servono a due
# cose: far convivere due istanze sullo stesso computer (cioè poter PROVARE il
# sync senza avere due macchine), e cavarsela se quelle porte sono già occupate
# da qualcos'altro. Chi non le tocca non se ne accorge.
_PORTA_SYNC = int(os.environ.get("VAULTMIND_SYNC_PORT", sync_net.PORTA_SYNC))
_PORTA_SCOPERTA = int(os.environ.get("VAULTMIND_SYNC_SCOPERTA", sync_net.PORTA_SCOPERTA))

SYNC = SyncApp(store_di=lambda: S.store,
               leggi_impostazioni=_load_settings,
               salva_impostazioni=_save_settings,
               porta=_PORTA_SYNC,
               porta_scoperta=_PORTA_SCOPERTA)


class SyncImpostaIn(BaseModel):
    nome: Optional[str] = None
    acceso: Optional[bool] = None

class SyncOraIn(BaseModel):
    indirizzo: str
    porta: int = sync_net.PORTA_SYNC
    codice: str = ""

class SyncRevocaIn(BaseModel):
    id: str

class SyncRisolviIn(BaseModel):
    uid: str
    scelta: str   # "mia" | "sua"


@app.get("/api/sync/stato")
def sync_stato():
    _require_unlocked()
    return {
        "acceso": SYNC.acceso,
        "in_ascolto": SYNC.in_ascolto,
        "id": SYNC.id_dispositivo,
        "nome": SYNC.nome,
        "dispositivi": SYNC.dispositivi(),
        "codice": SYNC.codice_attivo(),
        "conflitti": len(SYNC.conflitti),
        "ultimo": SYNC.ultimo,
    }


@app.post("/api/sync/imposta")
def sync_imposta(body: SyncImpostaIn):
    _require_unlocked()
    SYNC.imposta(nome=body.nome, acceso=body.acceso)
    return {"ok": True, "acceso": SYNC.acceso, "nome": SYNC.nome,
            "in_ascolto": SYNC.in_ascolto}


@app.post("/api/sync/abbina_inizia")
def sync_abbina_inizia():
    """Apre la finestra di abbinamento e restituisce il codice da leggere
    sull'altro dispositivo. Vale 120 secondi e 5 tentativi."""
    _require_unlocked()
    if not SYNC.in_ascolto and not SYNC.avvia():
        raise HTTPException(status_code=409,
                            detail="Il sync è spento: accendilo per abbinare un dispositivo.")
    return SYNC.apri_abbinamento()


@app.post("/api/sync/abbina_ferma")
def sync_abbina_ferma():
    _require_unlocked()
    SYNC.chiudi_abbinamento()
    return {"ok": True}


@app.post("/api/sync/cerca")
def sync_cerca():
    """Chiede sulla rete locale chi ha lo stesso vault. La domanda è firmata:
    chi non ha la chiave non sa nemmeno riconoscerla, e non risponde."""
    _require_unlocked()
    return {"dispositivi": SYNC.cerca()}


@app.post("/api/sync/ora")
def sync_ora(body: SyncOraIn):
    _require_unlocked()
    try:
        return SYNC.sincronizza_con(body.indirizzo, body.porta, body.codice)
    except RifiutoSync as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except OSError:
        raise HTTPException(status_code=502,
                            detail="Non è stato possibile raggiungere quel dispositivo.")


@app.post("/api/sync/revoca")
def sync_revoca(body: SyncRevocaIn):
    _require_unlocked()
    return {"ok": SYNC.revoca(body.id)}


@app.get("/api/sync/conflitti")
def sync_conflitti():
    _require_unlocked()
    return {"conflitti": SYNC.elenco_conflitti()}


@app.post("/api/sync/risolvi")
def sync_risolvi(body: SyncRisolviIn):
    _require_unlocked()
    if body.scelta not in ("mia", "sua"):
        raise HTTPException(status_code=400, detail="scelta non valida")
    if not SYNC.risolvi(body.uid, body.scelta):
        raise HTTPException(status_code=404, detail="conflitto non trovato")
    _rebuild_index()
    return {"ok": True, "restanti": len(SYNC.conflitti)}


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
    return {"ok": True, "name": nome}


@app.post("/api/category_delete")
def category_delete(body: CategoryIn):
    """Elimina la categoria. Le voci NON si toccano: restano nel vault senza
    categoria. Cancellare un raggruppamento non può cancellare le password che
    raggruppava."""
    _require_unlocked()
    liberate = S.store.delete_category(body.name)
    _rebuild_index()
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
    return {"ok": True, "count": len(S.store.entries)}


@app.post("/api/clear")
def clear_all():
    """Svuota completamente il vault (tutte le voci). Richiede vault sbloccato.
    La conferma esplicita avviene lato UI: qui si esegue e basta."""
    _require_unlocked()
    removed = len(S.store.entries)
    S.store.clear()
    _rebuild_index()
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


@app.post("/api/lock")
def lock():
    SYNC.ferma()          # prima la porta, poi la chiave
    if S.store:
        S.store.lock()
    S.store = None
    S.index = None
    S.index_dirty = False
    return {"ok": True}
