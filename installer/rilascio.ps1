# ==========================================================================
#  VaultMind — rilascio: dal codice ai consegnabili (per NOI, non per l'utente)
#
#  Catena completa:
#     run.bat  ->  dist\VaultMind.exe        (build dell'app, a parte)
#     questo   ->  VaultMind-Setup.exe       (installer con procedura guidata)
#              ->  VaultMind-Windows.zip     (sorgente, ripiego)
#              ->  VaultMind-Estensione.zip  (estensione browser)
#              ->  release su GitHub          (solo con -Release)
#
#  Tutto finisce in "PACCHETTO X INSTALLAZIONE EVERYWHERE\": una copia sola,
#  nessun duplicato da tenere in sincrono.
#
#  Uso:
#     .\installer\rilascio.ps1              # solo i consegbabili locali
#     .\installer\rilascio.ps1 -Release     # e aggiorna la release su GitHub
#
#  NOTA: file in ASCII puro come run.ps1 — PowerShell 5.1 legge i .ps1 senza
#  BOM con la codepage ANSI e gli accenti uscirebbero corrotti.
# ==========================================================================
param(
  [switch]$Release,
  [string]$Tag = "v6.7"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$REPO_DIR = Split-Path $PSScriptRoot -Parent
$WIN      = Join-Path $REPO_DIR "VaultMind_Windows"
$EXE      = Join-Path $WIN "dist\VaultMind.exe"
$PACCHETTO = Join-Path $REPO_DIR "PACCHETTO X INSTALLAZIONE EVERYWHERE"
$GH_REPO  = "psyko-cyber/VaultMind"

function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Err($m){ Write-Host "  [ERRORE] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }
function Fase($m){ Write-Host ""; Write-Host $m -ForegroundColor Cyan }

Set-Location $REPO_DIR

# ============================ 1) l'exe c'e' ed e' fresco? =================
# Impacchettare una build stantia significa consegnare un'app senza le ultime
# modifiche, e non se ne accorge nessuno finche' non lo segnala chi testa.
Fase "1/4  Controllo della build"
if (-not (Test-Path $EXE)) {
  Err "dist\VaultMind.exe non esiste. Lancia prima run.bat in VaultMind_Windows."
  exit 1
}
$exeTime = (Get-Item $EXE).LastWriteTime
$sorgenti = @(Get-ChildItem (Join-Path $WIN "app") -Recurse -File)
foreach ($f in @("vaultmind_launcher.py","requirements.txt")) {
  $p = Join-Path $WIN $f
  if (Test-Path $p) { $sorgenti += Get-Item $p }
}
$vecchi = @($sorgenti | Where-Object { $_.LastWriteTime -gt $exeTime } | Select-Object -ExpandProperty Name -Unique)
if ($vecchi.Count -gt 0) {
  Err ("L'exe e' piu' VECCHIO di: " + ($vecchi -join ", "))
  Info "Lancia run.bat (ricostruisce da solo), poi rilancia questo script."
  exit 1
}
$commit = (git rev-parse --short HEAD).Trim()
Ok ("VaultMind.exe del " + $exeTime.ToString("dd/MM/yyyy HH:mm") + " - codice non piu' recente (commit $commit)")

# ============================ 2) installer ================================
Fase "2/4  Installer con procedura guidata"
$iscc = $null
foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                 "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
                 "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe")) {
  if (Test-Path $p) { $iscc = $p; break }
}
if (-not $iscc) {
  Err "Inno Setup 6 non trovato:  winget install -e --id JRSoftware.InnoSetup"
  exit 1
}
& $iscc /Q (Join-Path $PSScriptRoot "VaultMind.iss")
if ($LASTEXITCODE -ne 0) { Err "Compilazione dell'installer fallita."; exit 1 }
$setup = Get-Item (Join-Path $PACCHETTO "VaultMind-Setup.exe")
Ok ("VaultMind-Setup.exe  " + [math]::Round($setup.Length / 1MB, 1) + " MB")

# --- lo stesso installer dentro uno zip, con le istruzioni ---
# Serve per mandarlo ai soci: WhatsApp, molte webmail e i proxy aziendali
# rifiutano gli allegati .exe, uno .zip passa. Dentro va anche il file di
# istruzioni: un solo allegato con tutto quello che serve a chi lo riceve.
$stageZip = Join-Path $env:TEMP "vm_setup_zip"
if (Test-Path $stageZip) { Remove-Item $stageZip -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Force $stageZip | Out-Null
Copy-Item $setup.FullName $stageZip
Copy-Item (Join-Path $PACCHETTO "INIZIA DA QUI (per chi riceve).txt") $stageZip
$zipSetup = Join-Path $PACCHETTO "VaultMind-Setup.zip"
if (Test-Path $zipSetup) { Remove-Item $zipSetup -Force }
# -Path con \* : lo zip contiene i file, non una cartella che li avvolge
Compress-Archive -Path (Join-Path $stageZip "*") -DestinationPath $zipSetup
Remove-Item $stageZip -Recurse -Force -Confirm:$false
Ok ("VaultMind-Setup.zip  " + [math]::Round((Get-Item $zipSetup).Length / 1MB, 1) + " MB  (installer + istruzioni, da mandare a mano)")

# ============================ 3) i due zip ================================
Fase "3/4  Pacchetti zip"
$stage = Join-Path $env:TEMP "vm_stage"

# --- sorgente (il ripiego: chi preferisce costruirsi l'app con run.bat) ---
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -Confirm:$false }
$root = Join-Path $stage "VaultMind"
New-Item -ItemType Directory -Force "$root\app\web" | Out-Null
foreach ($f in @("run.bat","run.ps1","INIZIA DA QUI.txt","requirements.txt",
                 "requirements-audio.txt","VaultMind.ico","vaultmind_launcher.py")) {
  Copy-Item (Join-Path $WIN $f) $root
}
Copy-Item (Join-Path $WIN "app\*.py") "$root\app"
Copy-Item (Join-Path $WIN "app\web\*") "$root\app\web"

# Controllo NON negoziabile: un vault non deve mai finire in un pacchetto che
# si spedisce. Meglio fermare il rilascio che consegnare credenziali.
$sporchi = @(Get-ChildItem $root -Recurse -Include "vault.json","settings.json","*.log")
if ($sporchi.Count -gt 0) {
  Err "DATI UTENTE nello staging: rilascio interrotto."
  $sporchi | ForEach-Object { Info $_.FullName }
  exit 1
}
$ver = @"
VaultMind - versione del pacchetto
==================================
Versione app : $Tag
Build        : $(Get-Date -Format "dd/MM/yyyy HH:mm")
Commit       : $commit

Se segnali un problema, cita queste righe: aiutano a capire
quale build stai usando.
"@
[IO.File]::WriteAllText((Join-Path $root "VERSIONE.txt"), $ver)
$zipSrc = Join-Path $PACCHETTO "VaultMind-Windows.zip"
if (Test-Path $zipSrc) { Remove-Item $zipSrc -Force }
Compress-Archive -Path $root -DestinationPath $zipSrc
Ok ("VaultMind-Windows.zip  " + [math]::Round((Get-Item $zipSrc).Length / 1KB) + " KB")

# --- estensione browser ---
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -Confirm:$false }
$eroot = Join-Path $stage "VaultMind-Estensione"
New-Item -ItemType Directory -Force $eroot | Out-Null
Copy-Item (Join-Path $REPO_DIR "extension\*") $eroot -Recurse
[IO.File]::WriteAllText((Join-Path $eroot "COME SI INSTALLA.txt"), @"
Estensione VaultMind per Chrome / Edge / Brave
==============================================
1. Estrai questa cartella dove vuoi tenerla (non cancellarla dopo).
2. Nel browser apri  chrome://extensions  e attiva "Modalita' sviluppatore".
3. "Carica estensione non pacchettizzata" -> scegli questa cartella.
4. Apri VaultMind e sblocca il vault.
5. Menu -> Impostazioni -> Estensione browser -> Associa...
6. Clicca l'icona VaultMind nella barra del browser e scrivi il codice.

L'estensione legge dal vault SOLO quando l'app e' aperta e sbloccata.
Non salva nessuna credenziale nel browser ed e' in sola lettura.
Versione app richiesta: $Tag o successiva (build $(Get-Date -Format "dd/MM/yyyy")).
"@)
$zipExt = Join-Path $PACCHETTO "VaultMind-Estensione.zip"
if (Test-Path $zipExt) { Remove-Item $zipExt -Force }
Compress-Archive -Path $eroot -DestinationPath $zipExt
Ok ("VaultMind-Estensione.zip  " + [math]::Round((Get-Item $zipExt).Length / 1KB) + " KB")
Remove-Item $stage -Recurse -Force -Confirm:$false

# ============================ 4) release su GitHub ========================
if (-not $Release) {
  Fase "4/4  Release su GitHub: SALTATA"
  Info "Consegnabili pronti in: PACCHETTO X INSTALLAZIONE EVERYWHERE\"
  Info "Per pubblicarli:  .\installer\rilascio.ps1 -Release"
  Write-Host ""
  Info "Ricorda: la prova che conta e' su una macchina PULITA (VM o secondo PC)."
  exit 0
}

Fase "4/4  Aggiornamento della release su GitHub"
# Il token esce dal credential helper di git (lo stesso usato da push) e resta
# in una variabile: mai stampato, mai scritto su disco.
# Lo stdin passa da un file: il pipe di PowerShell 5.1 arriva a git con
# l'encoding sbagliato ("refusing to work with credential missing protocol").
$tmpIn = Join-Path $env:TEMP "vm_cred_query.txt"
[IO.File]::WriteAllText($tmpIn, "protocol=https`nhost=github.com`n`n")
$cred = cmd /c "git credential fill < `"$tmpIn`""
Remove-Item $tmpIn -Force
$token = ($cred | Where-Object { $_ -like "password=*" }) -replace "^password=", ""
if (-not $token) { Err "Nessuna credenziale git per github.com."; exit 1 }
$H  = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }
$HU = @{ Authorization = "token $token" }

try {
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$GH_REPO/releases/tags/$Tag" -Headers $H
} catch {
  Err "Release $Tag non trovata su GitHub. Creala una volta a mano, poi questo script la aggiorna."
  exit 1
}
Info $rel.html_url

$nomi = @("VaultMind-Setup.exe", "VaultMind-Windows.zip", "VaultMind-Estensione.zip")
foreach ($a in $rel.assets) {
  if ($nomi -contains $a.name) {
    Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$GH_REPO/releases/assets/$($a.id)" -Headers $H | Out-Null
    Info ("rimosso il vecchio " + $a.name)
  }
}
foreach ($n in $nomi) {
  $f = Join-Path $PACCHETTO $n
  $tipo = if ($n.EndsWith(".exe")) { "application/octet-stream" } else { "application/zip" }
  Info ("carico $n (" + [math]::Round((Get-Item $f).Length / 1MB, 1) + " MB)...")
  $uri = "https://uploads.github.com/repos/$GH_REPO/releases/" + $rel.id + "/assets?name=$n"
  Invoke-RestMethod -Method Post -Uri $uri -Headers $HU -ContentType $tipo -InFile $f -TimeoutSec 900 | Out-Null
  Ok $n
}
Write-Host ""
Ok ("Release aggiornata: " + $rel.html_url)
Info "La descrizione della release si aggiorna a mano: dice cosa cambia per chi testa."
