"""
sync_app.py — Il sync del PC con i telefoni collegati: la colla fra
`sync_protocol` (chiave e messaggi), `sync_net` (chi chiamare) e `merge`
(chi vince). Gemello sul telefono: `mobile/lib/sync_gestore.dart`.

## Come si collega un telefono

Il PC mostra un QR con 32 byte a caso; il telefono lo inquadra. Da quel
momento i due hanno la stessa chiave e nessun altro ce l'ha: è tutto
l'abbinamento. Le master password possono essere diverse, e i vault possono
essere nati separati — il caso che col sync di prima non si poteva fare.

Le chiavi dei telefoni stanno **nel vault** (`sync_telefoni` nella radice del
contenuto cifrato): cifrate come le password, sopravvivono al cambio della
master password e non si leggono senza. Nelle impostazioni, in chiaro, solo
ciò che non è segreto: l'ultimo indirizzo, l'ora dell'ultimo sync, le categorie
concordate (la «base» di `merge._categorie`).

## Il giro

Ogni pochi secondi, finché il vault è aperto, il PC chiama ciascun telefono
all'ultimo indirizzo; se lì non risponde lo cerca nella rete di casa
(`sync_net.bussa`), sempre più di rado finché non ricompare. Il telefono
risponde solo quando VaultMind è aperto e sbloccato, quindi «apri l'app sul
telefono» è tutto quello che serve per sincronizzare.

Ogni lato ha un **gettone**: il PC il contatore delle scritture del vault, il
telefono un valore a caso che rinnova a ogni modifica. Se nessuno dei due è
cambiato dall'ultima volta lo scambio finisce lì, in un messaggio. Altrimenti
il telefono manda il suo contenuto, il PC fonde (vince l'ultima modifica),
scrive se c'è qualcosa di nuovo, e rimanda il risultato; il telefono lo adotta
solo se nel frattempo non è cambiato niente, se no si riprova al giro dopo.
Solo il PC fonde: due fusioni non possono pestarsi i piedi.
"""

from __future__ import annotations
import socket
import threading
import time
from typing import Callable, Dict, List, Optional, Tuple

from . import merge, qr, sync_net, sync_protocol as sp
from .crypto_store import Credential, VaultStore, _clean_categories

#: Ogni quanto si chiama un telefono che risponde.
INTERVALLO_S = 5.0
#: Un telefono che non risponde lo si cerca nella rete dopo questa pausa, che
#: raddoppia a ogni ricerca vuota fino a PAUSA_MAX_S: bussare a 254 indirizzi
#: ogni 5 secondi per un telefono che è fuori casa sarebbe rumore per niente.
PAUSA_RICERCA_S = 5.0
PAUSA_MAX_S = 120.0
#: Per quanto vale il QR. Abbastanza per trovare la schermata sul telefono.
VALIDITA_QR_S = 600
#: Dove stanno, nella radice del vault, i telefoni collegati e le loro chiavi.
RADICE = "sync_telefoni"


def _nome_predefinito() -> str:
    """«PC di <nome del computer>», tranne quando il nome è uno di quelli che
    Windows inventa (DESKTOP-4F7G2K1): sul telefono non direbbe niente."""
    try:
        h = socket.gethostname().strip()
    except OSError:
        h = ""
    if not h or h.upper().startswith(("DESKTOP-", "LAPTOP-", "WIN-")):
        return "PC"
    return f"PC {h}"[:40]


class SyncApp:
    """Il sync di questo PC. Uno solo per processo."""

    def __init__(self, store_di: Callable[[], Optional[VaultStore]],
                 leggi_impostazioni: Callable[[], dict],
                 salva_impostazioni: Callable[[dict], None],
                 porta: int = sync_net.PORTA_SYNC,
                 dopo_fusione: Optional[Callable[[], None]] = None,
                 reti: Optional[Callable[[], List[List[str]]]] = None,
                 automatico: bool = True):
        self._store_di = store_di
        self._leggi = leggi_impostazioni
        self._salva = salva_impostazioni
        #: Chiamata quando il sync ha cambiato il vault: il server rifà
        #: l'indice della ricerca, altrimenti una voce arrivata dal telefono
        #: c'è ma la chat non la trova.
        self._dopo_fusione = dopo_fusione
        # Porta e reti a parametro solo per i test: un telefono finto su
        # 127.0.0.1, su una porta che non disturba l'app vera.
        self._porta = porta
        self._reti = reti or sync_net.reti_locali
        #: False nei test: il giro lo chiamano loro, quando vogliono, invece
        #: di un filo che parte da solo ogni pochi secondi.
        self._automatico = automatico

        self._lucchetto = threading.RLock()   # un giro alla volta
        self._sveglia = threading.Event()
        #: Uno per filo: un filo vecchio che sta finendo uno scambio non deve
        #: ripartire quando se ne avvia uno nuovo.
        self._fermo = threading.Event()
        self._filo: Optional[threading.Thread] = None
        self._rinvio: Optional[threading.Timer] = None

        #: Il QR mostrato in questo momento: {"chiave", "scade", "collegato"}.
        self._attesa: Optional[dict] = None
        #: Per telefono: (gettone del telefono, gettone del PC) all'ultimo
        #: scambio riuscito. In memoria: dopo un riavvio il primo giro fa uno
        #: scambio completo, che è giusto.
        self._visti: Dict[str, Tuple[str, Tuple[int, int]]] = {}
        #: Per telefono, cosa dire nella sezione Sincronizza.
        self._esiti: Dict[str, dict] = {}
        self._prossima_ricerca = 0.0
        self._pausa = PAUSA_RICERCA_S

        #: Cresce di uno ogni volta che il sync cambia il vault: la pagina lo
        #: guarda (`/api/sync/novita`) per ricaricare le voci arrivate.
        self.revisione = 0
        #: L'ultimo sync che ha portato qualcosa, per la riga sotto il pulsante.
        self.ultimo: Optional[dict] = None

    # ----------------------------------------------------------- impostazioni

    def _sez(self) -> dict:
        s = self._leggi()
        sync = dict(s.get("sync") or {})
        cambiato = False
        if not sync.get("id"):
            sync["id"] = sp.id_dispositivo()
            cambiato = True
        if not sync.get("nome") or sync.get("nome") == "Questo PC":
            # «Questo PC» era il nome predefinito di prima: sul telefono, dove
            # ora compare, vorrebbe dire il telefono stesso.
            sync["nome"] = _nome_predefinito()
            cambiato = True
        sync.setdefault("acceso", True)
        if not isinstance(sync.get("telefoni"), dict):
            sync["telefoni"] = {}
            cambiato = True
        # Le chiavi del sync di prima (dispositivi, basi) non servono più e
        # non si lasciano in giro: dicevano con chi ci si era abbinati.
        for vecchia in ("dispositivi", "basi"):
            if vecchia in sync:
                sync.pop(vecchia)
                cambiato = True
        if cambiato:
            self._scrivi_sez(sync)
        return sync

    def _scrivi_sez(self, sync: dict) -> None:
        s = self._leggi()
        s["sync"] = sync
        self._salva(s)

    def _aggiorna_telefono(self, tid: str, **campi) -> None:
        sync = self._sez()
        t = dict(sync["telefoni"].get(tid) or {})
        if all(t.get(k) == v for k, v in campi.items()):
            return   # già così: niente riscrittura delle impostazioni
        t.update(campi)
        sync["telefoni"][tid] = t
        self._scrivi_sez(sync)

    @property
    def id_dispositivo(self) -> str:
        return self._sez()["id"]

    @property
    def nome(self) -> str:
        return self._sez()["nome"]

    @property
    def acceso(self) -> bool:
        return bool(self._sez().get("acceso", True))

    def imposta(self, nome: Optional[str] = None, acceso: Optional[bool] = None) -> dict:
        sync = self._sez()
        if nome is not None and nome.strip():
            sync["nome"] = " ".join(nome.split())[:40]
        if acceso is not None:
            sync["acceso"] = bool(acceso)
        self._scrivi_sez(sync)
        # Spegnerlo deve fermarlo subito: chi lo spegne di solito è preoccupato.
        if self.acceso:
            self.avvia()
        else:
            self.ferma()
        return sync

    # -------------------------------------------------------------- i telefoni

    def _store(self) -> Optional[VaultStore]:
        store = self._store_di()
        if store is None or not store.unlocked:
            return None
        return store

    def _collegati(self, store: VaultStore) -> Dict[str, dict]:
        """{id: {"nome", "chiave": bytes}} dalla radice del vault. Una voce
        scritta male si salta: un telefono illeggibile non vale il sync degli
        altri."""
        fuori: Dict[str, dict] = {}
        grezzi = store.radice(RADICE)
        if not isinstance(grezzi, dict):
            return fuori
        for tid, t in grezzi.items():
            try:
                chiave = bytes.fromhex(str(t["chiave"]))
                if len(chiave) == sp.LUNGHEZZA_CHIAVE:
                    fuori[str(tid)] = {"nome": str(t.get("nome") or "Telefono"),
                                       "chiave": chiave}
            except Exception:
                continue
        return fuori

    def _registra(self, store: VaultStore, tid: str, nome: str, chiave: bytes) -> None:
        grezzi = store.radice(RADICE)
        grezzi = dict(grezzi) if isinstance(grezzi, dict) else {}
        grezzi[tid] = {"nome": nome, "chiave": chiave.hex()}
        store.imposta_radice(RADICE, grezzi)

    def telefoni(self) -> List[dict]:
        store = self._store()
        if store is None:
            return []
        sez = self._sez()["telefoni"]
        fuori = []
        for tid, t in self._collegati(store).items():
            fuori.append({"id": tid, "nome": t["nome"],
                          "indirizzo": (sez.get(tid) or {}).get("indirizzo") or "",
                          "quando": (sez.get(tid) or {}).get("quando") or 0,
                          **(self._esiti.get(tid) or {"esito": "attesa"})})
        return fuori

    def scollega(self, tid: str) -> bool:
        store = self._store()
        if store is None:
            return False
        with self._lucchetto:
            grezzi = store.radice(RADICE)
            if not isinstance(grezzi, dict) or tid not in grezzi:
                return False
            grezzi = {k: v for k, v in grezzi.items() if k != tid}
            store.imposta_radice(RADICE, grezzi or None)
            sync = self._sez()
            sync["telefoni"].pop(tid, None)
            self._scrivi_sez(sync)
            self._visti.pop(tid, None)
            self._esiti.pop(tid, None)
        return True

    # -------------------------------------------------------------- il QR

    def inizia_collegamento(self) -> dict:
        """Una chiave nuova e il QR che la porta. Vale finché la finestra
        resta aperta (al massimo VALIDITA_QR_S), e per un telefono solo."""
        if self._store() is None:
            raise sync_net.RifiutoSync("Il vault è chiuso.")
        if not self.acceso:
            self.imposta(acceso=True)   # chi collega un telefono vuole il sync
        chiave = sp.nuova_chiave()
        self._attesa = {"chiave": chiave, "scade": time.time() + VALIDITA_QR_S,
                        "collegato": None}
        uri = sp.uri_abbinamento(self.id_dispositivo, self.nome, chiave)
        self._prossima_ricerca = 0.0
        self.avvia()
        self._sveglia.set()
        return {"uri": uri, "svg": qr.svg(uri), "secondi": VALIDITA_QR_S}

    def stato_collegamento(self) -> Optional[dict]:
        a = self._attesa
        if a is None:
            return None
        if a["collegato"] is None and time.time() > a["scade"]:
            self._attesa = None
            return {"scaduto": True}
        return {"collegato": a["collegato"],
                "secondi": max(0, int(a["scade"] - time.time()))}

    def ferma_collegamento(self) -> None:
        self._attesa = None

    # ------------------------------------------------------ accendi / spegni

    def avvia(self) -> bool:
        """Fa partire il giro. Da chiamare dopo lo sblocco; ripeterlo non fa
        danni. Il PC non apre nessuna porta: chiama e basta."""
        with self._lucchetto:
            if not self.acceso or self._store() is None:
                return False
            if not self._automatico:
                return True
            if self._filo is not None and self._filo.is_alive()                     and not self._fermo.is_set():
                return True
            self._fermo = threading.Event()
            self._filo = threading.Thread(target=self._ciclo, args=(self._fermo,),
                                          name="sync", daemon=True)
            self._filo.start()
            return True

    def ferma(self) -> None:
        """Ferma il giro. Da chiamare quando il vault si blocca."""
        self._fermo.set()
        self._sveglia.set()
        if self._rinvio is not None:
            self._rinvio.cancel()
            self._rinvio = None
        filo = self._filo
        if filo is not None and filo is not threading.current_thread():
            # Breve: chi blocca il vault non deve aspettare uno scambio a metà.
            # Il filo finisce da solo, e col vault chiuso non tocca più niente.
            filo.join(timeout=2)
        self._filo = None
        self._attesa = None
        self._visti.clear()

    def riavvia(self) -> bool:
        self.ferma()
        return self.avvia()

    @property
    def in_ascolto(self) -> bool:
        """Il giro sta girando (il nome è quello di prima, per la pagina)."""
        return self._filo is not None and self._filo.is_alive()

    def programma_sync(self, ritardo: float = 1.5) -> None:
        """Una modifica sul PC parte subito verso i telefoni, senza aspettare
        il giro. Il rinvio raccoglie le modifiche a raffica (salva, cambia
        categoria, salva) in un solo scambio. Non solleva mai."""
        if self._rinvio is not None:
            self._rinvio.cancel()
        t = threading.Timer(ritardo, self._sveglia.set)
        t.daemon = True
        self._rinvio = t
        t.start()

    def _ciclo(self, fermo: threading.Event) -> None:
        while not fermo.is_set():
            try:
                self.giro()
            except Exception:
                pass   # il sync di sfondo non deve mai far cadere niente
            # Col QR aperto si cerca di continuo: chi ha appena inquadrato
            # aspetta di vedere «collegato», non cinque secondi.
            attesa = 1.0 if self._attesa and not self._attesa["collegato"] else INTERVALLO_S
            self._sveglia.wait(attesa)
            self._sveglia.clear()

    # ------------------------------------------------------------- il lavoro

    def sincronizza_adesso(self) -> dict:
        """Il pulsante: un giro subito, cercando anche chi non risponde."""
        if self._store() is None:
            return {"ok": False, "motivo": "Il vault è chiuso.", "esiti": []}
        self._prossima_ricerca = 0.0
        self._pausa = PAUSA_RICERCA_S
        self.giro()
        self.avvia()
        return {"ok": True, "telefoni": self.telefoni()}

    def giro(self) -> None:
        store = self._store()
        if store is None or not self.acceso:
            return
        with self._lucchetto:
            collegati = self._collegati(store)
            sez = self._sez()["telefoni"]
            mancanti = []
            for tid, t in collegati.items():
                ind = (sez.get(tid) or {}).get("indirizzo")
                if ind and self._prova(store, ind, t["chiave"], tid):
                    continue
                mancanti.append(tid)
            attesa = self._attesa
            cerca_nuovo = bool(attesa and not attesa["collegato"]
                               and time.time() <= attesa["scade"])
            if not (mancanti or cerca_nuovo):
                self._pausa = PAUSA_RICERCA_S
                return
            if not cerca_nuovo and time.time() < self._prossima_ricerca:
                return
            self._cerca(store, collegati, mancanti, cerca_nuovo)

    def _cerca(self, store: VaultStore, collegati: Dict[str, dict],
               mancanti: List[str], cerca_nuovo: bool) -> None:
        for rete in self._reti():
            for h in sync_net.bussa(rete, self._porta):
                if cerca_nuovo and self._attesa:
                    if self._prova(store, h, self._attesa["chiave"], None):
                        cerca_nuovo = False
                        continue
                for tid in list(mancanti):
                    if self._prova(store, h, collegati[tid]["chiave"], tid):
                        mancanti.remove(tid)
                        break
            if not mancanti and not cerca_nuovo:
                break
        if mancanti:
            self._prossima_ricerca = time.time() + self._pausa
            self._pausa = min(self._pausa * 2, PAUSA_MAX_S)
        else:
            self._pausa = PAUSA_RICERCA_S
            self._prossima_ricerca = 0.0

    def _prova(self, store: VaultStore, host: str, chiave: bytes,
               atteso: Optional[str]) -> bool:
        """Uno scambio con chi risponde a `host`. Vero se era il telefono
        cercato (`atteso`, o un telefono nuovo se `atteso` è None), anche se
        poi lo scambio non è andato fino in fondo: l'indirizzo è quello."""
        try:
            with sync_net.Collegamento.apri(host, self._porta, chiave) as c:
                return self._scambio(store, c, host, chiave, atteso)
        except sync_net.Rifiutato as exc:
            if atteso and exc.motivo == "pc":
                self._esiti[atteso] = {
                    "esito": "sconosciuto",
                    "messaggio": "Il telefono non riconosce più questo PC: "
                                 "scollegalo qui e ricollegalo col QR."}
                return True
            return False
        except sync_net.NonRaggiungibile:
            if atteso:
                self._esiti[atteso] = {
                    "esito": "assente",
                    "messaggio": "Non risponde: apri VaultMind sul telefono, "
                                 "sulla stessa WiFi."}
            return False

    def _scambio(self, store: VaultStore, c: sync_net.Collegamento, host: str,
                 chiave: bytes, atteso: Optional[str]) -> bool:
        mezza = sp.nuova_meta_sessione()
        c.manda({"t": "ciao", "nome": self.nome, "s": mezza},
                intestazione={"v": sp.VERSIONE, "pc": self.id_dispositivo})
        stato = c.ricevi()
        sessione = str(stato.get("s") or "")
        tid = str(stato.get("id") or "")
        if (stato.get("t") != "stato" or len(sessione) != 32
                or not sessione.startswith(mezza) or not tid):
            raise sync_net.Rifiutato("protocollo")
        if atteso is not None and tid != atteso:
            return False   # un altro dei nostri telefoni, con la stessa chiave: impossibile, ma non è lui
        nome = " ".join(str(stato.get("nome") or "Telefono").split())[:40] or "Telefono"

        if atteso is None:
            # Il telefono ha inquadrato il QR: da qui è collegato.
            self._registra(store, tid, nome, chiave)
            if self._attesa is not None:
                self._attesa["collegato"] = {"id": tid, "nome": nome}
        elif self._collegati(store).get(tid, {}).get("nome") != nome:
            self._registra(store, tid, nome, chiave)   # ha cambiato nome

        self._aggiorna_telefono(tid, indirizzo=host)

        def manda(dati: dict) -> None:
            c.manda({**dati, "s": sessione})

        def ricevi(tipo: str) -> dict:
            r = c.ricevi()
            if r.get("s") != sessione or r.get("t") not in tipo.split("|"):
                raise sync_net.Rifiutato("protocollo")
            return r

        gettone = str(stato.get("token") or "")
        mio = (id(store), store.scritture)
        if self._visti.get(tid) == (gettone, mio):
            manda({"t": "fine"})
            self._esiti[tid] = {"esito": "allineato", "controllato": int(time.time())}
            return True

        manda({"t": "dammi"})
        v = ricevi("vault")
        try:
            tel = merge.Istantanea(
                entries=[Credential.from_dict(x) for x in v["voci"]],
                tombstones=[dict(t) for t in v.get("lapidi") or []],
                categories=_clean_categories(v.get("categorie") or []),
            )
        except Exception as exc:
            # Mai una fusione con metà delle voci del telefono: quelle che non
            # si leggono sparirebbero dal telefono quando adotta il risultato.
            raise sync_net.Rifiutato("protocollo", "Il telefono ha mandato voci illeggibili.") from exc
        gettone = str(v.get("token") or "")

        prima = store.scritture
        pc = merge.Istantanea(store.entries, store.tombstones, store.categories)
        info = self._sez()["telefoni"].get(tid) or {}
        base = info.get("categorie")
        f = merge.fondi(pc, tel, base if isinstance(base, list) else None,
                        primo=not info.get("quando"))
        risultato = merge.Istantanea(f.entries, f.tombstones, f.categories)

        cambiato_pc = not merge.uguali(risultato, pc)
        if cambiato_pc:
            if store.scritture != prima:
                return True   # hai salvato qualcosa nel frattempo: si rifà al giro dopo
            store.applica_fusione(f.entries, f.tombstones, f.categories)
            self.revisione += 1

        finale: Optional[str] = gettone
        if merge.uguali(risultato, tel):
            manda({"t": "uguale"})
        else:
            manda({"t": "prendi", "base": gettone,
                   "voci": [e.to_dict() for e in f.entries],
                   "lapidi": f.tombstones, "categorie": f.categories,
                   "riepilogo": f.sul_telefono})
            r = ricevi("preso|cambiato")
            finale = str(r.get("token") or "") if r["t"] == "preso" else None

        adesso = int(time.time())
        if finale:
            self._visti[tid] = (finale, (id(store), store.scritture))
            self._aggiorna_telefono(tid, quando=adesso, categorie=f.categories)
        else:
            # Il telefono è cambiato mentre si fondeva: si riprova fra poco.
            self._visti.pop(tid, None)
            self._sveglia.set()
        portato = any(f.sul_pc.values())
        self._esiti[tid] = {"esito": "sincronizzato" if portato or any(f.sul_telefono.values())
                            else "allineato",
                            "controllato": adesso,
                            "sul_pc": f.sul_pc, "sul_telefono": f.sul_telefono}
        if portato:
            self.ultimo = {"con": nome, "quando": adesso, **f.sul_pc}
        if cambiato_pc:
            self._avvisa()
        return True

    def _avvisa(self) -> None:
        if self._dopo_fusione is None:
            return
        try:
            self._dopo_fusione()
        except Exception:
            pass   # il dato è già salvato: l'indice si rifà al prossimo giro
