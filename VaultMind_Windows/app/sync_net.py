"""
sync_net.py — I byte sulla rete, lato PC. **Il PC chiama, il telefono
risponde**; gemello Dart, il lato che risponde: `mobile/lib/sync_rete_io.dart`.

## Perché il PC non ascolta più

Fino al 25/10/2026 il PC teneva aperte una porta TCP e una UDP, e cercava gli
altri con un broadcast. Due cose lo rompevano, e nessuna era colpa dell'utente:

  - il **firewall di Windows** blocca chi ascolta finché qualcuno non dice di
    sì a una finestra dell'UAC — e l'app doveva spiegarlo;
  - il **broadcast** usciva dalla scheda di rete con la metrica più bassa, che
    sul PC di Luca era quella di VMware (o del tunnel della VPN), non la WiFi:
    il telefono non lo sentiva mai, e l'app dava la colpa al firewall.

Adesso il PC non ascolta niente: un collegamento **in uscita** il firewall lo
lascia passare senza chiedere. Ascolta il telefono, su cui un firewall non c'è.
Per trovarlo il PC si ricorda l'ultimo indirizzo e, se lì non risponde, bussa
alla porta 8732 di ogni indirizzo delle reti a cui è collegato — tutte le
schede, la principale per prima, così non conta quale ha la metrica più bassa.
Si fa con collegamenti TCP brevi, non con un broadcast: passano da qualunque
scheda, e chi non c'è non risponde e basta.

Limite, dichiarato: si bussa sulle reti /24 del PC (`192.168.1.x`), che è
la rete di casa quasi sempre. Fuori casa il sync non c'è, ed è voluto.
"""

from __future__ import annotations
import json
import socket
from concurrent.futures import ThreadPoolExecutor
from typing import List, Optional

from . import sync_protocol as sp

PORTA_SYNC = 8732
#: Per bussare: chi è in casa risponde in pochi millisecondi, e chi non c'è non
#: deve far aspettare. Abbastanza largo per una WiFi affollata.
ATTESA_BUSSA_S = 0.8
#: A collegamento aperto: un vault grande su una WiFi lenta ci mette un po'.
ATTESA_RISPOSTA_S = 20.0
#: Oltre questa misura una riga non è un vault, è qualcuno che ci prova.
MAX_MESSAGGIO = 64 * 1024 * 1024


class RifiutoSync(Exception):
    """Il sync con quel dispositivo non si è fatto. Il messaggio è per l'utente."""


class NonRaggiungibile(RifiutoSync):
    """Nessuno risponde a quell'indirizzo, o il collegamento è caduto."""


class Rifiutato(RifiutoSync):
    """Ha risposto, ma non ci riconosce (`motivo`: "pc", "chiave") o ha
    detto qualcosa che non segue il protocollo ("protocollo")."""

    def __init__(self, motivo: str, messaggio: str = ""):
        super().__init__(messaggio or f"rifiutato: {motivo}")
        self.motivo = motivo


class Collegamento:
    """Un collegamento col telefono: righe JSON, ciascuna cifrata con la
    chiave di quel telefono."""

    def __init__(self, sock: socket.socket, chiave: bytes):
        self._s = sock
        self._f = sock.makefile("rb")
        self._chiave = chiave

    @classmethod
    def apri(cls, indirizzo: str, porta: int, chiave: bytes,
             attesa: float = ATTESA_BUSSA_S) -> "Collegamento":
        try:
            s = socket.create_connection((indirizzo, porta), timeout=attesa)
        except OSError as exc:
            raise NonRaggiungibile(f"{indirizzo} non risponde.") from exc
        s.settimeout(ATTESA_RISPOSTA_S)
        return cls(s, chiave)

    def manda(self, dati: dict, intestazione: Optional[dict] = None) -> None:
        riga = dict(intestazione or {})
        riga["m"] = sp.cifra(self._chiave, dati)
        try:
            self._s.sendall(json.dumps(riga).encode("ascii") + b"\n")
        except OSError as exc:
            raise NonRaggiungibile("Il collegamento è caduto.") from exc

    def ricevi(self) -> dict:
        try:
            riga = self._f.readline(MAX_MESSAGGIO + 1)
        except OSError as exc:
            raise NonRaggiungibile("Il telefono ha smesso di rispondere.") from exc
        if not riga:
            # Chiuso senza dire niente: è quello che fa un telefono che non
            # riesce a decifrare la prima riga (chiave sbagliata) — o un altro
            # programma che per caso ascolta sulla stessa porta.
            raise Rifiutato("chiuso", "Ha chiuso il collegamento senza rispondere.")
        if len(riga) > MAX_MESSAGGIO:
            raise Rifiutato("protocollo", "Messaggio troppo grande.")
        # Cattura larga: arriva dalla rete, può avere qualunque forma.
        try:
            obj = json.loads(riga.decode("utf-8"))
            if not isinstance(obj, dict):
                raise ValueError("non è un oggetto")
        except Exception as exc:
            raise Rifiutato("protocollo", "Risposta illeggibile.") from exc
        if "no" in obj:
            raise Rifiutato(str(obj.get("no")))
        try:
            return sp.decifra(self._chiave, str(obj.get("m") or ""))
        except sp.MessaggioRifiutato as exc:
            raise Rifiutato("chiave", "Risposta cifrata con un'altra chiave.") from exc

    def chiudi(self) -> None:
        try:
            self._f.close()
            self._s.close()
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.chiudi()


# ------------------------------------------------------------- dove cercare

def _principale() -> Optional[str]:
    """L'indirizzo della scheda che porta verso Internet. Un `connect` UDP non
    manda nessun pacchetto: chiede solo al sistema quale scheda userebbe."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))   # indirizzo di documentazione, mai usato davvero
            return s.getsockname()[0]
    except OSError:
        return None


def indirizzi_locali() -> List[str]:
    """Gli IPv4 di questo PC, la scheda principale per prima. Loopback e
    169.254 (la scheda senza rete) non servono a trovare nessuno."""
    tutti: List[str] = []
    p = _principale()
    if p:
        tutti.append(p)
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in tutti:
                tutti.append(ip)
    except OSError:
        pass
    return [ip for ip in tutti
            if not ip.startswith(("127.", "169.254.", "0."))]


def reti_locali() -> List[List[str]]:
    """Per ogni rete /24 del PC, gli indirizzi a cui bussare. La rete della
    scheda principale per prima: è quasi sempre lì che sta il telefono, e
    trovarlo subito evita di bussare a vuoto sulle reti di VMware."""
    reti: List[List[str]] = []
    viste = set()
    for ip in indirizzi_locali():
        prefisso = ip.rsplit(".", 1)[0]
        if prefisso in viste:
            continue
        viste.add(prefisso)
        reti.append([f"{prefisso}.{n}" for n in range(1, 255)])
    return reti


def bussa(indirizzi: List[str], porta: int,
          attesa: float = ATTESA_BUSSA_S) -> List[str]:
    """Chi, fra `indirizzi`, accetta un collegamento sulla porta. Non dice
    niente e chiude subito: chi è va scoperto dopo, con la chiave."""
    aperti: List[str] = []

    def prova(h: str) -> None:
        try:
            with socket.create_connection((h, porta), timeout=attesa):
                aperti.append(h)
        except OSError:
            pass

    # Tanti in parallelo: quasi tutti gli indirizzi di una rete sono vuoti, e
    # ognuno costa l'attesa intera. 254 in 128 fili sono due attese, non 254.
    with ThreadPoolExecutor(max_workers=128) as ex:
        list(ex.map(prova, indirizzi))
    return [h for h in indirizzi if h in aperti]
