"""
sync_protocol.py — Abbinamento e autenticazione fra dispositivi. Senza socket.

Qui c'è **solo il ragionamento**: come due dispositivi si dimostrano di essere
tuoi, come si accorgono di qualcuno in mezzo, e come si riconoscono le volte
successive. La rete sta in `sync_net.py`, la fusione dei dati in `merge.py`.
Tenerli separati serve a poter provare questa parte con dei vettori invece che
con due telefoni veri.

Esiste identico in Dart (`mobile/lib/sync_protocollo.dart`), legato a questo dal
vettore `tests/vettore/sync.json`: se le due implementazioni calcolassero prove
diverse, l'abbinamento fallirebbe sempre e nessun test se ne accorgerebbe.

## L'idea, in una riga

**Il segreto condiviso c'è già.** Due dispositivi che aprono lo stesso vault
derivano la stessa chiave a 256 bit dalla master password. Non serve inventare
uno scambio di chiavi: basta dimostrare di saperla, senza mai trasmetterla.

## Cosa protegge, e cosa no

Il confine della sicurezza è **la master password**. Chi la conosce possiede il
vault, punto — e quindi può anche abbinare un dispositivo. L'elenco dei
dispositivi fidati non difende da lui: serve a te, per decidere e per revocare.

Da questo discende una scelta che evita un problema intero: le chiavi per
parlare con ciascun dispositivo **non si generano e non si salvano**, si
ricavano al volo dalla chiave del vault. Sul disco resta un elenco di nomi e
date. Non c'è nessun segreto nuovo da custodire, da rubare o da dimenticare.

## Il codice e l'impronta

Il **codice** di 6 cifre, mostrato su uno schermo e scritto sull'altro, dice
*quale* dispositivo stai abbinando: entra nel calcolo delle prove, quindi
abbinarsi col dispositivo sbagliato non riesce, fallisce.

L'**impronta di sessione** — sei cifre uguali sui due schermi — è la verifica
finale, quella che si fa con l'occhio. Con un segreto condiviso forte nessuno
può mettersi in mezzo, ma è la cosa che rende la promessa *controllabile*
invece che solo dichiarata. È il gesto che fanno Signal e WhatsApp.
"""

from __future__ import annotations
import hashlib
import hmac
import os
import secrets
from typing import Tuple

#: Cifre del codice di abbinamento e dell'impronta.
CIFRE_CODICE = 6
#: Quanto vive un codice di abbinamento. Oltre, si rigenera.
VALIDITA_CODICE_S = 120
#: Tentativi ammessi su uno stesso codice, poi si butta.
TENTATIVI_MAX = 5

#: Etichette del protocollo. Cambiarne una rompe l'abbinamento fra versioni
#: diverse: è voluto, perché una versione che calcola prove diverse deve
#: fallire subito e non a metà di un trasferimento.
_INFO_SESSIONE = b"vaultmind-sync-v1"
_INFO_PEER = b"vaultmind-peer-v1"


def _hkdf(ikm: bytes, salt: bytes, info: bytes, lunghezza: int = 32) -> bytes:
    """HKDF-SHA256 (RFC 5869), scritto a mano sulla libreria standard.

    Non si usa quello di `cryptography` per non aggiungere un import che
    PyInstaller dovrebbe poi ritrovare: `hmac` e `hashlib` ci sono sempre, anche
    dentro l'exe. L'algoritmo è standard, quindi Dart ottiene gli stessi byte.
    """
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    fuori, blocco, i = b"", b"", 1
    while len(fuori) < lunghezza:
        blocco = hmac.new(prk, blocco + info + bytes([i]), hashlib.sha256).digest()
        fuori += blocco
        i += 1
    return fuori[:lunghezza]


def _cifre(dato: bytes, quante: int) -> str:
    """Trasforma dei byte in cifre decimali, per farle leggere a una persona.

    **Sei byte, non otto.** Gli interi di Python non hanno limite, quelli di
    Dart sono a 64 bit con segno: otto byte diventerebbero negativi di là, e le
    due implementazioni mostrerebbero codici diversi senza che niente si rompa
    in modo evidente. Con sei byte (2^48) ci stanno larghi tutti e due.
    """
    n = int.from_bytes(dato[:6], "big") % (10 ** quante)
    return str(n).zfill(quante)


# ------------------------------------------------------------------ sessione

def nonce() -> bytes:
    """Numero usato una volta sola. Ogni abbinamento ne genera uno per parte:
    è ciò che impedisce di riusare una conversazione registrata ieri."""
    return secrets.token_bytes(16)


def codice_abbinamento() -> str:
    """Le sei cifre da mostrare. `secrets` e non `random`: un codice
    indovinabile vanificherebbe il fatto stesso di chiederlo."""
    return _cifre(secrets.token_bytes(8), CIFRE_CODICE)


def chiave_sessione(chiave_vault: bytes, nonce_a: bytes, nonce_b: bytes) -> bytes:
    """La chiave valida per QUESTO abbinamento.

    Nasce dalla chiave del vault più i due nonce: cambia a ogni sessione, e
    conoscerne una non aiuta con le altre.
    """
    return _hkdf(chiave_vault, nonce_a + nonce_b, _INFO_SESSIONE)


def prova(sessione: bytes, ruolo: str, codice: str) -> str:
    """La dimostrazione di conoscere la chiave del vault, senza mostrarla.

    Il `ruolo` ("A" per chi mostra il codice, "B" per chi lo scrive) fa sì che
    le due prove siano diverse: senza, chi riceve la prova di A potrebbe
    rimandarla indietro spacciandosi per B.

    Il `codice` entra nel calcolo: è così che l'abbinamento resta legato alle
    sei cifre che hai letto sull'altro schermo.
    """
    messaggio = f"prova:{ruolo}:{codice}".encode("utf-8")
    return hmac.new(sessione, messaggio, hashlib.sha256).hexdigest()


def verifica_prova(sessione: bytes, ruolo: str, codice: str, ricevuta: str) -> bool:
    """Confronto a tempo costante: `==` su una stringa esce al primo byte
    diverso, e il tempo che ci mette dice quanti ne aveva indovinati."""
    return hmac.compare_digest(prova(sessione, ruolo, codice), ricevuta or "")


def impronta_sessione(sessione: bytes) -> str:
    """Le sei cifre da confrontare a occhio sui due schermi, in due gruppi da
    tre perché si leggano ad alta voce senza sbagliare."""
    grezza = hmac.new(sessione, b"impronta", hashlib.sha256).digest()
    c = _cifre(grezza, CIFRE_CODICE)
    return f"{c[:3]} {c[3:]}"


# ------------------------------------------- riconoscersi le volte successive

def id_dispositivo() -> str:
    """Un identificativo per questo dispositivo. Casuale e non ricavato
    dall'hardware: il MAC address si falsifica in un minuto e Android lo
    randomizza per rete, quindi come serratura non regge — e come etichetta un
    numero a caso va benissimo, senza dire niente su di te."""
    return secrets.token_hex(8)


def chiave_verso(chiave_vault: bytes, id_peer: str) -> bytes:
    """La chiave per parlare con un dispositivo già abbinato.

    **Si ricava, non si salva.** È il motivo per cui sul disco non finisce
    nessun segreto nuovo: il file dei dispositivi fidati contiene nomi e date, e
    chi lo legge non ci trova niente da usare.
    """
    return _hkdf(chiave_vault, id_peer.encode("utf-8"), _INFO_PEER)


def risposta_sfida(chiave_vault: bytes, id_peer: str, sfida: bytes) -> str:
    """Come ci si riconosce senza codice, dopo il primo abbinamento."""
    return hmac.new(chiave_verso(chiave_vault, id_peer), sfida, hashlib.sha256).hexdigest()


def verifica_sfida(chiave_vault: bytes, id_peer: str, sfida: bytes, ricevuta: str) -> bool:
    return hmac.compare_digest(risposta_sfida(chiave_vault, id_peer, sfida), ricevuta or "")


# ------------------------------------------------------------------ il vault

def impronta_vault(chiave_vault: bytes) -> str:
    """Un'etichetta che dice «questi due vault hanno la stessa chiave», senza
    rivelarla.

    Serve a distinguere due fallimenti che si assomigliano e chiedono cose
    opposte: «non ci siamo capiti sulla rete» e «hai cambiato la master
    password su un dispositivo e non sull'altro». Il secondo non si risolve
    riprovando: va rimandato il vault.
    """
    return hmac.new(chiave_vault, b"quale-vault", hashlib.sha256).hexdigest()[:16]


def sessione_da_password(master: str, salt: bytes, deriva) -> Tuple[bytes, str]:
    """Per il dispositivo che il vault non ce l'ha ancora.

    Il salt non è segreto e glielo manda l'altro; da lì e dalla master password
    che l'utente scrive esce la stessa chiave. Se la password è sbagliata le
    prove non tornano, e l'abbinamento fallisce **prima** che venga trasferito
    qualsiasi dato.

    `deriva` è la funzione Argon2id vera (iniettata per non far dipendere il
    protocollo dal modulo di cifratura).
    """
    chiave = deriva(master, salt)
    return chiave, impronta_vault(chiave)


def nonce_da(dato: str) -> bytes:
    """I nonce viaggiano in esadecimale dentro il JSON: qui tornano byte."""
    try:
        return bytes.fromhex(dato)
    except (ValueError, TypeError):
        return os.urandom(0)
