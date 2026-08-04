# ==========================================================================
#  VaultMind mobile — costruisce l'APK per Android
#
#  Unico punto d'ingresso, come run.bat per l'app Windows: prepara l'ambiente
#  e costruisce. Serve perche' su questa macchina l'ambiente ha due trappole
#  che fanno fallire `flutter build` con errori che non dicono la verita'.
#
#  Uso:
#     .\costruisci.ps1            # APK di debug, per provare
#     .\costruisci.ps1 -Release   # APK da consegnare
#     .\costruisci.ps1 -Test      # solo i test Dart (veloce, niente APK)
#
#  NOTA: file in ASCII puro come gli altri .ps1 del progetto (PowerShell 5.1
#  legge i .ps1 senza BOM con la codepage ANSI e gli accenti si corrompono).
# ==========================================================================
param(
  [switch]$Release,
  [switch]$Test
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Err($m){ Write-Host "  [ERRORE] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }
function Fase($m){ Write-Host ""; Write-Host $m -ForegroundColor Cyan }

# ------------------------------------------------------------- 1) AMBIENTE
Fase "Ambiente"

$jdk = Get-ChildItem "C:\Program Files\Microsoft\jdk-17*" -Directory -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $jdk) {
  Err "OpenJDK 17 non trovato:  winget install -e --id Microsoft.OpenJDK.17"
  exit 1
}
$env:JAVA_HOME = $jdk.FullName

if (-not (Test-Path "C:\src\flutter\bin\flutter.bat")) {
  Err "Flutter non trovato in C:\src\flutter"
  Info "git clone --depth 1 -b stable https://github.com/flutter/flutter.git C:\src\flutter"
  exit 1
}
$env:Path = "C:\src\flutter\bin;$env:JAVA_HOME\bin;C:\Android\Sdk\platform-tools;$env:Path"
$env:ANDROID_HOME = "C:\Android\Sdk"

# TRAPPOLA 1 - la cartella temporanea.
# Java crea le sue pipe interne con socket di dominio Unix, e mette il file
# del socket in TEMP. Dentro C:\Users\<utente>\AppData\Local\Temp il connect
# fallisce, e Gradle muore con "Unable to establish loopback connection", che
# fa pensare a un problema di rete o di firewall: non lo e'. Verificato che
# succede sia col percorso lungo sia con la forma abbreviata MS-DOS.
$tmp = "C:\Android\tmp"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:TEMP = $tmp
$env:TMP  = $tmp

# TRAPPOLA 2 - gli spazi nei percorsi.
# Gli strumenti Android non li tollerano: per questo Flutter sta in
# C:\src\flutter e l'SDK in C:\Android\Sdk, non sotto il profilo utente.
# Il progetto invece sta nel repo, che ha spazi nel percorso: per un'app di
# solo Dart va bene (il divieto riguarda l'NDK, cioe' il codice nativo), ma
# se una build fa i capricci e' il primo posto dove guardare.
if ($PSScriptRoot -match " ") {
  Info "Nota: il progetto sta in un percorso con spazi. Finora non da' problemi."
}
Ok "Java, Flutter e Android SDK pronti"

# ---------------------------------------------------------------- 2) TEST
# I test Dart aprono il vettore di prova vero (tests\vettore\): se non passano,
# l'app non leggerebbe i vault dell'app Windows. Non ha senso costruire un APK
# rotto, quindi si fermano qui.
Fase "Test (aprono il vettore di prova, condiviso con i test Python)"
# -j 2 e non il parallelismo pieno: piu' file di test insieme derivano ognuno
# una chiave Argon2id da 64 MB, e con la macchina occupata la memoria non
# basta. Visto due volte: test crittografici che scadono o non finiscono senza
# che nulla sia rotto - e siccome qui sotto l'APK non viene costruito a test
# rossi, sembra di aver rotto qualcosa. Costa una decina di secondi in piu' e
# toglie di mezzo un fallimento che non significa niente.
& flutter test -j 2
if ($LASTEXITCODE -ne 0) {
  Err "Test falliti: l'APK non viene costruito."
  exit 1
}
Ok "Test superati"
if ($Test) { exit 0 }

# ----------------------------------------------------------------- 3) APK
$tipo = if ($Release) { "release" } else { "debug" }
Fase "Costruzione APK ($tipo)"
Info "La PRIMA build scarica Gradle e le dipendenze: diversi minuti. Poi e' veloce."
if ($Release) { & flutter build apk --release } else { & flutter build apk --debug }
if ($LASTEXITCODE -ne 0) {
  Err "Build fallita: leggi i messaggi qui sopra."
  exit 1
}

$apk = Get-ChildItem "build\app\outputs\flutter-apk" -Filter "app-$tipo.apk" -ErrorAction SilentlyContinue |
       Select-Object -First 1
if (-not $apk) { Err "APK non trovato dopo la build."; exit 1 }
Write-Host ""
Ok ($apk.FullName + "  (" + [math]::Round($apk.Length / 1MB, 1) + " MB)")

if ($Release) {
  # Nel PACCHETTO insieme agli altri consegnabili, cosi' rilascio.ps1 lo
  # trova e lo carica sulla release senza che nessuno se lo ricordi.
  $pacchetto = Join-Path (Split-Path $PSScriptRoot -Parent) "PACCHETTO X INSTALLAZIONE EVERYWHERE"
  if (Test-Path $pacchetto) {
    Copy-Item $apk.FullName (Join-Path $pacchetto "VaultMind.apk") -Force
    Ok "Copiato nel pacchetto: VaultMind.apk"
  }
  Write-Host ""
  Info "Da mandare su WhatsApp: e' questo file."
  Info "Chi lo riceve deve autorizzare una volta l'installazione da quell'app."
} else {
  Write-Host ""
  Info "APK di DEBUG: va bene per provare, non per consegnare (piu' pesante e piu' lento)."
  Info "Per l'APK da consegnare:  .\costruisci.ps1 -Release"
}
