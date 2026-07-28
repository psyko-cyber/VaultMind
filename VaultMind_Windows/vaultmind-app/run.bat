@echo off
setlocal
cd /d "%~dp0"

echo Avvio VaultMind (setup automatico al primo avvio)...
echo.

where powershell >nul 2>nul
if errorlevel 1 (
  echo [ERRORE] PowerShell non trovato. Aggiorna Windows oppure usa run.ps1 manualmente.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"

if errorlevel 1 (
  echo.
  echo Si e' verificato un problema. Leggi i messaggi qui sopra.
  pause
)
