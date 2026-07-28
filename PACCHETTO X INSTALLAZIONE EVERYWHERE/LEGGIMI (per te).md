# Pacchetto da mandare a chi testa

Qui dentro c'è **`VaultMind-Windows.zip`**: il pacchetto pronto da inviare a
chiunque debba provare VaultMind su Windows. Il nome del file non cambia mai —
è sempre la versione più recente.

## Dopo ogni modifica al codice

Chiedimi *"aggiorna il pacchetto"* e lo rigenero dall'ultimo stato del codice.
Dentro lo zip c'è `VERSIONE.txt` con data di build e riferimento al commit: se
chi prova segnala un problema, quella riga dice esattamente quale build aveva.

## Cosa contiene

Tutta la cartella `VaultMind_Windows`, più due file scritti per chi riceve:

- **`INIZIA DA QUI.txt`** — le istruzioni. In sintesi: estrarre lo zip ed
  eseguire `vaultmind-app\run.bat`. Avvisa di tre cose che altrimenti fanno
  scrivere "non funziona": il download da ~1,9 GB di Ollama (evitabile),
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

## Nota su `Installa VaultMind.bat` (la strada del .exe)

Nel pacchetto c'è anche quel file, ma **non è la strada da consigliare a chi
prova**: usa `where python`, che su Windows 11 trova il finto alias del
Microsoft Store e fa fallire tutto in modo incomprensibile. `run.bat` invece
gestisce già quel caso. Sistemare il `.bat` è il punto 3.3 del [TODO](../TODO.md).
