# Vettore di prova — il contratto del formato vault

Serve a chi implementa la lettura del vault **su un'altra piattaforma**
(l'app Android, §2 del TODO). Se il tuo codice apre `vault-esempio.json` e
ritrova esattamente quello che c'è in `atteso.json`, allora leggerà anche i
vault veri. Se non lo apre, non li leggerà — e scoprirlo qui costa un minuto,
scoprirlo sul telefono dell'utente costa il vault.

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
3. **Contenuto**: il testo in chiaro è JSON UTF-8, `{"credentials": [...]}`.

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

**Compatibilità all'indietro**: nei vault creati prima del 29/07/2026 il campo
`critical` non esiste. Assente significa `false`, mai errore.

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

Se qualcuno cambia il formato del vault senza accorgersene, si rompono **prima**
che l'app mobile smetta di aprire i vault degli utenti. È esattamente il motivo
per cui il vettore esiste, e per cui deve restarne **uno solo**: due copie
divergerebbero in silenzio.
