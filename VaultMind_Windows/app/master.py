"""
master.py — Quando una master password NUOVA è troppo debole per fissarla.

Vale solo dove la password si sceglie (primo avvio, cambio): chi ha già un
vault con una master corta deve poterlo aprire, sempre.

Perché serve (pentest del 10/11/2026, M5): il file del vault è fatto per poter
finire in mano ad altri — un backup su una chiavetta, una copia nel cloud — e
lì non c'è nessun limite ai tentativi: conta solo quanto costa indovinare.
Argon2 rallenta ogni prova, ma «12345678» è la prima che si prova. Otto
caratteri bastavano; adesso dodici, e non una sequenza o una parola ovvia.

Niente dizionari da megabyte e niente punteggi: una regola che si spiega in
una riga, uguale sul telefono (`mobile/lib/master.dart`). Il messaggio dice
cosa non va, perché chi sceglie la password deve poterla correggere.
"""

from __future__ import annotations
from typing import Optional

LUNGHEZZA_MINIMA = 12

#: Tolte le cifre e i simboli in coda e in testa, se resta una di queste la
#: password è «una parola ovvia più qualcosa».
_OVVIE = {
    "password", "passw0rd", "vaultmind", "vault", "master", "masterpassword",
    "qwerty", "qwertyuiop", "admin", "administrator", "letmein", "welcome",
    "benvenuto", "ciaociao", "iloveyou", "tiamo", "juventus", "napoli",
    "francesco", "alessandro", "giuseppe", "password", "segreto", "sicurezza",
}

#: Le file della tastiera e gli ordini che vengono da soli sotto le dita.
_FILE = ("0123456789" * 3, "abcdefghijklmnopqrstuvwxyz" * 2,
         "qwertyuiopasdfghjklzxcvbnm" * 2, "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik9ol0p")


def troppo_debole(pw: str) -> Optional[str]:
    """Perché questa master non va bene, in una frase per l'utente; `None`
    se va bene."""
    if len(pw) < LUNGHEZZA_MINIMA:
        return (f"Scegli una master password di almeno {LUNGHEZZA_MINIMA} "
                "caratteri: è l'unica chiave del vault. Una frase di tre o "
                "quattro parole va benissimo.")
    if len(set(pw)) < 5:
        return ("Questa password ripete sempre gli stessi caratteri: "
                "è fra le prime che si provano.")
    bassa = pw.lower()
    if any(bassa in f or bassa[::-1] in f for f in _FILE):
        return ("Questa password è una sequenza della tastiera: "
                "è fra le prime che si provano.")
    nocciolo = bassa.strip("0123456789 .,;:!?@#$%&*+-_=/\\")
    # «passwordpassword»: una parola ovvia ripetuta resta una parola ovvia.
    meta = nocciolo[: len(nocciolo) // 2]
    if nocciolo in _OVVIE or (meta and meta * 2 == nocciolo and meta in _OVVIE):
        return ("Questa password è una parola comune con qualcosa attaccato: "
                "è fra le prime che si provano.")
    return None
