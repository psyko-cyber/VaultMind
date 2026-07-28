# ============================================================================
#  VaultMind - avvio e setup automatico (Windows)
#  Installa/avvia: Python deps, Ollama + modello. Poi apre l'app.
#  Filosofia: l'app DEVE partire sempre. Ogni componente extra (Ollama)
#  e' best-effort: se qualcosa fallisce, VaultMind parte lo stesso.
#
#  NOTA: questo file resta in ASCII puro. PowerShell 5.1 legge i .ps1 senza BOM
#  con la codepage ANSI: accenti e caratteri di blocco uscirebbero corrotti.
# ============================================================================
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$MODEL = "llama3.2:3b"
$STEPS = 5

function Say($m){ Write-Host $m -ForegroundColor Cyan }
function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!] $m" -ForegroundColor Yellow }
function Has($cmd){ return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------- BARRE DI STATO
# Il primo avvio scarica centinaia di MB: senza riscontro visivo sembra
# bloccato. Una barra sulla stessa riga (`r) + la barra nativa di PowerShell.
$script:PHASE = "preparazione"

function Bar($cur, $tot, $label){
  if($tot -le 0){ $tot = 1 }
  $w = 22
  $frac = $cur / $tot
  if($frac -gt 1){ $frac = 1 }
  if($frac -lt 0){ $frac = 0 }
  $pct  = [int]($frac * 100)
  $fill = [int]($frac * $w)
  $bar  = ("#" * $fill).PadRight($w, "-")
  $lbl  = [string]$label
  if($lbl.Length -gt 30){ $lbl = $lbl.Substring(0, 30) }
  Write-Host ("`r  [{0}] {1,3}%  {2}" -f $bar, $pct, $lbl.PadRight(30)) -NoNewline -ForegroundColor Cyan
  Write-Progress -Id 1 -Activity ("VaultMind - " + $script:PHASE) -Status $lbl -PercentComplete $pct
}
function BarDone(){ Write-Host "" }

function Step($n, $title){
  $script:PHASE = $title
  Write-Host ""
  Say ("$n/$STEPS  $title")
}

# ------------------------------------------------------- RILEVAMENTO PYTHON
# Windows 11 mette in PATH un finto "python.exe" che apre il Microsoft Store:
# Get-Command lo trova, ma non esegue niente (esce con codice 49). Va quindi
# provato davvero, e in caso si ripiega sul launcher "py -3".
function PyOut($exe, $argLine){
  $out = Join-Path $env:TEMP "vaultmind_py.txt"
  $err = Join-Path $env:TEMP "vaultmind_py.err"
  try {
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $out -RedirectStandardError $err
    if ($p.ExitCode -ne 0) { return $null }
    if (Test-Path $out) { return (Get-Content $out -Raw) }
    return ""
  } catch { return $null }
}

function FindPython(){
  $probe = '-c "import sys; print(sys.executable)"'
  if (Has "python") {
    $r = PyOut "python" $probe
    if ($r) { return $r.Trim() }
  }
  if (Has "py") {
    $r = PyOut "py" ("-3 " + $probe)
    if ($r) { return $r.Trim() }
  }
  return $null
}

# Legge un requirements.txt scartando commenti e righe vuote.
function ReqList($file){
  if(-not (Test-Path $file)){ return @() }
  return @(Get-Content $file | ForEach-Object { $_.Trim() } |
           Where-Object { $_ -ne "" -and -not $_.StartsWith("#") })
}

# Installa i pacchetti UNO ALLA VOLTA: e' l'unico modo per sapere a che punto
# siamo. Ritorna la lista di quelli falliti (l'avvio prosegue comunque).
function InstallList($file){
  $pkgs = ReqList $file
  if($pkgs.Count -eq 0){ return @() }
  $failed = @()
  for($i = 0; $i -lt $pkgs.Count; $i++){
    $spec = $pkgs[$i]
    $name = ($spec -split '[<>=!~\[]')[0]
    Bar $i $pkgs.Count ("$name  (" + ($i + 1) + "/" + $pkgs.Count + ")")
    & $PY -m pip install $spec --quiet --disable-pip-version-check
    if($LASTEXITCODE -ne 0){ $failed += $name }
  }
  Bar $pkgs.Count $pkgs.Count "completato"
  BarDone
  return $failed
}

Write-Host ""
Write-Host "============================================" -ForegroundColor White
Write-Host "  VaultMind - configurazione e avvio" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

# ---------------------------------------------------------------- 1) PYTHON
Step 1 "Controllo Python"
Bar 0 1 "cerco un Python utilizzabile"
$PY = FindPython
if (-not $PY) {
  BarDone
  Warn "Python non trovato. Provo a installarlo con winget..."
  if (Has "winget") {
    try { winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements } catch { }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
  }
  $PY = FindPython
} else {
  Bar 1 1 "trovato"
  BarDone
}
if (-not $PY) {
  Warn "Non riesco a installare Python in automatico."
  Write-Host "    Scaricalo da https://www.python.org/downloads/  (spunta 'Add python.exe to PATH')," -ForegroundColor Yellow
  Write-Host "    poi riapri run.bat." -ForegroundColor Yellow
  Start-Process "https://www.python.org/downloads/"
  Read-Host "Premi INVIO per uscire"
  exit 1
}
$ver = PyOut $PY "--version"
if (-not $ver) { $ver = "" }
Ok ($ver.Trim() + "  ->  " + $PY)

# ------------------------------------------------------ 2) AMBIENTE PYTHON
Step 2 "Ambiente Python isolato (.venv)"
if (-not (Test-Path ".venv")) {
  Bar 0 2 "creo l'ambiente (una sola volta)"
  & $PY -m venv .venv
  Bar 1 2 "attivo l'ambiente"
} else {
  Bar 1 2 "ambiente gia' presente"
}
& ".\.venv\Scripts\Activate.ps1"
# Da qui in poi si usa l'interprete DEL venv per path esplicito: non dipende
# dall'ordine del PATH (dove puo' esserci ancora l'alias dello Store).
$venvPy = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (Test-Path $venvPy) { $PY = $venvPy }
& $PY -m pip install --upgrade pip --quiet --disable-pip-version-check
Bar 2 2 "pronto"
BarDone
Ok "Ambiente pronto."

# ---------------------------------------------------------- 3) DIPENDENZE
Step 3 "Dipendenze dell'app"
Write-Host "    Alla prima esecuzione vengono scaricate: puo' richiedere qualche minuto." -ForegroundColor Gray
$failed = InstallList "requirements.txt"
if ($failed.Count -gt 0) {
  Warn ("Pacchetti non installati: " + ($failed -join ", ") + ". L'app potrebbe non partire: controlla la connessione.")
} else {
  Ok "Dipendenze pronte."
}

# ------------------------------------------------------------- 4) AUDIO
# Input vocale (Whisper locale): installato di default cosi' il microfono
# funziona subito. Se fallisce, l'app parte comunque senza voce.
Step 4 "Modulo audio (dettatura, opzionale)"
Write-Host "    E' il pacchetto piu' pesante: se la barra sembra ferma, sta scaricando." -ForegroundColor Gray
$failedAudio = InstallList "requirements-audio.txt"
if ($failedAudio.Count -gt 0) {
  Warn "Modulo audio non installato: il microfono restera' disattivato (l'app funziona comunque)."
} else {
  Ok "Modulo audio pronto."
}

# -------------------------------------------------------------- 5) OLLAMA
Step 5 "Ollama (assistente in locale, opzionale)"
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
    Write-Host "    Scarico il modello $MODEL (~1.9 GB, solo la prima volta)." -ForegroundColor Gray
    Write-Host "    La barra qui sotto e' quella di Ollama:" -ForegroundColor Gray
    try { ollama pull $MODEL; Ok "Modello pronto." } catch { Warn "Download modello non riuscito: l'app usera' la modalita' base." }
  }
} else {
  Warn "Ollama non disponibile: VaultMind funzionera' comunque (ricerca locale senza chatbot avanzato)."
}

# --------------------------------------------------------------- AVVIO
Write-Progress -Id 1 -Activity "VaultMind" -Completed
Write-Host ""
Write-Host "  Tutto pronto. Avvio VaultMind..." -ForegroundColor White
Write-Host ""
Write-Host "  Si aprira' una finestra dell'app (o il browser su http://127.0.0.1:8731)" -ForegroundColor White
Write-Host "  Per chiudere: chiudi la finestra, oppure torna qui e premi CTRL+C" -ForegroundColor Gray
Write-Host ""
& $PY main.py

Write-Host ""
Write-Host "VaultMind si e' chiuso." -ForegroundColor White
Read-Host "Premi INVIO per uscire"
