"""
sync_net.py — Il trasporto del sync sulla rete locale.

Divisione del lavoro: `sync_protocol.py` decide *chi si fida di chi*, `merge.py`
decide *cosa vince*, e qui dentro c'è solo l'idraulica — trovarsi e scambiarsi
i byte.

## Cosa si apre, e per quanto

**Non** si tocca il server FastAPI: quello resta inchiodato a `127.0.0.1` come è
sempre stato. Il sync apre un ascoltatore **suo**, su una porta sua, e **solo**
mentre il vault è sbloccato e il sync è acceso. Alla chiusura del vault si
richiude. La proprietà che il progetto ha oggi — il loopback non parla con la
rete — resta vera per tutto il resto dell'app.

## Chi risponde alle domande sulla rete

La scoperta è in UDP, ma **la sonda è firmata**: chi cerca dimostra di
conoscere la chiave del vault, e solo un dispositivo con la stessa chiave sa
verificarla e rispondere. Per chiunque altro sulla stessa WiFi — un bar, un
ufficio — VaultMind non esiste: non risponde, non si annuncia, non dice il
proprio nome. È la stessa promessa delle icone dei servizi non scaricate da
Internet, applicata alla rete locale.

L'unica eccezione è voluta e dura 120 secondi: quando **tu** chiedi di
aggiungere un dispositivo nuovo, che il vault non ce l'ha ancora e quindi la
chiave non può averla. In quella finestra si risponde anche a chi non firma, e
si dice il salt — che non è segreto — perché possa derivare la chiave dalla
master password che stai scrivendo. Se sbaglia password, le prove non tornano e
non viene trasferito niente.
"""

from __future__ import annotations
import json
import socket
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

from . import sync_protocol as sp

#: Porta dell'ascoltatore. Vicina a quella dell'app (8731) per ricordarsi che
#: sono due cose diverse: quella è loopback, questa parla con la rete locale.
PORTA_SYNC = 8732
#: Porta della scoperta. Solo UDP, solo domande e risposte corte.
PORTA_SCOPERTA = 8733

#: Versione del protocollo sul filo. Due versioni diverse si rifiutano subito,
#: invece di capirsi a metà.
VERSIONE = 1

#: Oltre questo, un messaggio non è un messaggio: è qualcuno che prova a farci
#: allocare memoria finché non moriamo. Il vault di 800 voci sta in ~1 MB.
MAX_MESSAGGIO = 64 * 1024 * 1024
TIMEOUT_S = 20


# --------------------------------------------------------------- il contesto

@dataclass
class ContestoSync:
    """Tutto quello che il trasporto deve chiedere all'app, senza conoscerla.

    Serve a tenere questo modulo provabile: nei test si passa un contesto finto
    e si fa parlare un client con un server sullo stesso computer, senza vault
    e senza interfaccia.
    """
    id_dispositivo: str
    nome: str
    chiave_vault: bytes
    #: {id: {"nome": ..., "quando": ...}} — solo nomi e date, nessun segreto.
    fidati: Dict[str, dict] = field(default_factory=dict)
    #: Da dove leggere l'elenco AGGIORNATO. Il campo qui sopra è una
    #: fotografia: chi abbina un dispositivo mentre l'ascoltatore è già aperto
    #: la lascia vecchia, e il dispositivo appena abbinato continuerebbe a
    #: risultare sconosciuto — respinto per sempre a finestra di abbinamento
    #: chiusa. Chi ha un elenco che cambia passa una funzione.
    fidati_ora: Optional[Callable[[], Dict[str, dict]]] = None
    #: Il vault cifrato da mandare all'altro.
    leggi_vault_cifrato: Callable[[], str] = lambda: ""
    #: Riceve il vault dell'altro e lo fonde. Torna un riepilogo per l'utente.
    ricevi_vault: Callable[[str, str], dict] = lambda blob, id_peer: {}
    #: Il salt del vault, per chi deve ancora derivare la chiave.
    salt_vault: bytes = b""
    #: Codice di abbinamento in corso, se l'utente l'ha chiesto. Altrimenti None.
    codice_attivo: Callable[[], Optional[str]] = lambda: None
    #: Chiamata quando un abbinamento va a buon fine.
    abbina: Callable[[str, str], None] = lambda id_peer, nome: None

    def elenco_fidati(self) -> Dict[str, dict]:
        return self.fidati_ora() if self.fidati_ora else self.fidati

    def si_fida_di(self, id_peer: str) -> bool:
        return id_peer in self.elenco_fidati()


class RifiutoSync(Exception):
    """Il collegamento non deve proseguire, e il motivo si può dire all'utente."""


# ------------------------------------------------------------- righe di JSON

def _scrivi(sock: socket.socket, dato: dict) -> None:
    riga = json.dumps(dato, ensure_ascii=False).encode("utf-8") + b"\n"
    sock.sendall(riga)


def _leggi(sock: socket.socket) -> dict:
    """Legge una riga di JSON, con un tetto: senza, chi si collega può farci
    crescere il buffer all'infinito e spegnere l'app da fuori."""
    pezzi = bytearray()
    while b"\n" not in pezzi:
        blocco = sock.recv(65536)
        if not blocco:
            raise RifiutoSync("Collegamento interrotto.")
        pezzi.extend(blocco)
        if len(pezzi) > MAX_MESSAGGIO:
            raise RifiutoSync("Messaggio troppo grande.")
    riga, _, _ = bytes(pezzi).partition(b"\n")
    try:
        dato = json.loads(riga.decode("utf-8"))
    except Exception as exc:
        raise RifiutoSync("Messaggio illeggibile.") from exc
    if not isinstance(dato, dict):
        raise RifiutoSync("Messaggio illeggibile.")
    return dato


# ------------------------------------------------------------------ scoperta

def _firma_sonda(chiave: bytes, nonce_hex: str) -> str:
    return sp.risposta_sfida(chiave, "sonda", bytes.fromhex(nonce_hex))


def _firma_eccomi(chiave: bytes, nonce_hex: str, id_dispositivo: str) -> str:
    return sp.risposta_sfida(chiave, "eccomi:" + id_dispositivo, bytes.fromhex(nonce_hex))


def cerca_dispositivi(ctx: ContestoSync, attesa: float = 1.5,
                      porta: int = PORTA_SCOPERTA) -> List[dict]:
    """Chiede «c'è qualcuno col mio stesso vault?» e raccoglie le risposte.

    La domanda è firmata con la chiave del vault: chi non ce l'ha non sa
    nemmeno riconoscerla, e infatti non risponde.
    """
    nonce_hex = sp.nonce().hex()
    domanda = json.dumps({
        "vm": VERSIONE, "tipo": "sonda", "n": nonce_hex,
        "f": _firma_sonda(ctx.chiave_vault, nonce_hex),
    }).encode("utf-8")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.3)
    trovati: Dict[str, dict] = {}
    try:
        s.sendto(domanda, ("255.255.255.255", porta))
        fine = time.time() + attesa
        while time.time() < fine:
            try:
                dati, mittente = s.recvfrom(8192)
            except socket.timeout:
                continue
            try:
                r = json.loads(dati.decode("utf-8"))
            except Exception:
                continue
            if r.get("tipo") != "eccomi" or r.get("vm") != VERSIONE:
                continue
            id_peer = str(r.get("id") or "")
            if not id_peer or id_peer == ctx.id_dispositivo:
                continue
            # La risposta è firmata a sua volta: chi non ha la chiave non può
            # fingersi un nostro dispositivo per farsi mandare il vault.
            atteso = _firma_eccomi(ctx.chiave_vault, nonce_hex, id_peer)
            if r.get("f") and r.get("f") != atteso:
                continue
            noti = ctx.elenco_fidati()
            trovati[id_peer] = {
                "id": id_peer,
                "nome": r.get("nome") or noti.get(id_peer, {}).get("nome") or "dispositivo",
                "indirizzo": mittente[0],
                "porta": int(r.get("porta") or PORTA_SYNC),
                "abbinabile": bool(r.get("abbinabile")),
                "firmata": bool(r.get("f")),
                "salt": r.get("salt") or "",
            }
    finally:
        s.close()
    return list(trovati.values())


class Annunciatore(threading.Thread):
    """Risponde alle sonde. Vive solo mentre il vault è aperto."""

    daemon = True

    def __init__(self, ctx: ContestoSync, porta: int = PORTA_SCOPERTA,
                 porta_sync: int = PORTA_SYNC):
        super().__init__(name="vaultmind-scoperta")
        self.ctx = ctx
        self.porta = porta
        self.porta_sync = porta_sync
        self._stop = threading.Event()
        self._sock: Optional[socket.socket] = None

    def run(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.settimeout(0.5)
        try:
            s.bind(("", self.porta))
        except OSError:
            return  # porta occupata: si rinuncia in silenzio, resta il sync a mano
        self._sock = s
        try:
            while not self._stop.is_set():
                try:
                    dati, mittente = s.recvfrom(8192)
                except socket.timeout:
                    continue
                except OSError:
                    break
                # Rete di sicurezza: qualunque cosa succeda su UN pacchetto non
                # può portarsi via l'ascolto di tutti gli altri.
                try:
                    risposta = self._rispondi(dati)
                    if risposta is not None:
                        s.sendto(json.dumps(risposta).encode("utf-8"), mittente)
                except Exception:
                    continue
        finally:
            s.close()
            self._sock = None

    def _rispondi(self, dati: bytes) -> Optional[dict]:
        # Cattura larga, e controllo che sia davvero un oggetto: un pacchetto
        # UDP arriva da chiunque, e `[]` è JSON validissimo che non ha `.get()`.
        # È la stessa lezione già pagata in `_leggi_blob` e in `unlock`: qui
        # costava il thread della scoperta, spento da fuori con un pacchetto.
        try:
            d = json.loads(dati.decode("utf-8"))
        except Exception:
            return None
        if not isinstance(d, dict):
            return None
        if d.get("tipo") != "sonda" or d.get("vm") != VERSIONE:
            return None
        nonce_hex = str(d.get("n") or "")
        try:
            bytes.fromhex(nonce_hex)
        except ValueError:
            return None

        firma_giusta = (d.get("f") == _firma_sonda(self.ctx.chiave_vault, nonce_hex))
        in_abbinamento = self.ctx.codice_attivo() is not None

        if firma_giusta:
            # Stesso vault: si risponde per esteso, firmando a nostra volta.
            return {
                "vm": VERSIONE, "tipo": "eccomi",
                "id": self.ctx.id_dispositivo, "nome": self.ctx.nome,
                "porta": self.porta_sync,
                "abbinabile": in_abbinamento,
                "f": _firma_eccomi(self.ctx.chiave_vault, nonce_hex, self.ctx.id_dispositivo),
            }

        if in_abbinamento:
            # Finestra voluta: un dispositivo nuovo il vault non ce l'ha ancora,
            # quindi non può firmare. Gli si dice il salt — che non è segreto —
            # perché derivi la chiave dalla master password che l'utente sta
            # scrivendo. Senza quella, l'abbinamento fallisce comunque.
            return {
                "vm": VERSIONE, "tipo": "eccomi",
                "id": self.ctx.id_dispositivo, "nome": self.ctx.nome,
                "porta": self.porta_sync, "abbinabile": True,
                "salt": self.ctx.salt_vault.hex(),
            }

        # Nessuna firma e nessun abbinamento in corso: per chi sta su questa
        # rete, qui non c'è niente.
        return None

    def ferma(self) -> None:
        self._stop.set()


# ----------------------------------------------------------------- il canale

def _stretta_di_mano_lato_server(sock: socket.socket, ctx: ContestoSync) -> str:
    """Verifica chi si è collegato. Torna l'id del dispositivo, o solleva."""
    ciao = _leggi(sock)
    if ciao.get("vm") != VERSIONE:
        _scrivi(sock, {"tipo": "no", "perche": "versione diversa"})
        raise RifiutoSync("Le due app hanno versioni diverse del sync.")

    id_peer = str(ciao.get("id") or "")
    sfida_peer = str(ciao.get("sfida") or "")
    codice = str(ciao.get("codice") or "")
    if not id_peer or not sfida_peer:
        raise RifiutoSync("Presentazione incompleta.")

    atteso_codice = ctx.codice_attivo()
    nuovo = not ctx.si_fida_di(id_peer)

    if nuovo:
        # Primo incontro: serve il codice che l'utente sta leggendo sull'altro
        # schermo. Senza, un dispositivo che conosce la master password
        # potrebbe abbinarsi da solo, senza che nessuno se ne accorga.
        if not atteso_codice:
            _scrivi(sock, {"tipo": "no", "perche": "non abbinato"})
            raise RifiutoSync("Dispositivo non abbinato.")
        if codice != atteso_codice:
            _scrivi(sock, {"tipo": "no", "perche": "codice errato"})
            raise RifiutoSync("Codice di abbinamento errato.")

    mia_sfida = sp.nonce()
    _scrivi(sock, {
        "tipo": "sfida",
        "id": ctx.id_dispositivo,
        "nome": ctx.nome,
        "sfida": mia_sfida.hex(),
        # si risponde alla sua, dimostrando di avere la stessa chiave
        "risposta": sp.risposta_sfida(ctx.chiave_vault, ctx.id_dispositivo,
                                      bytes.fromhex(sfida_peer)),
        "vault": sp.impronta_vault(ctx.chiave_vault),
    })

    conferma = _leggi(sock)
    if not sp.verifica_sfida(ctx.chiave_vault, id_peer, mia_sfida,
                             str(conferma.get("risposta") or "")):
        _scrivi(sock, {"tipo": "no", "perche": "chiave diversa"})
        raise RifiutoSync("L'altro dispositivo non ha la chiave di questo vault.")

    if nuovo:
        ctx.abbina(id_peer, str(ciao.get("nome") or "dispositivo"))
    return id_peer


def _stretta_di_mano_lato_client(sock: socket.socket, ctx: ContestoSync,
                                 codice: str = "") -> dict:
    mia_sfida = sp.nonce()
    _scrivi(sock, {
        "vm": VERSIONE, "tipo": "ciao",
        "id": ctx.id_dispositivo, "nome": ctx.nome,
        "sfida": mia_sfida.hex(),
        "codice": codice,
    })
    r = _leggi(sock)
    if r.get("tipo") == "no":
        raise RifiutoSync(_spiega(str(r.get("perche") or "")))
    if r.get("tipo") != "sfida":
        raise RifiutoSync("Risposta inattesa.")

    id_peer = str(r.get("id") or "")
    if not sp.verifica_sfida(ctx.chiave_vault, id_peer, mia_sfida,
                             str(r.get("risposta") or "")):
        raise RifiutoSync("L'altro dispositivo non ha la chiave di questo vault.")

    if r.get("vault") and r["vault"] != sp.impronta_vault(ctx.chiave_vault):
        # Non è un errore di rete: è un vault diverso, e riprovare non serve.
        raise RifiutoSync(
            "I due vault hanno master password diverse. Rimanda il vault dal "
            "dispositivo su cui l'hai cambiata.")

    _scrivi(sock, {
        "tipo": "conferma",
        "risposta": sp.risposta_sfida(ctx.chiave_vault, ctx.id_dispositivo,
                                      bytes.fromhex(str(r.get("sfida") or ""))),
    })
    nome = str(r.get("nome") or "dispositivo")
    # Anche chi CHIAMA registra l'altro. Prima lo faceva solo chi riceveva, e
    # il risultato era un abbinamento a metà: il sync funzionava in un verso
    # solo, e nell'elenco dei fidati mancava proprio il dispositivo con cui ti
    # eri appena abbinato.
    if not ctx.si_fida_di(id_peer):
        ctx.abbina(id_peer, nome)
    return {"id": id_peer, "nome": nome}


def _spiega(codice: str) -> str:
    return {
        "versione diversa": "Le due app hanno versioni diverse del sync: aggiornale.",
        "non abbinato": "Questo dispositivo non è ancora abbinato: chiedi il codice sull'altro.",
        "codice errato": "Codice di abbinamento errato.",
        "chiave diversa": "L'altro dispositivo non ha la chiave di questo vault.",
    }.get(codice, "Il collegamento è stato rifiutato.")


class Ascoltatore(threading.Thread):
    """Il server del sync. Vive solo mentre il vault è aperto."""

    daemon = True

    def __init__(self, ctx: ContestoSync, porta: int = PORTA_SYNC):
        super().__init__(name="vaultmind-sync")
        self.ctx = ctx
        self.porta = porta
        self._server: Optional[socket.socket] = None
        self._stop = threading.Event()
        #: Si alza quando la porta è davvero in ascolto. Senza, chi avvia
        #: l'ascoltatore e prova subito a collegarsi trova ancora chiuso.
        self.pronto = threading.Event()
        #: L'ultimo esito, da mostrare nella sezione Sincronizza.
        self.ultimo: Optional[dict] = None

    @property
    def porta_vera(self) -> int:
        return self._server.getsockname()[1] if self._server else self.porta

    def run(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", self.porta))
            s.listen(4)
        except OSError:
            s.close()
            return
        s.settimeout(0.5)
        self._server = s
        self.pronto.set()
        try:
            while not self._stop.is_set():
                try:
                    conn, _ = s.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=self._servi, args=(conn,), daemon=True).start()
        finally:
            s.close()
            self._server = None

    def _servi(self, conn: socket.socket) -> None:
        conn.settimeout(TIMEOUT_S)
        try:
            id_peer = _stretta_di_mano_lato_server(conn, self.ctx)
            # Da qui in poi si parla con un dispositivo che ha dimostrato di
            # avere la chiave di QUESTO vault. Quello che viaggia è comunque
            # cifrato: in chiaro non passa niente, nemmeno adesso.
            _scrivi(conn, {"tipo": "vault", "blob": self.ctx.leggi_vault_cifrato()})
            suo = _leggi(conn)
            if suo.get("tipo") == "vault":
                self.ultimo = self.ctx.ricevi_vault(str(suo.get("blob") or ""), id_peer)
        except (RifiutoSync, OSError, socket.timeout):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def ferma(self) -> None:
        self._stop.set()


def sincronizza(ctx: ContestoSync, indirizzo: str, porta: int = PORTA_SYNC,
                codice: str = "") -> dict:
    """Il lato che chiama. Torna un riepilogo di cosa è successo.

    Scambio simmetrico: ognuno manda il proprio vault cifrato e fonde in casa
    propria. Così nessuno dei due deve fidarsi della fusione dell'altro, e un
    conflitto lasciato in sospeso non blocca l'altro dispositivo.
    """
    sock = socket.create_connection((indirizzo, porta), timeout=TIMEOUT_S)
    sock.settimeout(TIMEOUT_S)
    try:
        chi = _stretta_di_mano_lato_client(sock, ctx, codice)
        suo = _leggi(sock)
        if suo.get("tipo") != "vault":
            raise RifiutoSync("L'altro dispositivo non ha mandato il vault.")
        _scrivi(sock, {"tipo": "vault", "blob": ctx.leggi_vault_cifrato()})
        esito = ctx.ricevi_vault(str(suo.get("blob") or ""), chi["id"])
        return {"ok": True, "con": chi["nome"], "id": chi["id"], **(esito or {})}
    finally:
        try:
            sock.close()
        except OSError:
            pass
