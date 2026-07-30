# Esegue i test su crypto_store.py.
#
# Usa l'interprete del venv per PATH ESPLICITO: su Windows 11 `python` nel PATH
# e' spesso il finto alias del Microsoft Store, che risponde ai controlli ma
# esce con codice 49 senza eseguire nulla.
#
# I test girano tutti in cartelle temporanee: non toccano ~/.vaultmind.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$py = Join-Path $repo "VaultMind_Windows\.venv\Scripts\python.exe"

if (-not (Test-Path $py)) {
  Write-Host "  [ERRORE] venv non trovato. Lancia prima run.bat in VaultMind_Windows." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "  Test su crypto_store.py (Argon2 coi parametri veri: ~1 minuto)" -ForegroundColor Cyan
Write-Host ""
& $py -m unittest discover -s $PSScriptRoot -t $PSScriptRoot -v
exit $LASTEXITCODE
