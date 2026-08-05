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
"App installate" (oggi: 6.8).

**`VaultMind-Setup.zip`** è lo stesso installer più le istruzioni, in uno zip:
WhatsApp, molte webmail e i proxy aziendali rifiutano gli allegati `.exe`.
Si rigenera insieme a tutto il resto, quindi è sempre allineato.

Chi lo riceve **installa sopra** la versione precedente: niente disinstallazione,
il vault non viene toccato, una sola icona e una sola voce in "App installate"
(l'`AppId` è fisso, Windows riconosce la stessa app).

## 1-bis. `VaultMind-Estensione.zip` — l'estensione per il browser (~50 KB)

L'estensione Chrome/Edge/Brave: cerca e copia dal vault mentre si naviga.
Dentro c'è `COME SI INSTALLA.txt` (modalità sviluppatore, niente Web Store
per ora). Richiede l'app **6.8 aggiornata** (build dal 29/07 sera): con un
exe più vecchio l'abbinamento non esiste e l'estensione resta cieca.

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
Nel repo resta questo file, così la cartella non sparisce. E comunque il
repository è privato: chi deve testare non potrebbe scaricarli da lì, il
pacchetto va consegnato a mano.
