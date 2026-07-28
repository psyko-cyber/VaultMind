# VaultMind — gestore di credenziali locale con interfaccia chat

Un password manager **100% locale**: salvi le credenziali in un vault cifrato e le
recuperi scrivendo in linguaggio naturale ("dammi la password di amazon"), anche se
i titoli sono disordinati. Nessun cloud, nessun account, nessuna porta esposta in rete.

> Prototipo dimostrativo. Mostra l'architettura del concept; non è ancora un
> prodotto auditato per uso in produzione (vedi *Sicurezza e limiti*).

---

## Cosa fa

- **Vault cifrato**: le credenziali stanno in un unico file cifrato con AES-256-GCM;
  la chiave è derivata dalla master password con Argon2id e non viene mai salvata.
- **Recupero deterministico**: la richiesta viene trasformata in un embedding e
  confrontata (coseno) con le voci salvate. Il match è *trovato*, non *generato*:
  l'AI non inventa password e non può restituirne una sbagliata "con sicurezza".
- **Gestione dell'ambiguità**: se due voci sono troppo vicine (es. due account
  Amazon), l'app chiede quale intendi invece di tirare a indovinare.
- **Interfaccia chat** in locale, con mostra/copia e auto-clear della clipboard.
- **LLM locale opzionale** (Ollama) solo per formulare la frase di risposta — non
  vede né genera mai le password.

---

## Avvio rapido

Serve **Python 3.10+**.

### Windows

1. Estrai lo zip.
2. Apri la cartella `vaultmind-app`.
3. Fai **doppio clic su `run.bat`** (oppure, da PowerShell, `./run.ps1`).

La prima volta crea l'ambiente, installa le dipendenze e apre il browser su
`http://127.0.0.1:8731`. Se Windows mostra un avviso "Windows ha protetto il PC",
clicca *Ulteriori informazioni → Esegui comunque* (succede perché il file arriva
da fuori). Se manca Python, installalo da python.org **spuntando "Add Python to PATH"**.

> Se la finestra si apre e si richiude subito senza messaggi: rilanciala da un
> Terminale (`cmd`) navigando nella cartella e scrivendo `run.bat`, così il
> messaggio d'errore resta visibile invece di scomparire con la finestra.
> `run.bat` ora controlla Python, mostra ogni errore esplicitamente e non si
> chiude mai senza un "Premi un tasto per continuare".

Avvio manuale (se preferisci):


---

## Novità (sessione 19/06/2026 — v5)

### 🎲 Generatore di password
Nel pulsante **＋** (e in modifica) c'è ora **🎲 Genera**: apre un pannello con
slider lunghezza (8-40) e toggle A-Z / a-z / 0-9 / simboli. La password è generata
**nel browser** con `crypto.getRandomValues` (crypto-grade), esclude caratteri
ambigui (l/I/O/0/1) e si inserisce con un clic nel campo Password. Nessun dato esce
dal dispositivo.

### 📄 Import da CSV (Bitwarden / 1Password / KeePass)
Nel modal **Import intelligente** (⇪) c'è il bottone **📄 Importa da CSV**: carichi
l'export di un altro password manager e l'app riconosce il formato dai nomi delle
colonne (Bitwarden, 1Password, KeePass o CSV generico). Mappa username/password/URL/
note/2FA, estrae il secret dagli `otpauth://` URI, e trasforma cartelle/gruppi in tag.
La lettura è **locale, senza LLM**; le voci passano comunque dall'anteprima editabile
prima del salvataggio. Rileva da solo il separatore (virgola, punto e virgola, tab).

### 🔍 Filtro nel Database
La tab **Database** ha ora un campo di ricerca che filtra le card per **titolo o tag**
in tempo reale, lato client. Indispensabile oltre le ~50 voci.

### Nuovo endpoint
| Endpoint | Metodo | Input | Output |
|----------|--------|-------|--------|
| `/api/import_csv` | POST | `{content}` (testo CSV) | `{source, entries:[{title, fields, tags}]}` |
