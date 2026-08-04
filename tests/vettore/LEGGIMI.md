# Vettore di prova — il contratto del formato vault

Serve a chi implementa il vault **su un'altra piattaforma**. Se il tuo codice
apre `vault-esempio.json` e ritrova esattamente quello che c'è in
`atteso.json`, allora leggerà anche i vault veri. Se non lo apre, non li
leggerà — e scoprirlo qui costa un minuto, scoprirlo sul telefono dell'utente
costa il vault.

Dal 04/08/2026 **anche l'app Android scrive**, non solo legge: da quel giorno
un errore qui non impedisce più soltanto di consultare le password, produce un
file che l'altra piattaforma **non riapre**. Chi implementa la scrittura legga
anche "Scrivere un vault", in fondo.

**Le credenziali qui dentro sono inventate.** La master password è scritta in
chiaro apposta: è un file di prova, non un vault.

```
master password: vettore-di-prova-2026
```

## Come è fatto il file

```jsonc
{
  "version": 1,
  "kdf": {
    "alg": "argon2id",
    "salt": "<16 byte, base64>",
    "time_cost": 3,
    "memory_cost": 65536,   // KiB, cioè 64 MB
    "parallelism": 2
  },
  "cipher": "aes-256-gcm",
  "nonce": "<12 byte, base64>",
  "ciphertext": "<base64: cifrato + tag GCM a 16 byte in coda>"
}
```

I passaggi, nell'ordine:

1. **Chiave**: Argon2**id** — `salt` dal file, time cost 3, memoria 65536 KiB,
   parallelismo 2, lunghezza in uscita **32 byte**. Non Argon2i né Argon2d:
   `id`. Sbagliare una variante o un parametro dà una chiave diversa, e la
   decifratura fallisce senza dire perché.
2. **Decifratura**: AES-256-GCM con quel `nonce` e, obbligatorio, i dati
   autenticati aggiuntivi **`vaultmind`** (i byte ASCII, non una stringa
   JSON). Senza AAD il tag non torna.
3. **Contenuto**: il testo in chiaro è JSON UTF-8:

```jsonc
{
  "credentials": [
    {
      "id": 1,
      "title": "Banca Esempio",
      "tags": ["banca"],
      "critical": true,               // opzionale, assente = false
      "category": "Banche",           // opzionale, assente = nessuna categoria
      "uid": "9f2c…",                 // opzionale, assente = si ricava da id
      "rev": 3,                       // opzionale, assente = 1
      "mod": 1754300000000,           // opzionale, assente = 0 (sconosciuta)
      "fields": [{"label": "utente", "value": "mario.rossi"}]
    }
  ],
  "categories": ["Banche", "Social"], // opzionale, assente = nessuna
  "deleted": [                        // opzionale, le lapidi (vedi sotto)
    {"uid": "#5", "rev": 2, "mod": 1754300000000}
  ]
}
```

`categories` è l'elenco delle categorie **esistenti**, che non coincide con
quelle usate dalle voci: una categoria appena creata è ancora vuota, e
dedurla dalle voci la farebbe sparire fra il momento in cui la crei e quello
in cui la riempi. L'ordine è quello scelto dall'utente e va conservato.

Una voce sta in **una categoria sola**: assegnarne un'altra la sposta.

Molte librerie tengono il tag GCM separato dal cifrato: qui è **in coda al
ciphertext**, com'è convenzione in Python `cryptography` e nella maggior parte
delle librerie moderne. Se la tua lo vuole a parte, sono gli ultimi 16 byte.

## Cosa deve venire fuori

`atteso.json` contiene le voci in chiaro **nell'ordine esatto** in cui devono
uscire, e l'ordine dei campi dentro ogni voce: non è un dettaglio estetico, è
l'ordine con cui l'utente vede la credenziale, e l'ha scelto lui.

Casi scelti apposta perché sono quelli in cui un'implementazione diversa
sbaglia:

| Voce | Cosa mette alla prova |
|---|---|
| `Vocé àccentata 🔐` | UTF-8 vero: accenti ed emoji, in titoli, etichette e valori |
| `Valore lungo` | valore da 3000 caratteri |
| `Senza campi` | voce senza nessun campo (lista vuota, non `null`) |
| `amazon.it` | titolo-dominio, come li scrive Bitwarden |
| `Banca Esempio` | `critical: true` |
| `Posta con 2FA` | secret TOTP in base32 |

**Compatibilità all'indietro**: i campi si sono aggiunti nel tempo, e un campo
assente non è mai un errore — è il suo valore predefinito.

| Campo | Aggiunto | Assente significa |
|---|---|---|
| `critical` | 29/07/2026 | `false` |
| `category` | 04/08/2026 | nessuna categoria |
| `categories` (radice) | 04/08/2026 | nessuna categoria definita |
| `uid` | 04/08/2026 | si **ricava da `id`** (vedi sotto) |
| `rev` | 04/08/2026 | `1` |
| `mod` | 04/08/2026 | `0`, cioè sconosciuta |
| `deleted` (radice) | 04/08/2026 | nessuna cancellazione registrata |

Il vettore qui dentro **non ha categorie**, di proposito: dimostra che un vault
scritto prima che esistessero continua ad aprirsi e a riscriversi identico.

## Scrivere un vault

Chi implementa anche la scrittura deve rispettare tre regole, e sono quelle in
cui è facile fare danni silenziosi.

1. **Nonce nuovo a ogni scrittura.** Non è un'accortezza: riusare un nonce con
   la stessa chiave in AES-GCM non indebolisce la cifratura, la **annulla** —
   due vault cifrati con la stessa coppia si smontano a vicenda. Il `salt`
   invece resta quello del file, perché la chiave deriva da lui.
2. **Non scrivere i campi opzionali quando sono vuoti.** Niente `"category": ""`
   e niente `"categories": []`: un vault senza categorie deve restare quello di
   prima. Altrimenti il formato cambia per tutti senza che nessuno l'abbia
   deciso.
3. **Conservare le chiavi che non conosci.** Se leggi un vault con un campo che
   la tua versione non prevede, riscrivilo tale e quale. È il caso concreto dei
   timestamp che arriveranno col sync (TODO §2): senza questa regola, un
   telefono con l'app vecchia li cancellerebbe tutti al primo salvataggio, in
   silenzio, e il sync non se ne accorgerebbe.

Scrittura atomica (file temporaneo + rename) come fa `crypto_store.py`: se il
processo muore a metà, il vault vecchio deve restare leggibile.

## I campi del sync: `uid`, `rev`, `mod`, `deleted`

Servono a far convivere due copie dello stesso vault su dispositivi diversi.
Chi implementa solo la lettura può ignorarli; chi scrive **deve** rispettarli,
perché ognuno dei tre difende un modo preciso di perdere dati.

**`uid` — l'identità della voce, e la regola più importante di tutte.**
Non è `id`. `id` è un numero progressivo per vault: due dispositivi scollegati
che aggiungono una voce prendono **entrambi** `max+1`, cioè lo stesso `id` per
due voci diverse. `uid` è invece unico davvero.

Quando manca — cioè su ogni voce nata prima del 04/08/2026 — **si ricava da
`id`, con la formula `"#" + id`, e non lo si genera a caso.** Se il PC e il
telefono ne inventassero uno casuale per la stessa identica voce, al primo
allineamento quella voce diventerebbe due voci. Solo le voci **nuove** ricevono
un uid casuale (32 caratteri esadecimali).

**`rev` — chi è più avanti.** Un contatore che cresce di uno a ogni modifica
della voce. Qualunque cambiamento va contato, compreso lo spostamento di
categoria: altrimenti un riordino di 800 voci risulterebbe "niente è cambiato".

**`mod` — quando, in millisecondi.** Serve a *mostrarlo* all'utente e come
spareggio estremo, **non** a decidere chi vince: due dispositivi con l'orologio
sfasato deciderebbero male. Per quello c'è `rev`.

**`deleted` — le lapidi.** Senza, una voce cancellata su un dispositivo
resuscita al primo allineamento, perché l'altro — che ce l'ha ancora — la
rimanda indietro. Il `rev` della lapide è quello che aveva la voce **più uno**:
la cancellazione è essa stessa una modifica, e deve battere la copia viva.
Le lapidi più vecchie di 180 giorni si scartano; una lapide senza `mod` si
tiene comunque, perché nel dubbio è meglio una lapide di troppo che una voce
che torna in vita.

## Verifica anche il 2FA

In `atteso.json` c'è `totp_di_verifica`: dato quel secret base32 a
quell'istante unix, deve uscire quel codice. È TOTP standard (HMAC-SHA1,
periodo 30 s, 6 cifre), ma un errore nel decodificare il base32 o
nell'impacchettare il contatore big-endian passa inosservato finché qualcuno
non prova ad accedere a un servizio vero.

## Rigenerarlo

Non serve, se non cambia il formato. `genera.py` lo ricrea, ma salt e nonce
sono casuali: il contenuto resta identico, il file no.

```
..\..\VaultMind_Windows\.venv\Scripts\python.exe genera.py
```

Due suite aprono questo file a ogni esecuzione, una per piattaforma:

- **Python** — `tests\run.ps1`, classe `TestVettoreDiProva`
- **Dart** — `mobile\costruisci.ps1 -Test`, che si rifiuta di costruire l'APK
  se falliscono

## Gli altri due vettori

In questa cartella ci sono tre contratti, non tre copie della stessa cosa:

| File | Cosa fissa |
|---|---|
| `vault-esempio.json` + `atteso.json` | il **formato** del vault |
| `fusione.json` | il **comportamento** del merge |
| `sync.json` | i **byte** del protocollo di abbinamento |

`sync.json` contiene ingressi fissi (una chiave, due nonce, un codice) e i
valori che devono uscirne. Se il PC e il telefono calcolassero prove diverse
l'abbinamento fallirebbe **sempre**, e senza questo file lo si scoprirebbe con
due dispositivi veri in mano — il momento peggiore per accorgersene.

## Il secondo vettore: `fusione.json`

`fusione.json` non descrive il *formato* ma il **comportamento della fusione**:
coppie di vault in ingresso e il risultato che ci si aspetta. Non è una copia
del vettore del formato — è un contratto diverso, e sta qui perché ha la stessa
natura: qualcosa che due implementazioni devono interpretare allo stesso modo.

Lo eseguono `TestVettoreFusione` (Python) e `fusione_test.dart` (Dart) a ogni
esecuzione. Se il PC e il telefono decidessero diversamente su cosa è successo
fra due copie, si allineerebbero su due verità diverse — e nessuno se ne
accorgerebbe finché non manca una password.

Ogni caso porta con sé il *perché* esiste: leggerlo è il modo più veloce di
capire cosa fa il merge e, soprattutto, cosa si rifiuta di fare da solo.

E dal 04/08/2026 il contratto si verifica anche **nel verso opposto**: la suite
Dart lascia in `mobile\build\vault-scritto-da-dart.json` un vault che ha cifrato
lei, e la classe Python `TestScrittoDaDart` lo apre. È l'unica prova che il PC
riesca a leggere ciò che scrive il telefono — il rischio nuovo, da quando il
telefono non si limita più a leggere. Quel file **non sta in git**: si rigenera
a ogni esecuzione, e un vettore che si rigenera non può divergere. Se manca, i
test si dichiarano *saltati* invece di passare fingendo.

Se qualcuno cambia il formato del vault senza accorgersene, si rompono **prima**
che l'app mobile smetta di aprire i vault degli utenti. È esattamente il motivo
per cui il vettore esiste, e per cui deve restarne **uno solo**: due copie
divergerebbero in silenzio.
