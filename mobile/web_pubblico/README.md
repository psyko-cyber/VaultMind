# VaultMind per iPhone

Questa è la versione **web** di VaultMind, il password manager che tiene il
vault sul dispositivo e non su un server. Qui c'è solo l'app già compilata,
servita da GitHub Pages.

**Apri:** https://psyko-cyber.github.io/vaultmind-web/

## Installarla su iPhone

1. Apri il link qui sopra in **Safari**.
2. Tocca **Condividi** (il quadrato con la freccia; nelle versioni recenti di
   iOS sta nel menu «···») e scegli **Aggiungi alla schermata Home**.
3. Apri VaultMind **dall'icona** e crea lì il vault.

Il passo 3 conta: l'icona sulla Home ha una memoria separata da Safari, e
Safari cancella i dati di un sito dopo 7 giorni senza uso.

## Dove vanno le password

- Il vault è cifrato **sul dispositivo** (Argon2id + AES-256-GCM, lo stesso
  formato dell'app per PC e Android) e non viene mai inviato da nessuna parte.
  La pagina vieta al browser qualunque collegamento verso altri siti.
- La master password non viene salvata. Se la dimentichi, il vault non si
  recupera.
- **Se togli l'icona dalla Home, il vault se ne va con lei.** Salva un backup
  da *Impostazioni → Salva un backup*: è lo stesso file che apre l'app per PC.

## Cosa non c'è rispetto all'app Android

Sincronizzazione automatica col PC (il browser non può parlare con gli altri
dispositivi di casa: si passa da un backup) · sblocco con Face ID · appunti
che si svuotano da soli.

## Codice

Il sorgente sta in un repository privato. Le licenze dei componenti di terze
parti inclusi sono in `assets/NOTICES`.
