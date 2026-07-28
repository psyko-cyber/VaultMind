"""
vaultmind_launcher.py v6.3 — fix windowed stdout/stderr None
"""
import os, sys, socket, threading, time, webbrowser, traceback

if getattr(sys, "frozen", False):
    BASE = getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
else:
    BASE = os.path.dirname(os.path.abspath(__file__))

sys.path.insert(0, BASE)
os.chdir(BASE)

# FIX: in --windowed stdout/stderr sono None -> uvicorn crasha su isatty().
# Li sostituiamo con un file di log prima di importare qualsiasi cosa.
LOG_DIR = os.path.join(os.path.expanduser("~"), ".vaultmind")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "vaultmind.log")
_log_fh = open(LOG_FILE, "a", encoding="utf-8", buffering=1)

class _SafeStream:
    """Stream che scrive sul log e non crasha mai su isatty/fileno."""
    def write(self, s):
        try: _log_fh.write(s)
        except Exception: pass
    def flush(self):
        try: _log_fh.flush()
        except Exception: pass
    def isatty(self): return False
    def fileno(self): raise OSError("no fileno")

if sys.stdout is None: sys.stdout = _SafeStream()
if sys.stderr is None: sys.stderr = _SafeStream()

HOST, PORT = "127.0.0.1", 8731
URL = f"http://{HOST}:{PORT}"

def _wait_until_up(timeout=30.0):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((HOST, PORT), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.3)
    return False

def _run_server():
    try:
        import uvicorn
        uvicorn.run("app.server:app", host=HOST, port=PORT, log_level="warning")
    except Exception:
        sys.stderr.write("ERRORE SERVER:\n" + traceback.format_exc() + "\n")

def main():
    sys.stdout.write(f"[{time.strftime('%H:%M:%S')}] VaultMind avvio\n")
    threading.Thread(target=_run_server, daemon=True).start()
    up = _wait_until_up(30)
    sys.stdout.write(f"[{time.strftime('%H:%M:%S')}] server up={up}\n")
    if not up:
        try: os.startfile(LOG_FILE)
        except Exception: pass
        return
    try:
        import webview
        webview.create_window("VaultMind", URL, width=1100, height=820,
                              min_size=(680, 600), background_color="#0A0E1A")
        webview.start()
    except Exception as e:
        sys.stderr.write("webview fallito: " + str(e) + "\n")
        webbrowser.open(URL)
        while True: time.sleep(60)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.stderr.write("ERRORE MAIN:\n" + traceback.format_exc() + "\n")
