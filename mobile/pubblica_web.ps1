# VaultMind per iPhone: costruisce l'app web e (con -Pubblica) la mette online.
#
#   .\mobile\pubblica_web.ps1            test + build in mobile\build\web
#   .\mobile\pubblica_web.ps1 -Pubblica  ...e push sul repo pubblico
#
# DOVE FINISCE: https://psyko-cyber.github.io/vaultmind-web/
# Repo pubblico SEPARATO (psyko-cyber/vaultmind-web) con dentro SOLO l'app
# compilata: il sorgente resta nel repo privato. GitHub Pages gratis vuole un
# repo pubblico.
#
# PERCHE' UN SERVICE WORKER SCRITTO QUI: web\sw.js ha due segnaposto, la
# versione e le impronte dei file (percorso -> SHA-256), che si conoscono solo
# a build finita. Senza elenco l'app non si apre offline; con un elenco
# sbagliato (un file che non esiste) il service worker non si installa affatto,
# in silenzio. Per questo l'elenco si ricava dalla cartella vera. Le impronte
# servono a sw.js per rifiutare un file che la CDN di GitHub serve ancora
# della versione precedente: vedi il commento in cima a sw.js.
#
# COSA NON SI PUBBLICA: i simboli di debug (*.symbols), le varianti skwasm
# (solo build wasm, che su iPhone non gira) e quelle sperimentali (wimp,
# experimental_webparagraph), che il loader usa solo se glielo si chiede.
# COSA SI PUBBLICA MA NON VA IN CACHE: canvaskit\chromium (lo usano solo Chrome
# e Edge; chi e' su Android ha l'APK) e assets\NOTICES (le licenze, che l'app
# non apre). Senza questi tagli un iPhone scaricava 23 MB.
#
# Solo ASCII in questo file: PowerShell 5.1 legge gli script nella codepage di
# sistema e corrompe gli accenti.
param(
  [switch]$Pubblica
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Ok($m){ Write-Host "  [OK] $m" -ForegroundColor Green }
function Err($m){ Write-Host "  [ERRORE] $m" -ForegroundColor Red }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }
function Fase($m){ Write-Host ""; Write-Host $m -ForegroundColor Cyan }

$repo = "psyko-cyber/vaultmind-web"
$base = "/vaultmind-web/"

Fase "Ambiente"
if (-not (Test-Path "C:\src\flutter\bin\flutter.bat")) { Err "Flutter non trovato in C:\src\flutter"; exit 1 }
$env:Path = "C:\src\flutter\bin;$env:Path"
# Fuori dal profilo utente, come per Android: vedi costruisci.ps1.
$tmp = "C:\Android\tmp"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:TEMP = $tmp
$env:TMP  = $tmp
Ok "Flutter pronto"

Fase "Test (gli stessi dell'APK: il codice e' lo stesso)"
& flutter test -j 2
if ($LASTEXITCODE -ne 0) { Err "Test falliti: non costruisco."; exit 1 }
Ok "Test superati"

Fase "Build web"
# no-web-resources-cdn: motore grafico dentro l'app, non da gstatic.com.
# csp: niente codice generato al volo, cosi' la CSP di index.html regge.
& flutter build web --release --no-web-resources-cdn --csp --no-source-maps --base-href $base
if ($LASTEXITCODE -ne 0) { Err "Build web fallita."; exit 1 }
$uscita = Join-Path $PSScriptRoot "build\web"

# Il service worker di Flutter oggi serve solo a disinstallarsi: il nostro e' sw.js.
foreach ($f in @("flutter_service_worker.js", ".last_build_id")) {
  $p = Join-Path $uscita $f
  if (Test-Path $p) { Remove-Item $p -Force }
}
$ck = Join-Path $uscita "canvaskit"
Get-ChildItem $uscita -Recurse -File -Filter "*.symbols" | Remove-Item -Force
Get-ChildItem $ck -File | Where-Object { $_.Name -like "skwasm*" -or $_.Name -like "wimp*" } | Remove-Item -Force
$sperimentale = Join-Path $ck "experimental_webparagraph"
if (Test-Path $sperimentale) { Remove-Item $sperimentale -Recurse -Force }

$file = Get-ChildItem $uscita -Recurse -File |
  ForEach-Object { $_.FullName.Substring($uscita.Length + 1).Replace('\', '/') } |
  Where-Object { $_ -ne "sw.js" -and $_ -notlike "canvaskit/chromium/*" -and $_ -ne "assets/NOTICES" } |
  Sort-Object
# "./" e' la pagina chiesta aprendo l'icona: stesso contenuto di index.html.
$impronte = @()
foreach ($f in $file) {
  $h = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $uscita $f)).Hash.ToLower()
  $impronte += '"' + $f + '":"' + $h + '"'
  if ($f -eq "index.html") { $impronte += '"./":"' + $h + '"' }
}
$elenco = "{" + ($impronte -join ",") + "}"

$hash = (& git rev-parse --short HEAD).Trim()
$versione = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $hash
$sw = Join-Path $uscita "sw.js"
$testo = [IO.File]::ReadAllText($sw).Replace("__VERSIONE__", $versione).Replace("__IMPRONTE__", $elenco)
[IO.File]::WriteAllText($sw, $testo, (New-Object Text.UTF8Encoding $false))
$mb = [math]::Round(((Get-ChildItem $uscita -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
$mbCache = [math]::Round((($file | ForEach-Object { (Get-Item -LiteralPath (Join-Path $uscita $_)).Length } | Measure-Object -Sum).Sum) / 1MB, 1)
Ok "Build pronta: $uscita ($mb MB, in cache $($file.Count) file per $mbCache MB, versione $versione)"

if (-not $Pubblica) {
  Info "Non pubblicata. Per metterla online: .\mobile\pubblica_web.ps1 -Pubblica"
  exit 0
}

Fase "Pubblicazione su $repo"
$clone = Join-Path $tmp "vaultmind-web-pubblica"
if (Test-Path $clone) { Remove-Item $clone -Recurse -Force }
& git clone --quiet "https://github.com/$repo.git" $clone
if ($LASTEXITCODE -ne 0) { Err "Clone di $repo non riuscito."; exit 1 }

Get-ChildItem $clone -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
Copy-Item (Join-Path $uscita "*") $clone -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot "web_pubblico\README.md") $clone -Force
# Senza, GitHub Pages passa i file da Jekyll, che ignora quelli con "_" davanti.
New-Item -ItemType File (Join-Path $clone ".nojekyll") -Force | Out-Null

# Chi firma il commit: il nome del repo privato, ma l'email "noreply" di
# GitHub e non quella vera. Il repo e' pubblico, e l'email di un commit la
# legge chiunque, per sempre.
$nome = (& git -C (Split-Path $PSScriptRoot -Parent) config user.name).Trim()
$idGithub = (& gh api user --jq .id).Trim()
if (-not $idGithub) { Err "gh non risponde: serve 'gh auth login'."; exit 1 }
$email = "$idGithub+psyko-cyber@users.noreply.github.com"

Push-Location $clone
try {
  & git add -A
  & git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) { Ok "Niente di nuovo da pubblicare."; exit 0 }
  & git -c "user.name=$nome" -c "user.email=$email" commit --quiet -m "VaultMind web $versione"
  if ($LASTEXITCODE -ne 0) { Err "Commit non riuscito."; exit 1 }
  # HEAD:main e non HEAD: al primo giro il repo e' vuoto e il ramo locale si
  # chiama come vuole git init (spesso master), mentre Pages legge da main.
  & git push --quiet origin HEAD:main
  if ($LASTEXITCODE -ne 0) { Err "Push non riuscito."; exit 1 }
} finally {
  Pop-Location
}
Ok "Pubblicata. Tra un paio di minuti: https://psyko-cyber.github.io$base"
