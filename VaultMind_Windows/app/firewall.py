"""
firewall.py — Chiedere a Windows di lasciar passare il sync.

## Perché non lo fa l'installer

Sembrerebbe il posto giusto, e non lo è: `VaultMind.iss` dichiara
`PrivilegesRequired=lowest` **di proposito** — installazione per-utente, niente
UAC, e uno SmartScreen meno aggressivo su un installer non firmato. `netsh` una
regola del firewall la scrive solo da amministratore, quindi lì dentro
fallirebbe in silenzio. Alzare i privilegi dell'installer per questa riga
significherebbe barattare la prima impressione di *tutti* per un problema che
ha *qualcuno*.

## Perché serve, visto che Windows chiede da solo

Windows mostra l'avviso «Consenti accesso» la prima volta che un programma si
mette in ascolto, e per la maggior parte delle persone finisce lì. Il guaio è
cosa succede a chi lo chiude: **Windows registra un rifiuto e non chiede più**.
Da quel momento il sync non funziona, nessuno lo dice, e non esiste nessun
posto nell'app dove tornare a chiederlo. Questa è quella strada — una richiesta
di conferma, una volta, quando l'utente ha già capito che qualcosa non va.

Si cancellano **tutte** le regole in ingresso di questo eseguibile prima di
riscriverle: in Windows un divieto batte un permesso, quindi aggiungere e basta
lascerebbe il rifiuto di prima a vincere sulla regola appena creata — e
sembrerebbe che il pulsante non faccia niente.

Le regole non si limitano al profilo Privato, per quanto sarebbe più elegante:
**la rete di casa viene classificata Pubblica molto spesso** (succede sulla
macchina di sviluppo di questo progetto), e una regola che non si applica è
peggio di nessuna regola, perché sembra fatta. Il confine di sicurezza del sync
resta dov'è sempre stato: la sonda firmata, che a chi non ha la chiave non
risponde affatto.
"""

from __future__ import annotations
import ctypes
import socket
import sys
from ctypes import wintypes
from typing import Optional

#: Il processo che deve poter ricevere. Sotto PyInstaller è VaultMind.exe;
#: durante lo sviluppo è il python.exe del venv — che è comunque quello giusto,
#: perché è lui ad aprire la porta.
def eseguibile() -> str:
    return sys.executable or ""


def ip_locale() -> str:
    """L'indirizzo di questa macchina sulla rete di casa.

    Si ricava aprendo un socket UDP verso un indirizzo qualsiasi: **non manda
    niente**, serve solo a far scegliere al sistema da quale scheda uscirebbe.
    `gethostbyname(gethostname())` darebbe spesso 127.0.0.1 o la scheda
    sbagliata su un portatile con WiFi e cavo insieme.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return str(s.getsockname()[0])
    except OSError:
        return ""
    finally:
        s.close()


# ------------------------------------------------------- la parte con l'UAC

_SEE_MASK_NOCLOSEPROCESS = 0x00000040
_SW_HIDE = 0
_ERRORE_ANNULLATO = 1223   # ERROR_CANCELLED: l'utente ha detto no all'UAC
_INFINITO_NO_GRAZIE = 90_000   # ms: oltre, l'avviso è stato ignorato


class _SHELLEXECUTEINFOW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("fMask", ctypes.c_ulong),
        ("hwnd", wintypes.HWND),
        ("lpVerb", wintypes.LPCWSTR),
        ("lpFile", wintypes.LPCWSTR),
        ("lpParameters", wintypes.LPCWSTR),
        ("lpDirectory", wintypes.LPCWSTR),
        ("nShow", ctypes.c_int),
        ("hInstApp", wintypes.HINSTANCE),
        ("lpIDList", ctypes.c_void_p),
        ("lpClass", wintypes.LPCWSTR),
        ("hkeyClass", wintypes.HKEY),
        ("dwHotKey", wintypes.DWORD),
        ("hIcon", wintypes.HANDLE),
        ("hProcess", wintypes.HANDLE),
    ]


def _comando(exe: str, porta_sync: int, porta_scoperta: int) -> str:
    """I tre comandi in una riga sola per `cmd /c`.

    Si passano come **parametri**, non scrivendo un file .cmd: un file .cmd
    Windows lo legge nella codepage OEM, e un percorso con accenti — che su un
    profilo utente italiano è tutt'altro che raro — arriverebbe storpiato a
    `netsh`, che scriverebbe la regola per un eseguibile inesistente.
    """
    return (
        f'/c netsh advfirewall firewall delete rule name=all dir=in program="{exe}" >nul 2>&1'
        f' & netsh advfirewall firewall add rule name="VaultMind sync (TCP {porta_sync})"'
        f' dir=in action=allow program="{exe}" protocol=TCP localport={porta_sync}'
        f' & netsh advfirewall firewall add rule name="VaultMind scoperta (UDP {porta_scoperta})"'
        f' dir=in action=allow program="{exe}" protocol=UDP localport={porta_scoperta}'
    )


def apri(porta_sync: int, porta_scoperta: int) -> dict:
    """Chiede l'autorizzazione e scrive le regole. Torna cos'è successo.

    Aspetta che il comando finisca — con un tetto — perché l'unica risposta
    utile all'utente è «fatto, riprova» oppure «non è andata»: dirgli «forse»
    lo rimanderebbe a indovinare, che è il punto di partenza da cui si voleva
    uscire.
    """
    exe = eseguibile()
    if not exe:
        return {"ok": False, "motivo": "Non riesco a capire quale programma autorizzare."}
    if sys.platform != "win32":
        return {"ok": False, "motivo": "Serve solo su Windows."}

    info = _SHELLEXECUTEINFOW()
    info.cbSize = ctypes.sizeof(info)
    info.fMask = _SEE_MASK_NOCLOSEPROCESS
    info.lpVerb = "runas"          # è questo a far comparire la richiesta
    info.lpFile = "cmd.exe"
    info.lpParameters = _comando(exe, porta_sync, porta_scoperta)
    info.nShow = _SW_HIDE

    # use_last_error=True e non una chiamata a GetLastError() dopo: fra le due
    # ci starebbero altre chiamate di ctypes, e il codice d'errore vero sarebbe
    # gia' stato sovrascritto. E' l'unico modo di distinguere «ha detto no»
    # da «non ha funzionato», che sono due messaggi diversi.
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    kernel32 = ctypes.windll.kernel32
    if not shell32.ShellExecuteExW(ctypes.byref(info)):
        if ctypes.get_last_error() == _ERRORE_ANNULLATO:
            return {"ok": False, "annullato": True,
                    "motivo": "Serve la tua conferma: senza, Windows non lascia scrivere la regola."}
        return {"ok": False, "motivo": "Windows non ha permesso la modifica."}

    try:
        atteso = kernel32.WaitForSingleObject(info.hProcess, _INFINITO_NO_GRAZIE)
        if atteso != 0:
            return {"ok": False, "motivo": "La richiesta di Windows è rimasta senza risposta."}
        uscita = wintypes.DWORD()
        kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(uscita))
        if uscita.value != 0:
            return {"ok": False, "motivo": "La regola non è stata scritta."}
    finally:
        kernel32.CloseHandle(info.hProcess)

    return {"ok": True, "programma": exe}


def diagnosi(acceso: bool, in_ascolto: bool, abbinati: int,
             porta_sync: int, porta_scoperta: int) -> dict:
    """Quello che si può dire con certezza quando non si trova nessuno.

    **Non si prova a indovinare lo stato del firewall.** Leggere le regole
    vorrebbe già i privilegi che non abbiamo, e un «forse è il firewall» detto
    male manda a caccia della cosa sbagliata: qui si dicono solo i fatti che
    conosciamo, e il resto si offre come cosa da provare.
    """
    motivi = []
    if not acceso:
        motivi.append("Il sync è spento su questo dispositivo: accendilo qui sopra.")
    elif not in_ascolto:
        motivi.append(
            f"La porta {porta_sync} non si è aperta: forse è occupata da un altro "
            "programma. Il sync a mano funziona lo stesso.")
    if acceso and abbinati == 0:
        motivi.append(
            "Nessun dispositivo abbinato: la prima volta serve il codice, con "
            "«Abbina un dispositivo».")
    return {
        "certi": motivi,
        "da_provare": [
            "Sull'altro dispositivo l'app dev'essere aperta e il vault sbloccato: "
            "a vault chiuso non risponde a nessuno, ed è voluto.",
            "Devono essere sulla stessa rete WiFi — non una sulla WiFi e l'altra "
            "sulla rete del telefono.",
            "Windows può aver bloccato VaultMind: se hai chiuso il suo avviso la "
            "prima volta, non te lo chiede più.",
        ],
        "programma": eseguibile(),
        "ip": ip_locale(),
        "porta_sync": porta_sync,
        "porta_scoperta": porta_scoperta,
    }
