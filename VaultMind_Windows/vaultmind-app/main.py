"""
main.py — Avvio di VaultMind in locale.

Avvia il server web SOLO su 127.0.0.1 (loopback: non raggiungibile dalla rete).
Se "pywebview" è installato, l'app si apre in una FINESTRA NATIVA dedicata
(senza barra indirizzi né tab, sembra un'app desktop). Altrimenti ripiega
sul browser predefinito. In entrambi i casi il server è lo stesso.

Per uscire: chiudi la finestra, oppure Ctrl+C nel terminale.
"""

import threading
import time
import socket
import webbrowser

import uvicorn

HOST = "127.0.0.1"
PORT = 8731
URL = f"http://{HOST}:{PORT}"


def _wait_until_up(timeout=20.0):
    """Aspetta che il server risponda sulla porta, così la finestra non si
    apre su una pagina ancora vuota."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((HOST, PORT), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def _run_server():
    uvicorn.run("app.server:app", host=HOST, port=PORT, log_level="warning")


def _open_browser_fallback():
    _wait_until_up()
    webbrowser.open(URL)


if __name__ == "__main__":
    print("\n  VaultMind — gestore credenziali locale")
    print(f"  In ascolto solo su {URL}  (loopback, non esposto in rete)")
    print("  Per uscire: chiudi la finestra o premi Ctrl+C.\n")

    # Prova la finestra nativa (pywebview). Se non c'è, fallback al browser.
    try:
        import webview  # pywebview

        # Il server gira in un thread; pywebview DEVE stare nel thread principale (macOS).
        threading.Thread(target=_run_server, daemon=True).start()
        if not _wait_until_up():
            print("  [!] Il server non risponde, apro comunque nel browser.")
            webbrowser.open(URL)
        else:
            webview.create_window(
                "VaultMind",
                URL,
                width=1100,
                height=820,
                min_size=(680, 600),
                background_color="#070B14",
            )
            # storage_path isolato: la finestra non condivide cookie col browser
            webview.start()
        # quando la finestra si chiude, il processo termina (il thread è daemon)
    except ImportError:
        # Nessun pywebview: comportamento classico (browser).
        threading.Thread(target=_open_browser_fallback, daemon=True).start()
        _run_server()
