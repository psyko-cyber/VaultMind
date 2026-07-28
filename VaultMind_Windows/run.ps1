# ============================================================================
#  VaultMind - unico avvio (Windows)
#
#  PRIMA VOLTA : prepara tutto, costruisce VaultMind.exe e mette l'icona sul
#                Desktop. Alcuni minuti.
#  DA LI' IN POI: apre l'applicazione e chiude subito il terminale.
#
#  Ricostruisce da solo l'exe se il codice e' stato modificato: altrimenti si
#  continuerebbe ad aprire una versione vecchia senza accorgersene.
#
#  Filosofia: l'app DEVE partire sempre. I componenti extra (audio, Ollama)
#  sono best-effort: se falliscono, VaultMind parte lo stesso.
#
#  NOTA: file in ASCII puro. PowerShell 5.1 legge i .ps1 senza BOM con la
#  codepage ANSI: accenti e caratteri di blocco uscirebbero corrotti.
# ============================================================================
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$MODEL = "llama3.2:3b"
$EXE   = Join-Path $PSScriptRoot "dist\VaultMind.exe"
$script:TOT_STEPS = 7

# ------------------------------------------------------------------ OUTPUT
function Say($m){ Write-Host $m -ForegroundColor Cyan }
function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!] $m" -ForegroundColor Yellow }
function Err($m){ Write-Host "  [ERRORE] $m" -ForegroundColor Red }
function Has($cmd){ return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Il primo avvio scarica centinaia di MB: senza riscontro visivo sembra
# bloccato. Si usa SOLO una barra di testo sulla stessa riga (`r): la barra
# nativa Write-Progress e' quella banda blu che resta incollata in cima alla
# finestra e sporca l'output, quindi niente.
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
}
function BarDone(){ Write-Host "" }
function Step($n, $title){
  $script:PHASE = $title
  Write-Host ""
  Say ("$n/$($script:TOT_STEPS)  $title")
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
  if (Has "python") { $r = PyOut "python" $probe; if ($r) { return $r.Trim() } }
  if (Has "py")     { $r = PyOut "py" ("-3 " + $probe); if ($r) { return $r.Trim() } }
  return $null
}
# Fra i moduli chiesti ritorna solo quelli davvero importabili: un --collect-all
# su un pacchetto assente fa fallire PyInstaller con un errore incomprensibile.
function AvailableModules($py, $mods){
  $lst = "'" + ($mods -join "','") + "'"
  $probe = '-c "import importlib.util as u; mods=[' + $lst + ']; print('' ''.join(m for m in mods if u.find_spec(m)))"'
  $out = PyOut $py $probe
  if (-not $out) { return @() }
  return @($out.Trim() -split '\s+' | Where-Object { $_ })
}

# ------------------------------------------------------------- DIPENDENZE
function ReqList($file){
  if(-not (Test-Path $file)){ return @() }
  return @(Get-Content $file | ForEach-Object { $_.Trim() } |
           Where-Object { $_ -ne "" -and -not $_.StartsWith("#") })
}
# Installa un pacchetto alla volta: e' l'unico modo per mostrare a che punto
# siamo. Ritorna la lista dei falliti (si prosegue comunque).
function InstallList($py, $file){
  $pkgs = ReqList $file
  if($pkgs.Count -eq 0){ return @() }
  $failed = @()
  for($i = 0; $i -lt $pkgs.Count; $i++){
    $spec = $pkgs[$i]
    $name = ($spec -split '[<>=!~\[]')[0]
    Bar $i $pkgs.Count ("$name  (" + ($i + 1) + "/" + $pkgs.Count + ")")
    & $py -m pip install $spec --quiet --disable-pip-version-check
    if($LASTEXITCODE -ne 0){ $failed += $name }
  }
  Bar $pkgs.Count $pkgs.Count "completato"
  BarDone
  return $failed
}

# --------------------------------------------------------------- SUPPORTO
function EnsureShortcut(){
  try {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "VaultMind.lnk"
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath       = $EXE
    $s.WorkingDirectory = (Split-Path $EXE -Parent)
    $s.IconLocation     = (Join-Path $PSScriptRoot "VaultMind.ico")
    $s.Description      = "VaultMind - gestore di password locale"
    $s.Save()
    return $true
  } catch { return $false }
}

# L'exe va rifatto se il codice e' piu' recente: senza questo controllo, dopo
# una modifica si continuerebbe ad aprire la build vecchia senza capire perche'.
function NeedsBuild(){
  if (-not (Test-Path $EXE)) { return $true }
  $exeTime = (Get-Item $EXE).LastWriteTime
  $sorgenti = @()
  $sorgenti += Get-ChildItem (Join-Path $PSScriptRoot "app") -Recurse -File -ErrorAction SilentlyContinue
  foreach ($f in @("vaultmind_launcher.py","requirements.txt")) {
    $p = Join-Path $PSScriptRoot $f
    if (Test-Path $p) { $sorgenti += Get-Item $p }
  }
  foreach ($f in $sorgenti) { if ($f.LastWriteTime -gt $exeTime) { return $true } }
  return $false
}

# Ollama e' un processo a parte: se e' installato ma spento, l'assistente in
# chat non risponderebbe. Avviarlo costa nulla, quindi si fa sempre.
function StartOllamaIfPresent(){
  if (-not (Has "ollama")) { return }
  try { ollama list *> $null; return } catch { }
  try { Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden } catch { }
}

# ==========================================================================
#  PERCORSO VELOCE: l'applicazione c'e' gia' ed e' aggiornata
# ==========================================================================
if (-not (NeedsBuild)) {
  Write-Host ""
  Write-Host "  Avvio VaultMind..." -ForegroundColor White
  EnsureShortcut | Out-Null
  StartOllamaIfPresent
  Start-Process -FilePath $EXE
  Start-Sleep -Milliseconds 800
  exit 0
}

# ==========================================================================
#  PRIMA VOLTA (o codice modificato): si costruisce l'applicazione
# ==========================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  VaultMind - preparazione dell'applicazione" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White
if (Test-Path $EXE) {
  Write-Host "  Il codice e' cambiato: ricostruisco l'applicazione." -ForegroundColor Gray
} else {
  Write-Host "  Prima volta su questo computer: ci vogliono alcuni minuti." -ForegroundColor Gray
  Write-Host "  Da qui in poi VaultMind si aprira' dall'icona sul Desktop." -ForegroundColor Gray
}

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
} else { Bar 1 1 "trovato"; BarDone }
if (-not $PY) {
  Err "Python non disponibile."
  Write-Host "    Installalo da https://www.python.org/downloads/  (spunta 'Add python.exe to PATH')," -ForegroundColor Yellow
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
if (-not (Test-Path ".venv")) { Bar 0 2 "creo l'ambiente (una sola volta)"; & $PY -m venv .venv }
else { Bar 1 2 "ambiente gia' presente" }
$venvPy = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
  BarDone
  Err "Creazione dell'ambiente .venv fallita. Elimina la cartella .venv e riprova."
  Read-Host "Premi INVIO per uscire"
  exit 1
}
# da qui si usa l'interprete DEL venv per path esplicito: non dipende
# dall'ordine del PATH (dove puo' esserci ancora l'alias dello Store)
$PY = $venvPy
& $PY -m pip install --upgrade pip --quiet --disable-pip-version-check
Bar 2 2 "pronto"
BarDone
Ok "Ambiente pronto."

# ---------------------------------------------------------- 3) DIPENDENZE
Step 3 "Dipendenze dell'app"
Write-Host "    Vengono scaricate ora: puo' richiedere qualche minuto." -ForegroundColor Gray
$failed = InstallList $PY "requirements.txt"
if ($failed.Count -gt 0) { Warn ("Pacchetti non installati: " + ($failed -join ", ")) } else { Ok "Dipendenze pronte." }

# ------------------------------------------- 4) STRUMENTO DI BUILD + AUDIO
Step 4 "Componenti per creare l'applicazione"
Bar 0 2 "pyinstaller"
& $PY -m pip install pyinstaller --quiet --disable-pip-version-check
if ($LASTEXITCODE -ne 0) {
  BarDone
  Err "PyInstaller non si installa: senza non e' possibile creare l'applicazione."
  Read-Host "Premi INVIO per uscire"
  exit 1
}
Bar 1 2 "modulo audio (dettatura)"
Write-Host "" -NoNewline
& $PY -m pip install -r requirements-audio.txt --quiet --disable-pip-version-check
$audioOk = ($LASTEXITCODE -eq 0)
Bar 2 2 "pronto"
BarDone
if ($audioOk) { Ok "Componenti pronti (dettatura inclusa)." }
else { Warn "Modulo audio non installato: l'app funzionera' senza dettatura vocale." }

# --------------------------------------------------- 5) OLLAMA (OPZIONALE)
Step 5 "Assistente in locale (Ollama, opzionale)"
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
      Start-Process -FilePath $tmp -ArgumentList "/SILENT" -Wait
    } catch { Warn "Download Ollama non riuscito (sei offline?)." }
  }
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
if (Has "ollama") {
  StartOllamaIfPresent
  Start-Sleep -Seconds 2
  $have = $false
  try { if ((ollama list 2>$null) -match [regex]::Escape($MODEL)) { $have = $true } } catch { }
  if ($have) { Ok "Modello $MODEL gia' presente." }
  else {
    Write-Host "    Scarico il modello $MODEL (~1,9 GB, solo la prima volta)." -ForegroundColor Gray
    Write-Host "    La barra qui sotto e' quella di Ollama:" -ForegroundColor Gray
    try { ollama pull $MODEL; Ok "Modello pronto." } catch { Warn "Download non riuscito: l'app usera' la modalita' base." }
  }
} else {
  Warn "Ollama non disponibile: VaultMind funziona comunque (ricerca locale)."
}

# ------------------------------------------------------------- 6) BUILD
Step 6 "Creazione dell'applicazione"
$candidati = @("webview","fastapi","uvicorn","starlette","pydantic","pydantic_core",
               "cryptography","argon2","numpy","python_multipart",
               "faster_whisper","onnxruntime","ctranslate2","tokenizers")
$presenti = AvailableModules $PY $candidati
$assenti  = $candidati | Where-Object { $presenti -notcontains $_ }
$mancanti = @("fastapi","uvicorn","cryptography","argon2","numpy") | Where-Object { $presenti -notcontains $_ }
if ($mancanti) {
  Err ("Mancano dipendenze indispensabili: " + ($mancanti -join ", "))
  Write-Host "    Controlla la connessione e riapri run.bat." -ForegroundColor Yellow
  Read-Host "Premi INVIO per uscire"
  exit 1
}
if ($assenti) { Warn ("Non inclusi (non installati): " + ($assenti -join ", ")) }
Ok ("Moduli inclusi: " + $presenti.Count + ".")

foreach ($d in @("build","dist")) { if (Test-Path $d) { Remove-Item $d -Recurse -Force -Confirm:$false } }
if (Test-Path "VaultMind.spec") { Remove-Item "VaultMind.spec" -Force -Confirm:$false }

$piArgs = @("--noconfirm","--onefile","--windowed",
            "--name","VaultMind",
            "--icon","VaultMind.ico",
            "--add-data","app;app",
            "--add-data","requirements.txt;.")
foreach ($m in $presenti) { $piArgs += "--collect-all"; $piArgs += $m }
foreach ($h in @("uvicorn.logging","uvicorn.loops.auto","uvicorn.protocols.http.auto",
                 "uvicorn.protocols.websockets.auto","uvicorn.lifespan.on",
                 "app.server","app.crypto_store","app.search","app.embedding","app.llm",
                 "app.import_parse","app.import_csv","app.totp","app.transcribe")) {
  $piArgs += "--hidden-import"; $piArgs += $h
}
$piArgs += "vaultmind_launcher.py"

Write-Host "    Alcuni minuti. Sotto scorre l'output dello strumento di build:" -ForegroundColor Gray
Write-Host ""
& $PY -m PyInstaller @piArgs

if (-not (Test-Path $EXE)) {
  Write-Host ""
  Err "L'applicazione non e' stata creata. Leggi i messaggi qui sopra."
  Read-Host "Premi INVIO per uscire"
  exit 1
}
Ok ("VaultMind.exe creato (" + [math]::Round((Get-Item $EXE).Length / 1MB, 1) + " MB)")

# --------------------------------------------------- 7) ICONA SUL DESKTOP
Step 7 "Icona sul Desktop"
if (EnsureShortcut) { Bar 1 1 "creata"; BarDone; Ok "Icona 'VaultMind' sul Desktop." }
else { BarDone; Warn "Icona non creata. Avvia da: dist\VaultMind.exe" }

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  FATTO. VaultMind e' sul Desktop." -ForegroundColor Green
Write-Host "  Da adesso aprilo da li': niente piu' terminale." -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Avvio VaultMind..." -ForegroundColor White
Start-Process -FilePath $EXE
Start-Sleep -Seconds 2
