"""
server.py — App web locale (FastAPI), in ascolto SOLO su 127.0.0.1.

La sessione (chiave derivata + indice) vive in RAM nel processo, per la durata
dell'esecuzione. Nessun endpoint è esposto sulla rete: il bind è loopback.
"""

from __future__ import annotations
import os
import json
from pathlib import Path
from typing import List, Optional, Any

from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .crypto_store import VaultStore, WrongPassword, seed_into
from .embedding import Embeddings
from .search import SearchIndex, interpret
from .import_parse import heuristic_extract
from .import_csv import parse_csv
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
    seed_if_new: bool = True

class QueryIn(BaseModel):
    text: str

class FieldIn(BaseModel):
    label: str
    value: str

class AddIn(BaseModel):
    title: str
    fields: List[FieldIn] = []
    tags: str = ""

class UpdateIn(BaseModel):
    id: int
    title: str
    fields: List[FieldIn] = []
    tags: str = ""

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
    return (WEB_DIR / "index.html").read_text(encoding="utf-8")


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


@app.get("/api/settings")
def get_settings():
    s = _load_settings()
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
        if body.seed_if_new:
            seed_into(store)
    S.store = store
    _rebuild_index()
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
                         "tags": cred.tags, "score": round(picks[0].score, 3)}]}


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
            "tags": cred.tags}


@app.post("/api/add")
def add(body: AddIn):
    _require_unlocked()
    tags = [t.strip().lower() for t in body.tags.split(",") if t.strip()]
    fields = [{"label": f.label.strip(), "value": f.value} for f in body.fields if f.label.strip() or f.value]
    cred = S.store.add(body.title.strip(), fields, tags)
    _rebuild_index()
    return {"ok": True, "id": cred.id, "count": len(S.store.entries)}


@app.post("/api/update")
def update(body: UpdateIn):
    """Modifica una voce esistente (per completare credenziali o accorpare il 2FA)."""
    _require_unlocked()
    tags = [t.strip().lower() for t in body.tags.split(",") if t.strip()]
    fields = [{"label": f.label.strip(), "value": f.value} for f in body.fields if f.label.strip() or f.value]
    cred = S.store.update(body.id, body.title.strip(), fields, tags)
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
    parsed = llm.extract_entries(text)        # prova con Ollama (locale)
    source = "llm"
    if parsed is None:
        parsed = heuristic_extract(text)      # fallback senza LLM
        source = "euristica"
    entries = [_normalize_entry(e) for e in parsed if isinstance(e, dict)]
    entries = [e for e in entries if e["fields"]]
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
    for e in body.entries:
        fields = [{"label": f.label.strip(), "value": f.value} for f in e.fields if f.label.strip() or f.value]
        title = e.title.strip() or (fields[0]["value"] if fields else "voce senza titolo")
        tags = [t.strip().lower() for t in e.tags if t.strip()]
        items.append({"title": title, "fields": fields, "tags": tags})
    if items:
        S.store.add_many(items)
    if body.rebuild:
        _rebuild_index()
    else:
        S.index_dirty = True
    return {"ok": True, "saved": len(items), "count": len(S.store.entries)}


@app.get("/api/backup")
def backup():
    """Restituisce il file vault CIFRATO così com'è su disco (backup portabile)."""
    _require_unlocked()
    path = DEFAULT_VAULT
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Nessun vault da esportare.")
    data = Path(path).read_text(encoding="utf-8")
    return PlainTextResponse(
        data,
        headers={"Content-Disposition": 'attachment; filename="vaultmind-backup.json"'},
        media_type="application/json",
    )


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
            "fields": [{"label": f.label, "value": f.value} for f in c.fields],
        })
    return {"entries": result, "count": len(result)}


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


@app.post("/api/lock")
def lock():
    if S.store:
        S.store.lock()
    S.store = None
    S.index = None
    S.index_dirty = False
    return {"ok": True}
