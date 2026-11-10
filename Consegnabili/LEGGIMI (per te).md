# Pacchetto da mandare a chi testa

Tutto qui dentro è **generato** da `installer\rilascio.ps1`: non si modifica a
mano. I nomi dei file non cambiano mai, sono sempre la versione più recente.

**Cosa mandare, in pratica:**
- per **email/WhatsApp** → `VaultMind-Setup.zip` (contiene installer +
  istruzioni: un allegato solo, e passa dove i `.exe` vengono bloccati)
- se ha accesso al **repo** → il link alla release GitHub
- se vuole **vedere il codice** → `VaultMind-Windows.zip`

## 1. `VaultMind-Setup.exe` — quello principale (~108 MB)

L'installer con procedura guidata: doppio clic, Avanti → Installa, icona sul
Desktop e nel menu Start, disinstallazione da "App installate". Chi lo riceve
**non ha bisogno di Python, non scarica niente, non costruisce niente**:
l'applicazione è già dentro.

Da mandare **insieme a `INIZIA DA QUI (per chi riceve).txt`**, che avvisa
delle tre cose che altrimenti fanno scrivere "non funziona": l'avviso
SmartScreen (siamo senza firma), la master password che al primo avvio si
**crea** e non è recuperabile, e la spunta Ollama (~2 GB, facoltativa).

La versione precisa la mostra l'installer stesso e, dopo, la voce in
"App installate".

**`VaultMind-Setup.zip`** è lo stesso installer più le istruzioni, in uno zip:
WhatsApp, molte webmail e i proxy aziendali rifiutano gli allegati `.exe`.
Si rigenera insieme a tutto il resto, quindi è sempre allineato.

Chi lo riceve **installa sopra** la versione precedente: niente disinstallazione,
il vault non viene toccato, una sola icona e una sola voce in "App installate"
(l'`AppId` è fisso, Windows riconosce la stessa app).

## 1-bis. `VaultMind-Estensione.zip` — l'estensione per il browser (~280 KB)

L'estensione Chrome/Edge/Brave: cerca e copia dal vault mentre si naviga.
Dentro c'è `COME SI INSTALLA.txt` (modalità sviluppatore, niente Web Store),
che dice anche quale versione dell'app serve. Chi ha installato con
`VaultMind-Setup.exe` non ne ha bisogno: l'estensione è già accanto all'app.

## 1-ter. `VaultMind.apk`, `SHA256SUMS.txt`, `SHA256SUMS.txt.sig`

L'app Android (la lascia qui `mobile\costruisci.ps1 -Release`) e le impronte
firmate di setup e APK: senza quei due file l'aggiornamento dentro l'app non
installa. La firma si fa con una chiave che sta solo su questo PC
(`installer\firma_somme.py`).

## 2. `VaultMind-Windows.zip` — il ripiego (~0,3 MB)

Il canale vecchio: tutta la cartella `VaultMind_Windows`, e chi riceve fa
doppio clic su `run.bat`, che si costruisce l'app sulla sua macchina
(serve Python, scarica i componenti, minuti di attesa). Resta utile se:

- un antivirus aziendale blocca l'exe da 108 MB e conviene passare dal sorgente;
- chi testa vuole *vedere* il codice che esegue (col nostro pitch, succederà);
- serve provare una modifica al volo senza ricompilare l'installer.

Dentro c'è `VERSIONE.txt` con data di build e commit: se chi prova segnala un
problema, quella riga dice esattamente quale build aveva. Escluso a ogni
rigenerazione: `vault.json`, `settings.json`, log, `__pycache__`, `.venv`,
cartelle di build. **Un vault non deve mai finire dentro un pacchetto che
spedisci** — ogni zip viene ricontrollato per questo.

## Dopo ogni modifica al codice

Tutto quello che sta qui è **generato**: non si modifica a mano.

1. `run.bat` in `VaultMind_Windows\` — ricostruisce l'app
2. `installer\rilascio.ps1` — rifà installer e zip **direttamente qui**
   (si rifiuta se l'exe è più vecchio del codice, così non si consegna mai una
   build stantia). Con `-Release` aggiorna anche la release su GitHub.

## Perché i binari non sono dentro git

Sono file rigenerabili dal codice: committarne uno nuovo a ogni modifica
gonfierebbe il repository senza aggiungere niente che il codice non dica già.
Nel repo resta questo file, così la cartella non sparisce. Chi deve provare
li scarica dalla release su GitHub (il repository è pubblico dal 25/10/2026),
o li riceve a mano.
