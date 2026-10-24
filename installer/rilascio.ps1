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
#  Tutto finisce in "Consegnabili\": una copia sola, nessun duplicato da
#  tenere in sincrono.
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
  # Vuoto = si ricava da app\__init__.py ("6.9" -> "v6.9"). Si passa a mano
  # solo per rimettere mano a una release vecchia.
  [string]$Tag = ""
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$REPO_DIR = Split-Path $PSScriptRoot -Parent
$WIN      = Join-Path $REPO_DIR "VaultMind_Windows"
$EXE      = Join-Path $WIN "dist\VaultMind.exe"
$PACCHETTO = Join-Path $REPO_DIR "Consegnabili"
$GH_REPO  = "psyko-cyber/VaultMind"

function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Err($m){ Write-Host "  [ERRORE] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }
function Fase($m){ Write-Host ""; Write-Host $m -ForegroundColor Cyan }
# "6.9" e "6.9.0" sono la stessa versione: si confrontano tre pezzi per parte,
# come fanno piu_recente() in Python e piuRecente() in Dart.
function VerNorm($s){
  $p = @($s.Split('.') | ForEach-Object { [int]$_ })
  while ($p.Count -lt 3) { $p += 0 }
  ($p[0], $p[1], $p[2]) -join '.'
}

Set-Location $REPO_DIR

# ======================= 0) LA versione, da un posto solo =================
# Sta in app\__init__.py. Da qui la prendono l'installer (/DMyAppVersion), il
# tag della release e il nome che l'app confronta col tag quando controlla gli
# aggiornamenti. Scritta a mano in piu' file, prima o poi diverge - e un
# numero sbagliato significa un'app che non si aggiorna mai, oppure che
# propone di installare la versione che ha gia'.
Fase "0/4  Versione"
$initPy = Join-Path $WIN "app\__init__.py"
$m = [regex]::Match([IO.File]::ReadAllText($initPy), '__version__\s*=\s*"([^"]+)"')
if (-not $m.Success) { Err "__version__ non trovata in app\__init__.py"; exit 1 }
$VERSIONE = $m.Groups[1].Value
if (-not $Tag) { $Tag = "v$VERSIONE" }

# PC e telefono escono da QUESTA release, quindi devono dire lo stesso numero:
# l'APK che carichiamo qui e' quello che il telefono confrontera' col tag.
$pubspec = Join-Path $REPO_DIR "mobile\pubspec.yaml"
$verDart = Join-Path $REPO_DIR "mobile\lib\versione.dart"
$mp = [regex]::Match([IO.File]::ReadAllText($pubspec), '(?m)^version:\s*([0-9.]+)\+')
$md = [regex]::Match([IO.File]::ReadAllText($verDart), "versioneApp\s*=\s*'([^']+)'")
foreach ($c in @(@{n="mobile\pubspec.yaml"; v=$mp}, @{n="mobile\lib\versione.dart"; v=$md})) {
  if (-not $c.v.Success) { Err ("Versione non trovata in " + $c.n); exit 1 }
}
# pubspec dice "6.9.0", app\__init__.py dice "6.9": si confrontano i NUMERI,
# tre pezzi per parte. (TrimEnd('.0') sembrerebbe piu' corto e su "6.10.0"
# lascerebbe "6.1": taglia ogni carattere, non il suffisso.)
if ((VerNorm $mp.Groups[1].Value) -ne (VerNorm $VERSIONE) -or $md.Groups[1].Value -ne $VERSIONE) {
  Err "Le versioni non coincidono:"
  Info ("  app\__init__.py       " + $VERSIONE)
  Info ("  mobile\pubspec.yaml   " + $mp.Groups[1].Value)
  Info ("  mobile\lib\versione.dart  " + $md.Groups[1].Value)
  Info "Allineale (anche il numero dopo il + in pubspec, che deve solo crescere)."
  exit 1
}
Ok ("VaultMind $VERSIONE  -  release $Tag")

# ============================ 1) l'exe c'e' ed e' fresco? =================
# Impacchettare una build stantia significa consegnare un'app senza le ultime
# modifiche, e non se ne accorge nessuno finche' non lo segnala chi testa.
Fase "1/4  Controllo della build"
if (-not (Test-Path $EXE)) {
  Err "dist\VaultMind.exe non esiste. Lancia prima run.bat in VaultMind_Windows."
  exit 1
}
$exeTime = (Get-Item $EXE).LastWriteTime
# __pycache__ escluso: i .pyc nascono eseguendo l'app in sviluppo, sono sempre
# piu' recenti dell'exe e facevano dichiarare stantia una build buona.
$sorgenti = @(Get-ChildItem (Join-Path $WIN "app") -Recurse -File |
              Where-Object { $_.FullName -notmatch "__pycache__" })
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
# La versione la passa lo script: nel .iss non c'e' piu' (#ifndef + #error).
& $iscc /Q "/DMyAppVersion=$VERSIONE" (Join-Path $PSScriptRoot "VaultMind.iss")
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

NOTA: se hai installato VaultMind con VaultMind-Setup.exe, questo zip
NON TI SERVE - l'estensione e' gia' sul tuo computer, installata
insieme all'app. Il percorso da usare lo trovi nell'app:
Impostazioni > Estensione browser, con il pulsante per copiarlo.

Questo zip serve solo a chi vuole tenere l'estensione altrove, o a chi
usa VaultMind dal sorgente (run.bat).

1. Estrai questa cartella dove vuoi tenerla (non cancellarla dopo:
   il browser la carica da li' ogni volta).
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
  Info "Consegnabili pronti in: Consegnabili\"
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
  # Prima si creava a mano. Ora la versione cambia a ogni rilascio, e la
  # release nuova e' la regola, non l'eccezione: crearla qui evita di dover
  # ricordare un passaggio in piu' per poi scoprire che l'app non vede niente.
  Info "Release $Tag non trovata: la creo."
  $corpo = @{
    tag_name = $Tag
    name     = "VaultMind $VERSIONE"
    body     = "Da scrivere: cosa cambia per chi usa l'app.`n`nL'aggiornamento dentro l'app mostra QUESTO testo."
  } | ConvertTo-Json
  try {
    $rel = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$GH_REPO/releases" `
             -Headers $H -ContentType "application/json" -Body $corpo
  } catch {
    Err "Creazione della release $Tag non riuscita."
    Info "Il tag nasce sul commit di default del repo: se il commit non e' ancora"
    Info "stato pushato, fai prima push e rilancia."
    exit 1
  }
  Ok ("Release creata: " + $rel.html_url)
}
Info $rel.html_url

$nomi = @("VaultMind-Setup.exe", "VaultMind-Windows.zip", "VaultMind-Estensione.zip")
# L'APK lo costruisce mobile\costruisci.ps1 -Release, che lo lascia qui. Si
# carica se c'e': cosi' chi rilascia solo il PC non si trova un errore, e chi
# ha appena rifatto l'app mobile non deve ricordarsi di caricarla a mano.
if (Test-Path (Join-Path $PACCHETTO "VaultMind.apk")) { $nomi += "VaultMind.apk" }

# --- SHA256SUMS.txt: senza, l'aggiornamento dentro l'app NON installa ---
# Il controllo degli aggiornamenti scarica setup e APK e ne verifica l'impronta
# contro questo file: se manca, l'app si rifiuta di installare e manda alla
# pagina (aggiornamenti.py e aggiornamenti.dart). Gli zip non ci sono perche'
# nessuno li scarica da dentro l'app.
$daFirmare = @($nomi | Where-Object { $_ -eq "VaultMind-Setup.exe" -or $_ -eq "VaultMind.apk" })
$righe = foreach ($n in $daFirmare) {
  $h = (Get-FileHash (Join-Path $PACCHETTO $n) -Algorithm SHA256).Hash.ToLower()
  "$h *$n"
}
# Senza BOM e con LF: la prima riga deve cominciare con l'impronta, non con
# tre byte invisibili che la fanno sembrare un'altra cosa.
[IO.File]::WriteAllText((Join-Path $PACCHETTO "SHA256SUMS.txt"),
                        (($righe -join "`n") + "`n"),
                        (New-Object Text.UTF8Encoding $false))
$nomi += "SHA256SUMS.txt"
Ok ("SHA256SUMS.txt  " + $daFirmare.Count + " file: " + ($daFirmare -join ", "))
foreach ($a in $rel.assets) {
  if ($nomi -contains $a.name) {
    Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$GH_REPO/releases/assets/$($a.id)" -Headers $H | Out-Null
    Info ("rimosso il vecchio " + $a.name)
  }
}
foreach ($n in $nomi) {
  $f = Join-Path $PACCHETTO $n
  $tipo = switch -Wildcard ($n) {
    "*.exe" { "application/octet-stream" }
    "*.apk" { "application/vnd.android.package-archive" }
    "*.txt" { "text/plain; charset=utf-8" }
    default { "application/zip" }
  }
  Info ("carico $n (" + [math]::Round((Get-Item $f).Length / 1MB, 1) + " MB)...")
  $uri = "https://uploads.github.com/repos/$GH_REPO/releases/" + $rel.id + "/assets?name=$n"
  Invoke-RestMethod -Method Post -Uri $uri -Headers $HU -ContentType $tipo -InFile $f -TimeoutSec 900 | Out-Null
  Ok $n
}
Write-Host ""
Ok ("Release aggiornata: " + $rel.html_url)
Info "La descrizione della release si aggiorna a mano: e' il testo che l'app"
Info "mostra nella finestra 'c'e' una versione nuova'."
Info ""
Info "Perche' PC e telefono la vedano, il repo deve essere PUBBLICO: senza"
Info "token l'API delle release di un repo privato risponde 404, e il"
Info "controllo resta muto (l'app funziona, semplicemente non si aggiorna)."
