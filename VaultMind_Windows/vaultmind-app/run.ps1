# ============================================================================
#  VaultMind - avvio e setup automatico (Windows)
#  Installa/avvia: Python deps, Ollama + modello. Poi apre l'app.
#  Filosofia: l'app DEVE partire sempre. Ogni componente extra (Ollama)
#  e' best-effort: se qualcosa fallisce, VaultMind parte lo stesso.
# ============================================================================
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$MODEL = "llama3.2:3b"

function Say($m){ Write-Host $m -ForegroundColor Cyan }
function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!] $m" -ForegroundColor Yellow }
function Has($cmd){ return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Write-Host ""
Write-Host "============================================" -ForegroundColor White
Write-Host "  VaultMind - configurazione e avvio" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------- 1) PYTHON
Say "1/4  Controllo Python..."
if (-not (Has "python")) {
  Warn "Python non trovato. Provo a installarlo con winget..."
  if (Has "winget") {
    try { winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements } catch { }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
  }
}
if (-not (Has "python")) {
  Warn "Non riesco a installare Python in automatico."
  Write-Host "    Scaricalo da https://www.python.org/downloads/  (spunta 'Add python.exe to PATH')," -ForegroundColor Yellow
  Write-Host "    poi riapri run.bat." -ForegroundColor Yellow
  Start-Process "https://www.python.org/downloads/"
  Read-Host "Premi INVIO per uscire"
  exit 1
}
Ok ("Python " + (python --version 2>&1))

# ---------------------------------------------------------- 2) DIPENDENZE
Say "2/4  Ambiente Python e dipendenze (incl. audio/microfono)..."
if (-not (Test-Path ".venv")) { python -m venv .venv }
& ".\.venv\Scripts\Activate.ps1"
python -m pip install --upgrade pip --quiet
python -m pip install -r requirements.txt --quiet
# Input vocale (Whisper locale): installato di default cosi' il microfono
# funziona subito. Se fallisce, l'app parte comunque senza voce.
Write-Host "    Installo il modulo audio (microfono)..." -ForegroundColor Gray
try { python -m pip install -r requirements-audio.txt --quiet } catch { Warn "Modulo audio non installato: il microfono restera' disattivato (l'app funziona comunque)." }
Ok "Dipendenze pronte."

# -------------------------------------------------------------- 3) OLLAMA
Say "3/4  Ollama (chatbot intelligente in locale)..."
if (-not (Has "ollama")) {
  Warn "Ollama non installato. Lo installo ora (una sola volta)..."
  $installed = $false
  if (Has "winget") {
    try { winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements; $installed = $true } catch { }
  }
  if (-not $installed) {
    try {
      $tmp = Join-Path $env:TEMP "OllamaSetup.exe"
      Write-Host "    Scarico l'installer di Ollama..." -ForegroundColor Gray
      Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $tmp
      Write-Host "    Avvio l'installer (segui i passaggi: Next -> Install)..." -ForegroundColor Gray
      Start-Process -FilePath $tmp -ArgumentList "/SILENT" -Wait
      $installed = $true
    } catch { Warn "Download Ollama non riuscito (sei offline?)." }
  }
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
if (Has "ollama") {
  # assicura che il demone risponda
  $up = $false
  try { ollama list *> $null; $up = $true } catch { }
  if (-not $up) {
    Write-Host "    Avvio il servizio Ollama..." -ForegroundColor Gray
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
  }
  # scarica il modello se manca
  $have = $false
  try { if ((ollama list 2>$null) -match [regex]::Escape($MODEL)) { $have = $true } } catch { }
  if ($have) { Ok "Modello $MODEL gia' presente." }
  else {
    Write-Host "    Scarico il modello $MODEL (~1.9 GB, solo la prima volta)..." -ForegroundColor Gray
    try { ollama pull $MODEL; Ok "Modello pronto." } catch { Warn "Download modello non riuscito: l'app usera' la modalita' base." }
  }
} else {
  Warn "Ollama non disponibile: VaultMind funzionera' comunque (ricerca locale senza chatbot avanzato)."
}

# --------------------------------------------------------------- 5) AVVIO
Say "4/4  Avvio VaultMind..."
Write-Host ""
Write-Host "  Si aprira' una finestra dell'app (o il browser su http://127.0.0.1:8731)" -ForegroundColor White
Write-Host "  Per chiudere: chiudi la finestra, oppure torna qui e premi CTRL+C" -ForegroundColor Gray
Write-Host ""
python main.py

Write-Host ""
Write-Host "VaultMind si e' chiuso." -ForegroundColor White
Read-Host "Premi INVIO per uscire"
