#!/usr/bin/env bash
# ============================================================================
#  VaultMind - avvio e setup automatico (macOS / Linux)
#  Installa/avvia Python deps, Ollama + modello, poi apre l'app.
#  L'app DEVE partire sempre: Ollama e' best-effort (non bloccanti).
# ============================================================================
set -e
cd "$(dirname "$0")"
MODEL="llama3.2:3b"
OS="$(uname -s)"

say(){ printf "\033[36m%s\033[0m\n" "$1"; }
ok(){ printf "  \033[32m[OK]\033[0m %s\n" "$1"; }
warn(){ printf "  \033[33m[!]\033[0m %s\n" "$1"; }
has(){ command -v "$1" >/dev/null 2>&1; }

echo ""
echo "============================================"
echo "  VaultMind - configurazione e avvio"
echo "============================================"
echo ""

# --------------------------------------------------------------- 0) HOMEBREW (solo Mac)
# Su macOS Homebrew e' il modo affidabile per installare Ollama/audio.
# Senza brew, Ollama non e' installabile in automatico. Quindi lo installiamo qui.
if [ "$OS" = "Darwin" ] && ! has brew; then
  say "0/5  Homebrew non trovato: lo installo (serve per Ollama)..."
  echo "    Potrebbe chiedere la password del Mac (e' l'installer ufficiale di Homebrew)."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || warn "Installazione Homebrew non riuscita."
  # aggiunge brew al PATH della sessione corrente (Apple Silicon e Intel)
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
  has brew && ok "Homebrew pronto." || warn "Homebrew assente: proseguo, ma Ollama potrebbe saltare."
fi

# ----------------------------------------------------------------- 1) PYTHON
say "1/5  Controllo Python..."
if ! has python3; then
  warn "Python 3 non trovato."
  if [ "$OS" = "Darwin" ] && has brew; then brew install python || true; fi
fi
if ! has python3; then
  warn "Installa Python 3 da https://www.python.org/downloads/ e riesegui ./run.sh"
  exit 1
fi
ok "$(python3 --version)"

# ------------------------------------------------------------- 2) DIPENDENZE
say "2/5  Ambiente Python e dipendenze (incl. audio/microfono)..."
[ -d ".venv" ] || python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
# Input vocale (Whisper locale): lo installiamo di default cosi' il microfono
# funziona subito. E' un po' piu' pesante (scarica un modello al primo uso),
# ma rientra nella filosofia "tutto pronto, zero passaggi manuali".
echo "    Installo il modulo audio (microfono)..."
pip install --quiet -r requirements-audio.txt || warn "Modulo audio non installato: il microfono restera' disattivato (l'app funziona comunque)."
ok "Dipendenze pronte."

# I passi extra non devono mai bloccare l'avvio
set +e

# ----------------------------------------------------------------- 3) OLLAMA
say "3/5  Ollama (chatbot intelligente in locale)..."
if ! has ollama; then
  warn "Ollama non installato. Lo installo ora (una sola volta)..."
  if [ "$OS" = "Darwin" ]; then
    if has brew; then
      brew install --cask ollama || warn "brew install ollama non riuscito."
    fi
    # se brew manca o fallisce: scarico l'app ufficiale e la installo
    if ! has ollama; then
      echo "    Scarico l'app ufficiale di Ollama per Mac..."
      if curl -fsSL "https://ollama.com/download/Ollama-darwin.zip" -o /tmp/ollama.zip 2>/dev/null; then
        unzip -oq /tmp/ollama.zip -d /tmp/ollama_app 2>/dev/null
        APP="$(find /tmp/ollama_app -maxdepth 2 -name 'Ollama.app' | head -1)"
        if [ -n "$APP" ]; then
          cp -R "$APP" /Applications/ 2>/dev/null && open -a Ollama 2>/dev/null && sleep 5
          # il binario CLI vive dentro l'app
          export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
        fi
      fi
    fi
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
fi
if has ollama; then
  if ! ollama list >/dev/null 2>&1; then
    echo "    Avvio il servizio Ollama..."
    (ollama serve >/dev/null 2>&1 &) ; sleep 3
  fi
  if ollama list 2>/dev/null | grep -q "$MODEL"; then
    ok "Modello $MODEL gia' presente."
  else
    echo "    Scarico il modello $MODEL (~1.9 GB, solo la prima volta)..."
    if ollama pull "$MODEL"; then ok "Modello pronto."; else warn "Download modello non riuscito: modalita' base."; fi
  fi
else
  warn "Ollama non disponibile: VaultMind funziona comunque (ricerca locale senza chatbot avanzato)."
fi

set -e
# ------------------------------------------------------------------ 5) AVVIO
say "4/5  Avvio VaultMind..."
echo ""
echo "  Si aprira' una finestra dell'app (o il browser su http://127.0.0.1:8731)"
echo "  Per chiudere: chiudi la finestra, oppure torna qui e premi CTRL+C"
echo ""
python main.py
