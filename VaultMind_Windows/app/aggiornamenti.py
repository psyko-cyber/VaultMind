"""
aggiornamenti.py — Accorgersi che c'è una versione nuova, senza mai far
dipendere l'app da Internet.

## Perché un'app «100% locale» chiama GitHub

Il contrario di «locale» è «il provider ha i tuoi dati», non «il programma non
sa di essere vecchio». Un gestore di password che resta alla versione di un
anno prima è un problema di sicurezza, e finora l'unico modo di aggiornarlo era
che qualcuno si ricordasse di guardare la pagina delle release: cioè nessuno.
Da qui esce **una sola richiesta**, anonima, a una pagina pubblica.

## Cosa vede GitHub, e cosa non vede

Una GET senza autenticazione a `api.github.com`: indirizzo IP e `User-Agent`
con la versione, come qualunque visita a un sito. Niente identificativi, niente
conteggi, niente che riguardi il vault — questo file non ha nemmeno accesso
allo store. Resta una connessione in uscita che prima non c'era, quindi:
l'interruttore in Impostazioni la spegne, e spenta non parte nessuna richiesta.

## Non blocca mai niente

Vale per l'avvio, per lo sblocco e per la ricerca. Il controllo gira in un
thread, con un timeout corto, e **qualunque** guasto di rete vale «non lo so»:
nessun messaggio, nessuna riga rossa, nessuna attesa. Chi apre VaultMind in
aereo non deve accorgersi che questo file esiste. È la ragione per cui qui si
cattura `Exception` e non le singole eccezioni di `urllib`: un DNS che risponde
spazzatura, un proxy aziendale che restituisce HTML, un captive portal che
intercetta la richiesta sono tutti casi normali, non errori da segnalare.

## L'installazione

Il setup è lo stesso che si scarica a mano, con la stessa firma (cioè nessuna,
finché i binari non saranno firmati: §5.1 di TODO.md) e lo stesso `AppId`,
quindi si installa *sopra* e i dati in `~/.vaultmind` non vengono toccati.
Due dettagli pagati:

- **Lo SHA-256 si verifica prima di eseguire**, contro `SHA256SUMS.txt` della
  release. Senza quel controllo, un download corrotto a metà diventerebbe un
  eseguibile lanciato con fiducia.
- **Niente UAC**: l'installer è per-utente (`PrivilegesRequired=lowest`),
  quindi `ShellExecuteW` con il verbo `open` basta e nessuna finestra di
  Windows chiede conferma. Era la parte più fragile in Tigert, che installa
  allo stesso modo ma con `runas`.

Il setup, partito in silenzio, **chiude VaultMind** e lo riapre aggiornato
(`/RELAUNCH=1`): per questo l'ordine conta — prima si risponde alla pagina,
poi si lancia. Chi scrive qui dentro deve dare per scontato che il processo
muoia subito dopo.
"""

from __future__ import annotations
import ctypes
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.request
from typing import Callable, Optional

from . import __version__

#: Dove si guarda. È il repo del progetto: perché la richiesta funzioni senza
#: token, le release devono stare su un repo PUBBLICO (vedi TODO.md).
REPO = "psyko-cyber/VaultMind"
PAGINA_RELEASE = f"https://github.com/{REPO}/releases/latest"

#: I nomi degli allegati che `installer/rilascio.ps1` carica sulla release.
#: Cercare per nome e non «il primo .exe» evita di scaricare l'APK o uno zip.
NOME_SETUP = "VaultMind-Setup.exe"
NOME_SUMS = "SHA256SUMS.txt"

#: Corti di proposito: un controllo che non risponde non è un problema da
#: aspettare. Il download invece vale la pena di attenderlo.
TIMEOUT_CONTROLLO = 8.0
TIMEOUT_DOWNLOAD = 30.0

#: Ogni quanto si torna a chiedere. Non ha senso più spesso: le release
#: escono ogni settimane, e questo è anche il tetto sulle richieste a GitHub.
INTERVALLO_ORE = 12
#: «Più tardi» su una versione precisa: non si ripropone per questo tempo.
RINVIO_ORE = 20


def ora_ms() -> int:
    return int(time.time() * 1000)


# ------------------------------------------------------------- confronto
def piu_recente(a: str, b: str) -> bool:
    """`a` è una versione più nuova di `b`?

    Confronto numerico pezzo per pezzo, non alfabetico: `"6.10" > "6.9"` deve
    essere vero, e come stringhe non lo sarebbe.

    Si buttano via il `v` del tag e **tutto quello che segue un `+` o un `-`**:
    il numero di build serve ad Android (`versionCode`), non a dire chi è più
    recente, e senza questa riga `6.9.0+69` risulterebbe più nuovo di `6.9` —
    cioè il telefono si offrirebbe di aggiornarsi alla versione che ha già.
    I pezzi mancanti valgono 0: `6.9` e `6.9.0` sono la stessa versione.
    """
    def pezzi(v: str) -> list:
        v = re.sub(r"^[vV]", "", str(v or "").strip())
        v = re.split(r"[+\-]", v)[0]
        return [int(x) if x.isdigit() else 0 for x in v.split(".") if x != ""]

    x, y = pezzi(a), pezzi(b)
    for i in range(max(len(x), len(y), 3)):
        xi = x[i] if i < len(x) else 0
        yi = y[i] if i < len(y) else 0
        if xi != yi:
            return xi > yi
    return False


def sha_atteso(sums: str, nome: str) -> Optional[str]:
    """Lo SHA-256 di `nome` dentro un SHA256SUMS.txt (`hash *nome`)."""
    for riga in (sums or "").splitlines():
        m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", riga.strip())
        if m and m.group(2).strip() == nome:
            return m.group(1).lower()
    return None


# ------------------------------------------------------------- il controllo
def _richiesta(url: str) -> urllib.request.Request:
    return urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": f"VaultMind/{__version__}",
    })


def leggi_release(testo: str) -> Optional[dict]:
    """La risposta di GitHub ridotta a quello che ci serve, o None se quella
    risposta non parla di una release (un proxy che restituisce la sua pagina
    di login è il caso normale, non un errore).

    Separata dalla rete perché è l'unico pezzo che vale la pena provare: la
    forma di una risposta altrui non si dà mai per buona.
    """
    try:
        j = json.loads(testo)
    except Exception:
        return None
    if not isinstance(j, dict):
        return None
    tag = re.sub(r"^[vV]", "", str(j.get("tag_name") or "").strip())
    if not re.match(r"^\d+(\.\d+)*$", tag):
        return None
    info = {
        "versione": tag,
        "pagina": str(j.get("html_url") or PAGINA_RELEASE),
        "note": str(j.get("body") or "").strip(),
        "download": None,
        "sums": None,
    }
    allegati = j.get("assets")
    for a in allegati if isinstance(allegati, list) else []:
        if not isinstance(a, dict):
            continue
        nome = str(a.get("name") or "")
        url = a.get("browser_download_url")
        if not isinstance(url, str):
            continue
        if nome == NOME_SETUP:
            info["download"] = url
        elif nome == NOME_SUMS:
            info["sums"] = url
    return info


def cerca(timeout: float = TIMEOUT_CONTROLLO) -> Optional[dict]:
    """L'ultima release pubblicata, o None per qualunque motivo."""
    url = f"https://api.github.com/repos/{REPO}/releases/latest"
    try:
        with urllib.request.urlopen(_richiesta(url), timeout=timeout) as r:
            if r.status != 200:
                return None
            # Tetto alla lettura: una risposta enorme non deve poter riempire
            # la memoria dell'app per un controllo di versione.
            return leggi_release(r.read(256 * 1024).decode("utf-8", "replace"))
    except Exception:
        return None


def note_pulite(md: str, righe: int = 12) -> str:
    """Le note della release in testo semplice: la finestra dell'app non è un
    lettore di Markdown, e `## **` a schermo sembrano un difetto."""
    out = []
    for riga in (md or "").splitlines():
        riga = re.sub(r"^#+\s*", "", riga.replace("**", "")).rstrip()
        out.append(riga)
    testo = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    pezzi = testo.splitlines()
    if len(pezzi) > righe:
        pezzi = pezzi[:righe] + ["…"]
    return "\n".join(pezzi)


# ------------------------------------------------------------- il download
def cartella() -> str:
    """Una cartella nostra nel temporaneo di sistema. Non `~/.vaultmind`: lì
    ci sono i dati dell'utente e un eseguibile scaricato non ci entra."""
    return os.path.join(tempfile.gettempdir(), "vaultmind-aggiornamento")


def pulisci() -> None:
    """Via il setup già usato (o lasciato a metà). Un eseguibile vecchio che
    resta in giro è solo un modo di installare per sbaglio la versione di
    ieri."""
    try:
        shutil.rmtree(cartella(), ignore_errors=True)
    except Exception:
        pass


def scarica(info: dict, su_progresso: Optional[Callable[[float], None]] = None) -> str:
    """Scarica il setup della release e ne verifica lo SHA-256.

    Solleva se qualcosa non torna — e in quel caso il file viene cancellato:
    meglio nessun installer che un installer di cui non sappiamo niente.
    """
    url = info.get("download")
    if not url:
        raise ValueError("Questa release non ha il setup di Windows.")
    pulisci()
    os.makedirs(cartella(), exist_ok=True)
    percorso = os.path.join(cartella(), NOME_SETUP)
    try:
        with urllib.request.urlopen(_richiesta(url), timeout=TIMEOUT_DOWNLOAD) as r:
            totale = int(r.headers.get("Content-Length") or 0)
            fatto = 0
            h = hashlib.sha256()
            with open(percorso, "wb") as f:
                while True:
                    blocco = r.read(256 * 1024)
                    if not blocco:
                        break
                    f.write(blocco)
                    h.update(blocco)
                    fatto += len(blocco)
                    if totale and su_progresso:
                        su_progresso(fatto / totale)
        if totale and fatto != totale:
            raise IOError("Download incompleto.")

        atteso = None
        if info.get("sums"):
            try:
                with urllib.request.urlopen(_richiesta(info["sums"]), timeout=TIMEOUT_DOWNLOAD) as r:
                    atteso = sha_atteso(r.read(64 * 1024).decode("utf-8", "replace"), NOME_SETUP)
            except Exception:
                atteso = None     # il file dei controlli non c'è: vedi sotto
        # Senza SHA256SUMS.txt non si installa: è l'unica cosa che distingue
        # «ho scaricato il setup» da «ho scaricato qualcosa». Una release
        # pubblicata senza quel file va corretta, non aggirata.
        if not atteso:
            raise IOError("La release non pubblica lo SHA-256: niente da verificare.")
        if h.hexdigest() != atteso:
            raise IOError("Il file scaricato non corrisponde allo SHA-256 della release.")
        return percorso
    except Exception:
        pulisci()
        raise


def installa(percorso: str) -> bool:
    """Lancia il setup in silenzio. Dopo questa riga VaultMind si chiude.

    `ShellExecuteW` e non `subprocess`: è il modo che su Windows 11 funziona
    anche da un'app senza console (la lezione di Tigert, che prima lanciava un
    PowerShell staccato e su alcune build non partiva mai).
    `/FORCECLOSEAPPLICATIONS` perché in silenzio nessuno può rispondere alla
    domanda «chiudo VaultMind?», e `/RELAUNCH=1` lo riapre aggiornato.
    """
    if sys.platform != "win32":
        return False
    parametri = "/SILENT /NORESTART /FORCECLOSEAPPLICATIONS /RELAUNCH=1"
    r = int(ctypes.windll.shell32.ShellExecuteW(None, "open", percorso, parametri, None, 1))
    return r > 32
