"""
sync_app.py — La colla fra il motore del sync e l'app.

`sync_protocol` decide di chi fidarsi, `sync_net` porta i byte, `merge` decide
cosa vince. Qui si mettono insieme: si tiene l'identità del dispositivo, si
apre e si chiude l'ascoltatore insieme al vault, e si trasforma un vault
ricevuto in una fusione applicata.

## Cosa sta su disco e cosa no

Nelle impostazioni finiscono **id del dispositivo, nome, elenco dei fidati e
basi** — e nient'altro. Le chiavi per parlare con ciascun dispositivo si
ricavano dalla chiave del vault (vedi `sync_protocol.chiave_verso`), quindi non
c'è nessun segreto nuovo da custodire.

La **base** è `{uid: rev}` all'ultimo sync riuscito con quel dispositivo: è ciò
che permette di distinguere «sono più avanti di te» da «siamo divergiti». È un
dato derivato, sta fuori dal vault e non viaggia col backup.

I **conflitti in sospeso** stanno solo in memoria, di proposito. Se l'app si
chiude prima che tu abbia deciso, le voci restano com'erano e al sync successivo
il conflitto si ripresenta identico — perché la base esclude proprio le voci
contese. Nessuno stato da riparare a mano.
"""

from __future__ import annotations
import threading
import time
from typing import Callable, Dict, List, Optional

from . import merge, sync_net, sync_protocol as sp
from .crypto_store import Credential, VaultStore, WrongPassword, VaultCorrupted, apri_blob


class SyncApp:
    """Il sync di questo dispositivo. Uno solo per processo."""

    def __init__(self, store_di: Callable[[], Optional[VaultStore]],
                 leggi_impostazioni: Callable[[], dict],
                 salva_impostazioni: Callable[[dict], None],
                 porta: int = sync_net.PORTA_SYNC,
                 porta_scoperta: int = sync_net.PORTA_SCOPERTA):
        self._store_di = store_di
        self._leggi = leggi_impostazioni
        self._salva = salva_impostazioni
        # Porte a parametro solo per i test, che devono far convivere due
        # dispositivi finti sullo stesso computer.
        self._porta = porta
        self._porta_scoperta = porta_scoperta
        self._ascoltatore: Optional[sync_net.Ascoltatore] = None
        self._annunciatore: Optional[sync_net.Annunciatore] = None
        self._lucchetto = threading.Lock()

        #: Codice di abbinamento in corso: (codice, scadenza, tentativi).
        self._codice: Optional[str] = None
        self._scade: float = 0.0
        self._tentativi: int = 0

        #: Conflitti da decidere, per uid, con l'id del dispositivo da cui sono
        #: nati: serve a registrare la scelta nella base giusta.
        self.conflitti: Dict[str, merge.Conflitto] = {}
        self._da_chi: Dict[str, str] = {}
        #: L'ultimo esito, da mostrare nella sezione Sincronizza.
        self.ultimo: Optional[dict] = None

    # ----------------------------------------------------------- impostazioni

    def _sez(self) -> dict:
        s = self._leggi()
        sync = dict(s.get("sync") or {})
        cambiato = False
        if not sync.get("id"):
            sync["id"] = sp.id_dispositivo()
            cambiato = True
        if not sync.get("nome"):
            sync["nome"] = "Questo PC"
            cambiato = True
        sync.setdefault("acceso", True)
        sync.setdefault("dispositivi", {})
        sync.setdefault("basi", {})
        if cambiato:
            self._scrivi_sez(sync)
        return sync

    def _scrivi_sez(self, sync: dict) -> None:
        s = self._leggi()
        s["sync"] = sync
        self._salva(s)

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
            sync["nome"] = nome.strip()[:40]
        if acceso is not None:
            sync["acceso"] = bool(acceso)
        self._scrivi_sez(sync)
        # Accendere o spegnere il sync deve avere effetto subito, non al
        # prossimo avvio: chi lo spegne di solito lo fa perché è preoccupato.
        self.riavvia()
        return sync

    def dispositivi(self) -> List[dict]:
        sync = self._sez()
        return [{"id": i, **d} for i, d in (sync.get("dispositivi") or {}).items()]

    def revoca(self, id_peer: str) -> bool:
        sync = self._sez()
        if id_peer not in (sync.get("dispositivi") or {}):
            return False
        sync["dispositivi"].pop(id_peer, None)
        # Via anche la base: se un giorno si riabbina, si riparte prudenti
        # invece che con una fotografia vecchia di cui non ci si può più fidare.
        (sync.get("basi") or {}).pop(id_peer, None)
        self._scrivi_sez(sync)
        return True

    def _abbina(self, id_peer: str, nome: str) -> None:
        sync = self._sez()
        sync.setdefault("dispositivi", {})[id_peer] = {
            "nome": nome or "dispositivo",
            "quando": int(time.time()),
        }
        self._scrivi_sez(sync)

    # ------------------------------------------------------------ abbinamento

    def codice_attivo(self) -> Optional[str]:
        """Il codice, se è ancora valido. Scade da solo dopo 120 secondi e dopo
        5 tentativi sbagliati: una finestra che resta aperta è una finestra."""
        if self._codice and time.time() < self._scade and self._tentativi < sp.TENTATIVI_MAX:
            return self._codice
        self._codice = None
        return None

    def apri_abbinamento(self) -> dict:
        self._codice = sp.codice_abbinamento()
        self._scade = time.time() + sp.VALIDITA_CODICE_S
        self._tentativi = 0
        return {"codice": self._codice, "secondi": sp.VALIDITA_CODICE_S}

    def chiudi_abbinamento(self) -> None:
        self._codice = None

    # ----------------------------------------------------------- il contesto

    def _contesto(self) -> Optional[sync_net.ContestoSync]:
        store = self._store_di()
        if store is None or not store.unlocked or store.chiave is None:
            return None
        sync = self._sez()
        ctx = sync_net.ContestoSync(
            id_dispositivo=sync["id"],
            nome=sync["nome"],
            chiave_vault=store.chiave,
            # Non una fotografia: l'elenco cambia mentre l'ascoltatore è già
            # aperto, ed è proprio quello che succede al primo abbinamento.
            fidati_ora=lambda: dict((self._sez().get("dispositivi") or {})),
            leggi_vault_cifrato=lambda: _leggi_file(store.path),
            ricevi_vault=self.ricevi_vault,
            salt_vault=store.salt or b"",
            codice_attivo=self.codice_attivo,
        )
        ctx.abbina = self._abbina
        return ctx

    # ------------------------------------------------------- accendi / spegni

    def avvia(self) -> bool:
        """Apre l'ascoltatore. Da chiamare **dopo** lo sblocco: senza chiave non
        c'è niente da sincronizzare, e infatti non si apre nessuna porta."""
        with self._lucchetto:
            self._ferma_dentro()
            if not self.acceso:
                self._codice = None   # spento il sync, si chiude anche la finestra
                return False
            ctx = self._contesto()
            if ctx is None:
                return False
            a = sync_net.Ascoltatore(ctx, porta=self._porta)
            a.start()
            if not a.pronto.wait(3):
                a.ferma()
                return False
            self._ascoltatore = a
            ann = sync_net.Annunciatore(ctx, porta=self._porta_scoperta,
                                        porta_sync=a.porta_vera)
            ann.start()
            self._annunciatore = ann
            return True

    def ferma(self) -> None:
        """Chiude tutto. Da chiamare quando il vault si blocca: da quel momento
        la chiave non c'è più, e restare in ascolto sarebbe solo una porta
        aperta che non serve a niente."""
        with self._lucchetto:
            self._ferma_dentro()
            # Chiuso il vault, una finestra di abbinamento aperta non ha piu'
            # senso: la chiave non c'e' piu' e non si potrebbe dimostrare nulla.
            self._codice = None

    def _ferma_dentro(self) -> None:
        """Chiude solo i thread. **Non tocca il codice**: `avvia()` passa di
        qui per essere ripetibile, e cancellare il codice li' voleva dire
        buttare via quello che l'utente stava leggendo sullo schermo."""
        if self._annunciatore:
            self._annunciatore.ferma()
            self._annunciatore = None
        if self._ascoltatore:
            self._ascoltatore.ferma()
            self._ascoltatore = None

    def riavvia(self) -> bool:
        return self.avvia()   # avvia() chiude già quello che c'è

    @property
    def in_ascolto(self) -> bool:
        return self._ascoltatore is not None

    @property
    def porta_vera(self) -> int:
        return self._ascoltatore.porta_vera if self._ascoltatore else self._porta

    # ------------------------------------------------------------- il lavoro

    def cerca(self) -> List[dict]:
        ctx = self._contesto()
        if ctx is None:
            return []
        trovati = sync_net.cerca_dispositivi(ctx)
        noti = self._sez().get("dispositivi") or {}
        for t in trovati:
            t["conosciuto"] = t["id"] in noti
            if t["conosciuto"]:
                t["nome"] = noti[t["id"]].get("nome") or t["nome"]
        return trovati

    def sincronizza_con(self, indirizzo: str, porta: int, codice: str = "") -> dict:
        ctx = self._contesto()
        if ctx is None:
            raise sync_net.RifiutoSync("Il vault è chiuso.")
        esito = sync_net.sincronizza(ctx, indirizzo, porta, codice)
        self.ultimo = esito
        return esito

    def ricevi_vault(self, blob: str, id_peer: str) -> dict:
        """Il cuore: prende il vault dell'altro, lo fonde col nostro e applica.

        Quello che arriva è cifrato con la stessa chiave che abbiamo — l'ha
        appena dimostrato la stretta di mano — quindi si apre come si aprirebbe
        il proprio file. In chiaro sulla rete non è passato niente.
        """
        store = self._store_di()
        if store is None or not store.unlocked or store.chiave is None:
            return {"errore": "vault chiuso"}
        try:
            dati = apri_blob(blob, store.chiave)
        except WrongPassword:
            return {"errore": "I due vault hanno master password diverse."}
        except VaultCorrupted:
            return {"errore": "Il vault ricevuto non è leggibile."}

        sua = merge.Istantanea(
            entries=[Credential.from_dict(c) for c in (dati.get("credentials") or [])],
            tombstones=list(dati.get("deleted") or []),
            categories=list(dati.get("categories") or []),
        )
        mia = merge.Istantanea(entries=store.entries,
                               tombstones=store.tombstones,
                               categories=store.categories)

        sync = self._sez()
        base = (sync.get("basi") or {}).get(id_peer)
        f = merge.fondi(mia, sua, base)

        store.applica_fusione(f.entries, f.tombstones, f.categories)

        # La base registra solo ciò su cui siamo d'accordo: le voci contese
        # restano fuori, così al prossimo giro risultano ancora cambiate da
        # entrambi e il conflitto si ripresenta invece di sparire non deciso.
        contesi = {c.uid for c in f.conflitti}
        sync.setdefault("basi", {})[id_peer] = {
            c.uid: c.rev for c in f.entries if c.uid not in contesi
        }
        self._scrivi_sez(sync)

        self.conflitti = {c.uid: c for c in f.conflitti}
        self._da_chi = {c.uid: id_peer for c in f.conflitti}
        riepilogo = {
            "aggiunte": f.riepilogo.get("aggiunte", 0),
            "aggiornate": f.riepilogo.get("aggiornate", 0),
            "cancellate": f.riepilogo.get("cancellate", 0),
            "conflitti": len(f.conflitti),
            "quando": int(time.time()),
        }
        self.ultimo = riepilogo
        return riepilogo

    # ------------------------------------------------------------- conflitti

    def elenco_conflitti(self) -> List[dict]:
        fuori = []
        for c in self.conflitti.values():
            fuori.append({
                "uid": c.uid,
                "motivo": c.motivo,
                "titolo": c.titolo,
                "mia": _sommario(c.mia),
                "sua": _sommario(c.sua),
            })
        return fuori

    def risolvi(self, uid: str, scelta: str) -> bool:
        """`scelta` = "mia" | "sua". Applica la versione scelta e chiude il caso.

        Non esiste "decidi tu": la voce contesa è l'unica cosa che questo
        progetto non risolve da solo, e cambiare idea qui vorrebbe dire buttare
        una password senza che nessuno l'abbia deciso.
        """
        c = self.conflitti.get(uid)
        store = self._store_di()
        if c is None or store is None or not store.unlocked:
            return False
        tenuta = c.mia if scelta == "mia" else c.sua

        voci = [v for v in store.entries if v.uid != uid]
        lapidi = [t for t in store.tombstones if t.get("uid") != uid]
        if tenuta is not None:
            # Un giro di contatore in più: la scelta è essa stessa una modifica,
            # e deve battere quella dell'altro dispositivo al prossimo sync.
            scelto = Credential.from_dict(tenuta.to_dict())
            scelto.tocca()
            voci.append(scelto)
        else:
            base = c.mia or c.sua
            lapidi.append({"uid": uid, "rev": (base.rev if base else 1) + 1,
                           "mod": int(time.time() * 1000)})

        store.applica_fusione(voci, lapidi, store.categories)

        # Il pezzo che fa **convergere** la scelta. Senza, la voce resterebbe
        # "cambiata da entrambi" per sempre e la stessa domanda tornerebbe a
        # ogni sync: registrando nella base il `rev` che l'altro aveva, al
        # prossimo giro lui risulta fermo e la mia decisione vince da sola.
        id_peer = self._da_chi.pop(uid, None)
        if id_peer and c.rev_sua:
            sync = self._sez()
            sync.setdefault("basi", {}).setdefault(id_peer, {})[uid] = c.rev_sua
            self._scrivi_sez(sync)

        self.conflitti.pop(uid, None)
        return True


def _sommario(c: Optional[Credential]) -> Optional[dict]:
    """Come si racconta una versione all'utente: titolo, quando, e le
    ETICHETTE dei campi — mai i valori. Scegliere fra due versioni non deve
    costringere a guardare due password sullo schermo."""
    if c is None:
        return None
    return {"titolo": c.title, "rev": c.rev, "mod": c.mod,
            "categoria": c.category, "tags": list(c.tags),
            "campi": [f.label for f in c.fields], "critica": c.critical}


def _leggi_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()
