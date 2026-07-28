# Pacchetto da mandare a chi testa

Qui dentro c'è **`VaultMind-Windows.zip`**: il pacchetto pronto da inviare a
chiunque debba provare VaultMind su Windows. Il nome del file non cambia mai —
è sempre la versione più recente.

## Dopo ogni modifica al codice

Chiedimi *"aggiorna il pacchetto"* e lo rigenero dall'ultimo stato del codice.
Dentro lo zip c'è `VERSIONE.txt` con data di build e riferimento al commit: se
chi prova segnala un problema, quella riga dice esattamente quale build aveva.

## Cosa contiene

Tutta la cartella `VaultMind_Windows`: **19 file**, di cui uno solo da lanciare.

Chi riceve estrae lo zip e fa doppio clic su **`run.bat`**, che si trova subito
in vista. Alla prima esecuzione prepara l'ambiente, costruisce `VaultMind.exe` e
crea l'icona sul Desktop; dalle volte successive apre l'app e chiude il terminale.
Se nel frattempo il codice è cambiato, se ne accorge e ricostruisce da solo.

Più due file scritti per chi riceve:

- **`INIZIA DA QUI.txt`** — le istruzioni. Avvisa di tre cose che altrimenti
  fanno scrivere "non funziona": il download da ~1,9 GB di Ollama (evitabile),
  l'avviso SmartScreen, e il fatto che al primo avvio la master password si
  **crea** e non è recuperabile.
- **`VERSIONE.txt`** — versione, data di build, commit.

## Cosa NON contiene, e perché

Escluso a ogni rigenerazione: `vault.json`, `settings.json`, i log,
`__pycache__`, `.venv`, le cartelle di build. Il primo è il punto che conta:
**un vault non deve mai finire dentro un pacchetto che spedisci.** Ogni zip
viene ricontrollato per questo prima di essere consegnato.

## Perché lo zip non è dentro git

È un file binario rigenerabile dal codice: committarne uno nuovo a ogni
modifica gonfierebbe il repository senza aggiungere niente che il codice non
dica già. Nel repo resta questo file, così la cartella non sparisce.
Se preferisci averlo anche su GitHub, si cambia in un minuto — ma tieni
presente che il repository è privato, quindi chi deve testare **non** potrebbe
comunque scaricarlo da lì: il pacchetto va consegnato a mano.

## Perché c'è un solo file da lanciare

Prima ce n'erano due, `run.bat` e `Installa VaultMind.bat`, e sembrava che
entrambi installassero l'app: uno invece avviava soltanto dal sorgente lasciando
un terminale aperto. Ora esiste solo `run.bat`, che al primo avvio costruisce
davvero l'applicazione. Con lui sono spariti anche `installa.ps1`,
`setup-comune.ps1`, `Avvia VaultMind.vbs`, `run.sh`, `main.py`,
`LEGGIMI-WINDOWS.txt` e il vecchio `README.md`: tutto recuperabile da git se
dovesse servire.
