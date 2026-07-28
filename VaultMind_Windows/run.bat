@echo off
setlocal
cd /d "%~dp0"
title VaultMind

where powershell >nul 2>nul
if errorlevel 1 (
  echo [ERRORE] PowerShell non trovato. Aggiorna Windows.
  pause
  exit /b 1
)

REM Il lavoro sta tutto in run.ps1: da batch puro non si riesce a distinguere
REM il vero Python dal finto alias del Microsoft Store (che risponde a
REM "where python" ma esce con codice 49 senza eseguire nulla).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"

if errorlevel 1 (
  echo.
  echo Si e' verificato un problema. Leggi i messaggi qui sopra.
  pause
)
