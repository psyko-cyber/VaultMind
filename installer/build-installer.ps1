# ==========================================================================
#  Costruisce VaultMind-Setup-X.Y.exe   (per NOI, non per chi riceve l'app)
#
#  Catena: run.bat produce dist\VaultMind.exe  ->  questo script lo
#  impacchetta nell'installer con Inno Setup. Se l'exe e' piu' vecchio del
#  codice si ferma: impacchettare una build stantia significa consegnare
#  un'app senza le ultime modifiche, e non se ne accorge nessuno.
#
#  NOTA: file in ASCII puro, come run.ps1 (PowerShell 5.1 + codepage ANSI).
# ==========================================================================
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$Win = Join-Path (Split-Path $PSScriptRoot -Parent) "VaultMind_Windows"
$EXE = Join-Path $Win "dist\VaultMind.exe"

function Err($m){ Write-Host "  [ERRORE] $m" -ForegroundColor Red }
function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }

# ------------------------------------------------ 1) l'exe c'e' ed e' fresco?
if (-not (Test-Path $EXE)) {
  Err "dist\VaultMind.exe non esiste. Lancia prima run.bat in VaultMind_Windows."
  exit 1
}
$exeTime = (Get-Item $EXE).LastWriteTime
$vecchi = @()
$sorgenti = @(Get-ChildItem (Join-Path $Win "app") -Recurse -File)
foreach ($f in @("vaultmind_launcher.py","requirements.txt")) {
  $p = Join-Path $Win $f
  if (Test-Path $p) { $sorgenti += Get-Item $p }
}
foreach ($f in $sorgenti) { if ($f.LastWriteTime -gt $exeTime) { $vecchi += $f.Name } }
if ($vecchi.Count -gt 0) {
  Err ("L'exe e' piu' VECCHIO di: " + (($vecchi | Select-Object -Unique) -join ", "))
  Write-Host "  Lancia run.bat (ricostruisce da solo), poi rilancia questo script." -ForegroundColor Yellow
  exit 1
}
Ok ("VaultMind.exe del " + $exeTime.ToString("dd/MM/yyyy HH:mm") + ", codice non piu' recente.")

# ------------------------------------------------ 2) trova Inno Setup (ISCC)
$iscc = $null
foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                 "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
                 "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe")) {
  if (Test-Path $p) { $iscc = $p; break }
}
if (-not $iscc) {
  Err "Inno Setup 6 non trovato. Installalo con:  winget install -e --id JRSoftware.InnoSetup"
  exit 1
}
Ok "Inno Setup: $iscc"

# ------------------------------------------------ 3) compila
Write-Host ""
& $iscc (Join-Path $PSScriptRoot "VaultMind.iss")
if ($LASTEXITCODE -ne 0) {
  Err "Compilazione fallita: leggi i messaggi qui sopra."
  exit 1
}

$setup = Get-ChildItem (Join-Path $PSScriptRoot "Output") -Filter "VaultMind-Setup-*.exe" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ""
Ok ("Creato: " + $setup.FullName + "  (" + [math]::Round($setup.Length / 1MB, 1) + " MB)")

# ------------------------------------- 4) copia nel pacchetto da consegnare
# Nome SENZA versione, come lo zip: "il nome del file non cambia mai, e'
# sempre la versione piu' recente". La versione la dice l'installer stesso
# (e "App installate" dopo). Copiare qui a ogni build evita il pacchetto
# stantio: quello che si consegna e' per costruzione l'ultimo compilato.
$pacchetto = Join-Path (Split-Path $PSScriptRoot -Parent) "PACCHETTO X INSTALLAZIONE EVERYWHERE"
if (Test-Path $pacchetto) {
  Copy-Item $setup.FullName (Join-Path $pacchetto "VaultMind-Setup.exe") -Force
  Ok "Copiato nel pacchetto: VaultMind-Setup.exe"
}
Write-Host "  Ricorda: la prova vera e' su una macchina PULITA (VM o secondo PC)." -ForegroundColor Yellow
