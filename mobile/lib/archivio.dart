/// Dove sta il vault sul dispositivo, e come ci arriva.
///
/// Sul telefono è un file nella cartella privata dell'app; nel browser è la
/// memoria del sito. Il *dove* lo decide `deposito.dart`; qui restano le
/// regole, uguali ovunque. Il vault è comunque cifrato: quel testo, da solo,
/// non serve a nulla.
library;

import 'dart:convert';

import 'deposito.dart';

/// Il vault sul dispositivo. Nome fisso: ce n'è uno solo.
const _vault = 'vault.json';

Future<bool> esisteVault() => esisteDeposito(_vault);

Future<String> leggiVault() async {
  final c = await leggiDeposito(_vault);
  // Chi chiama ha già controllato che ci sia: se manca, per l'utente è un
  // vault che non si legge, e VaultCorrupted dice la cosa giusta da fare.
  if (c == null) throw const FormatException('Il vault non c\'è più.');
  return c;
}

/// Segnalibro che ricorda se il vault è stato modificato QUI dopo l'ultimo
/// import. Un file che c'è o non c'è, invece di confrontare le date: gli
/// orologi si spostano, un file no.
///
/// Serve perché da quando il telefono scrive, reimportare un backup dal PC
/// può cancellare del lavoro fatto qui — ed è l'unico modo di perdere dati
/// prima che esista il sync (TODO §2).
const _segnalibro = 'modificato-in-locale';

Future<bool> modificatoInLocale() => esisteDeposito(_segnalibro);

/// Salva il vault cifrato **in modo atomico** (vedi `scriviDeposito`): se il
/// telefono muore a metà scrittura resta il vault vecchio, intero — mai mezzo
/// vault, che non si aprirebbe più e sarebbe l'unica copia.
Future<void> salvaVaultCifrato(String contenuto) async {
  if (!sembraUnVault(contenuto)) {
    // Difesa dell'ultimo istante: qui passa solo roba prodotta da cifraVault(),
    // ma sovrascrivere il vault con qualcosa che non è un vault è l'errore da
    // cui non si torna indietro.
    throw const FormatException('Rifiuto di salvare: non ha la forma di un vault.');
  }
  await scriviDeposito(_vault, contenuto);
  await scriviDeposito(_segnalibro, '');
}

/// Scrive il vault di un dispositivo che non ne aveva: la strada di chi usa
/// VaultMind **senza un PC**.
///
/// Si rifiuta se un vault c'è già. La schermata lo ha controllato prima, ma
/// nel frattempo può arrivare un backup da «Apri con», e un vault vuoto scritto
/// sopra uno pieno è la perdita da cui non si torna.
///
/// Niente segnalibro [modificatoInLocale]: un vault vuoto non ha lavoro da
/// proteggere, e importare un backup subito dopo non deve chiedere conferma.
/// Lo mette la prima voce salvata.
Future<void> creaVault(String contenuto) async {
  if (!sembraUnVault(contenuto)) {
    throw const FormatException('Rifiuto di salvare: non ha la forma di un vault.');
  }
  if (await esisteVault()) {
    throw const FormatException('Su questo dispositivo c\'è già un vault.');
  }
  await scriviDeposito(_vault, contenuto);
}

/// Verifica che il testo sia davvero un vault prima di salvarlo.
///
/// Senza questo controllo si potrebbe sovrascrivere il vault buono con un
/// file qualsiasi scelto per sbaglio — e sul telefono i file si scelgono da
/// elenchi in cui i nomi si somigliano tutti.
bool sembraUnVault(String contenuto) {
  try {
    final j = jsonDecode(contenuto);
    if (j is! Map) return false;
    if (j['kdf'] is! Map || (j['kdf'] as Map)['salt'] == null) return false;
    return j['nonce'] != null && j['ciphertext'] != null;
  } catch (_) {
    return false;
  }
}

/// Salva un backup importato come vault del dispositivo.
///
/// Se ce n'era già uno, viene conservato di fianco con la data: sostituire il
/// vault è l'operazione più pericolosa dell'app, e senza una copia un import
/// sbagliato cancellerebbe l'unica cosa che conta.
Future<void> importaVault(String contenuto) async {
  if (!sembraUnVault(contenuto)) {
    throw const FormatException('Il file scelto non è un backup di VaultMind.');
  }
  final attuale = await leggiDeposito(_vault);
  if (attuale != null) {
    final quando = DateTime.now();
    final marca = '${quando.year}'
        '${quando.month.toString().padLeft(2, '0')}'
        '${quando.day.toString().padLeft(2, '0')}-'
        '${quando.hour.toString().padLeft(2, '0')}'
        '${quando.minute.toString().padLeft(2, '0')}';
    await scriviDeposito('vault-precedente-$marca.json', attuale);
  }
  await scriviDeposito(_vault, contenuto);
  // Il vault arriva da fuori: quello che c'era di modificato qui è stato
  // sostituito, e il segnalibro riparte da zero.
  await eliminaDeposito(_segnalibro);
}

/// Toglie il vault da questo dispositivo, comprese le copie di sicurezza degli
/// import precedenti: lasciarne una in giro vanificherebbe la scelta.
/// Se il vault è nato qui e non esiste un backup, è la fine delle password:
/// lo deve dire la schermata, non questa funzione.
Future<void> eliminaVault() async {
  for (final nome in await nomiDeposito()) {
    if (nome.startsWith('vault')) {
      try {
        await eliminaDeposito(nome);
      } catch (_) {}
    }
  }
  // Senza vault il segnalibro non significa più niente, e lasciarlo farebbe
  // avvisare di modifiche locali al primo import del prossimo backup.
  try {
    await eliminaDeposito(_segnalibro);
  } catch (_) {}
}
