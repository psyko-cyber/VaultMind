@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title Installa VaultMind

echo ============================================================
echo   VaultMind - creazione dell'applicazione (.exe)
echo ============================================================
echo.
echo Questo script crea VaultMind.exe con icona e mette un
echo collegamento sul Desktop. Va eseguito UNA SOLA VOLTA.
echo Dalla prossima volta: doppio clic sull'icona sul Desktop.
echo.

REM --- 1) Python ---
where python >nul 2>nul
if errorlevel 1 (
  echo [1/4] Python non trovato. Provo a installarlo con winget...
  where winget >nul 2>nul
  if not errorlevel 1 (
    winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
  )
)
where python >nul 2>nul
if errorlevel 1 (
  echo.
  echo [ERRORE] Python non disponibile. Installalo da https://www.python.org/downloads/
  echo          spuntando "Add python.exe to PATH", poi riesegui questo file.
  start "" "https://www.python.org/downloads/"
  pause
  exit /b 1
)
echo [1/4] Python OK.

REM --- 2) Ambiente e dipendenze ---
echo [2/4] Preparo l'ambiente e installo le dipendenze...
if not exist ".venv" python -m venv .venv
call ".venv\Scripts\activate.bat"
python -m pip install --upgrade pip --quiet
python -m pip install -r requirements.txt --quiet
python -m pip install pyinstaller --quiet
REM audio (microfono) best-effort
python -m pip install -r requirements-audio.txt --quiet 2>nul

REM verifica che le dipendenze critiche importino correttamente
echo     Verifico le dipendenze...
python -c "import fastapi, uvicorn, cryptography, argon2, numpy, webview" 2>nul
if errorlevel 1 (
  echo [!] Alcune dipendenze non si importano. Provo a reinstallarle...
  python -m pip install --force-reinstall cryptography argon2-cffi numpy --quiet
)

REM --- 3) Build del .exe ---
echo [3/4] Costruisco VaultMind.exe (puo' richiedere qualche minuto)...
REM pulizia build precedenti per evitare residui
if exist "build" rmdir /s /q "build"
if exist "dist" rmdir /s /q "dist"
if exist "VaultMind.spec" del /q "VaultMind.spec"
pyinstaller --noconfirm --onefile --windowed ^
  --name VaultMind ^
  --icon "VaultMind.ico" ^
  --add-data "app;app" ^
  --add-data "requirements.txt;." ^
  --collect-all webview ^
  --collect-all fastapi ^
  --collect-all uvicorn ^
  --collect-all starlette ^
  --collect-all pydantic ^
  --collect-all pydantic_core ^
  --collect-all cryptography ^
  --collect-all argon2 ^
  --collect-all numpy ^
  --collect-all python_multipart ^
  --collect-all faster_whisper ^
  --collect-all onnxruntime ^
  --collect-all ctranslate2 ^
  --collect-all tokenizers ^
  --hidden-import uvicorn.logging ^
  --hidden-import uvicorn.loops.auto ^
  --hidden-import uvicorn.protocols.http.auto ^
  --hidden-import uvicorn.protocols.websockets.auto ^
  --hidden-import uvicorn.lifespan.on ^
  --hidden-import app.server ^
  --hidden-import app.crypto_store ^
  --hidden-import app.search ^
  --hidden-import app.embedding ^
  --hidden-import app.llm ^
  --hidden-import app.import_parse ^
  --hidden-import app.import_csv ^
  --hidden-import app.totp ^
  --hidden-import app.transcribe ^
  vaultmind_launcher.py

if not exist "dist\VaultMind.exe" (
  echo.
  echo [ERRORE] La build non ha prodotto dist\VaultMind.exe. Leggi i messaggi sopra.
  pause
  exit /b 1
)
echo [3/4] Eseguibile creato in dist\VaultMind.exe

REM --- 4) Collegamento sul Desktop ---
echo [4/4] Creo il collegamento sul Desktop...
set "EXE=%CD%\dist\VaultMind.exe"
powershell -NoProfile -Command ^
  "$d=[Environment]::GetFolderPath('Desktop'); $s=(New-Object -ComObject WScript.Shell).CreateShortcut(\"$d\VaultMind.lnk\"); $s.TargetPath='%EXE%'; $s.WorkingDirectory='%CD%\dist'; $s.IconLocation='%CD%\VaultMind.ico'; $s.Save()"

echo.
echo ============================================================
echo   FATTO! Trovi "VaultMind" sul Desktop.
echo   Doppio clic per avviare: si apre la finestra dell'app.
echo.
echo   NOTA: per le risposte intelligenti in chat serve Ollama.
echo   Se non e' installato, l'app funziona comunque (modo base).
echo   Per installarlo: https://ollama.com/download  poi in un
echo   terminale:  ollama pull llama3.2:3b
echo ============================================================
echo.
pause
