"""
llm.py — Strato LLM locale OPZIONALE (via Ollama). L'assistente si chiama "mind".

Ruolo e confini di sicurezza:
  - mind formula le risposte in linguaggio naturale e risponde a domande
    generali (sicurezza, uso dell'app, conteggi) usando SOLO i titoli/metadati
    che gli vengono passati.
  - mind NON vede né genera password nel recupero: la ricerca resta
    deterministica (search.py). Alle funzioni qui sotto non arrivano mai valori
    di password.
  - Se Ollama non è in esecuzione, l'app funziona con risposte da template.
  - Tutto resta in locale: Ollama gira sulla macchina dell'utente.
"""

from __future__ import annotations
import json
import urllib.request
import urllib.error

OLLAMA_URL = "http://127.0.0.1:11434"
DEFAULT_MODEL = "llama3.2:3b"

# Identità condivisa da tutte le risposte conversazionali.
_PERSONA = (
    "Ti chiami mind. Sei l'assistente di VaultMind, un password manager locale "
    "e offline. Parli italiano, con tono professionale, calmo e diretto. "
    "Rispondi breve (1-3 frasi), senza fronzoli. Non mostri né inventi MAI "
    "password o valori segreti: conosci solo i titoli delle voci. Se non sai, "
    "lo dici."
)


def available(timeout: float = 0.4) -> bool:
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/tags")
        with urllib.request.urlopen(req, timeout=timeout):
            return True
    except Exception:
        return False


def _generate(system: str, prompt: str, model: str, timeout: float,
              temperature: float = 0.3, num_predict: int = 120,
              force_json: bool = False):
    """Helper interno per chiamare Ollama /api/generate. Ritorna stringa o None."""
    payload = {
        "model": model,
        "system": system,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": temperature, "num_predict": num_predict},
    }
    if force_json:
        payload["format"] = "json"
    body = json.dumps(payload).encode("utf-8")
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/generate", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return (data.get("response") or "").strip() or None
    except Exception:
        return None


def _flatten_entries(parsed):
    """Riporta la risposta del modello alla forma attesa: [{title, fields, tags}].

    Serve perché llama3.2:3b, pur avendo `format: json`, spesso ignora la forma
    richiesta e restituisce una MAPPA titolo -> dati:
        [{"Gmail": {"fields": [...]}, "Amazon": {"fields": [...]}}]
    invece di una lista di voci. Senza questa conversione ogni elemento risulta
    privo di `fields`, viene scartato a valle e l'import finisce con zero voci.
    """
    def da_mappa(m: dict):
        out = []
        for k, v in m.items():
            if isinstance(v, dict) and ("fields" in v or "tags" in v):
                e = dict(v)
                e.setdefault("title", k)
                out.append(e)
        return out

    if isinstance(parsed, dict):
        if "fields" in parsed or "title" in parsed:
            return [parsed]
        return da_mappa(parsed)

    if isinstance(parsed, list):
        out = []
        for it in parsed:
            if not isinstance(it, dict):
                continue
            if "fields" in it or "title" in it:
                out.append(it)
            else:
                out.extend(da_mappa(it))
        return out

    return []


def extract_entries(text: str, model: str = DEFAULT_MODEL, timeout: float = 45.0):
    """
    Estrae credenziali strutturate da un blob di testo disordinato.
    L'LLM legge il testo (password incluse) per strutturarlo, ma resta in locale.
    Non inventa dati. Ritorna lista di {title, fields, tags} o None.
    """
    if not available():
        return None
    sys = (
        "Sei un parser di credenziali. Ricevi un testo disordinato e restituisci "
        "ESCLUSIVAMENTE un array JSON valido, senza testo prima o dopo, senza ``` . "
        "Ogni elemento ha i campi: title (stringa, il nome del servizio/account), "
        "fields (array di oggetti {label, value}, in italiano, con l'etichetta PIU' "
        "NATURALE per quel dato — es. Email, Password, Utente, PIN, PUC, ID, "
        "Telefono, Email di recupero, Codice di backup — NON forzare sempre "
        "Email/Password se il testo suggerisce altro), tags (array di stringhe in "
        "minuscolo). NON inventare valori: includi solo i campi che il testo "
        "fornisce esplicitamente. Raggruppa per servizio: se vedi un nome di "
        "servizio seguito da più righe di dati (es. CIE, poi ID, PIN, PUC, "
        "Telefono), sono TUTTI campi della stessa voce, non voci separate."
    )
    raw = _generate(sys, f"TESTO:\n{text}\n\nARRAY JSON:", model, timeout,
                    temperature=0.0, num_predict=1500, force_json=True)
    if not raw:
        return None
    try:
        raw = raw.replace("```json", "").replace("```", "").strip()
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            for key in ("entries", "credentials", "items", "data"):
                if isinstance(parsed.get(key), list):
                    parsed = parsed[key]
                    break
        voci = _flatten_entries(parsed)
        # None = "non ho una risposta usabile", così il chiamante ripiega
        # sull'euristica invece di proporre una lista vuota.
        return voci or None
    except Exception:
        return None


def phrase(intent: str, titles: list[str], kind: str = "single",
           model: str = DEFAULT_MODEL, timeout: float = 8.0) -> str | None:
    """
    Frase di accompagnamento al risultato di una ricerca.
    `titles` = SOLO i titoli trovati (mai le password). `kind`: single|ambiguous.
    Ritorna None se Ollama non risponde (il chiamante usa il template).
    """
    if not available():
        return None
    if kind == "ambiguous":
        task = (
            "Hai trovato più voci che potrebbero corrispondere. Invita l'utente a "
            "scegliere quale, elencando i titoli in modo naturale. Una frase."
        )
    else:
        task = (
            "Hai trovato la voce giusta. Annuncia che mostri i dati richiesti, "
            "in modo naturale e brevissimo. Non elencare i campi, ci pensa l'app."
        )
    prompt = (f"Richiesta dell'utente: \"{intent}\"\n"
              f"Titoli trovati: {', '.join(titles) or 'nessuno'}\n"
              f"Compito: {task}\nRisposta:")
    return _generate(_PERSONA, prompt, model, timeout, temperature=0.3, num_predict=70)


def chat(message: str, context: dict | None = None,
         model: str = DEFAULT_MODEL, timeout: float = 12.0) -> str | None:
    """
    Risposta conversazionale di mind a un messaggio che NON è un recupero
    credenziali (es. "come creo una password sicura?", "quante voci ho?",
    "come funziona il backup?"). `context` può contenere metadati non sensibili
    come {"num_entries": 12, "has_ollama": true}. Mai password.
    Ritorna None se Ollama non disponibile.
    """
    if not available():
        return None
    ctx = ""
    if context:
        bits = []
        if "num_entries" in context:
            bits.append(f"voci nel vault: {context['num_entries']}")
        if "sample_titles" in context and context["sample_titles"]:
            bits.append("alcuni titoli: " + ", ".join(context["sample_titles"][:8]))
        if bits:
            ctx = "Contesto (non sensibile): " + "; ".join(bits) + ".\n"
    sys = (
        _PERSONA + " Puoi dare consigli su sicurezza delle password, spiegare le "
        "funzioni di VaultMind (ricerca, aggiunta voci, 2FA/TOTP, import CSV, "
        "backup cifrato, generatore di password, impostazioni) e rispondere a "
        "domande sui metadati che ti vengono forniti. Per recuperare una "
        "credenziale specifica, ricorda all'utente di scrivere il nome del "
        "servizio nella barra."
    )
    return _generate(sys, f"{ctx}Messaggio: {message}\nRisposta di mind:",
                     model, timeout, temperature=0.4, num_predict=200)
