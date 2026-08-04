/// Dove sta il vault sul telefono, e come ci arriva.
///
/// Il file resta nella cartella privata dell'app: nessun'altra app può
/// leggerlo, e `allowBackup="false"` più le regole in `res/xml/nessun_backup`
/// impediscono ad Android di copiarlo sul Google Drive dell'utente.
/// Il vault è comunque cifrato: quel file, da solo, non serve a nulla.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Il vault sul dispositivo. Nome fisso: ce n'è uno solo.
Future<File> fileVault() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/vault.json');
}

Future<bool> esisteVault() async => (await fileVault()).exists();

Future<String> leggiVault() async => (await fileVault()).readAsString();

/// Segnalibro che ricorda se il vault è stato modificato QUI dopo l'ultimo
/// import. Un file che c'è o non c'è, invece di confrontare le date: gli
/// orologi si spostano, un file no.
///
/// Serve perché da quando il telefono scrive, reimportare un backup dal PC
/// può cancellare del lavoro fatto qui — ed è l'unico modo di perdere dati
/// prima che esista il sync (TODO §2).
Future<File> _segnalibro() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/modificato-in-locale');
}

Future<bool> modificatoInLocale() async => (await _segnalibro()).exists();

/// Salva il vault cifrato **in modo atomico**: prima un file temporaneo, poi
/// il rename, che sullo stesso volume è indivisibile. Se il telefono muore a
/// metà scrittura resta il vault vecchio, intero — mai mezzo vault, che non si
/// aprirebbe più e sarebbe l'unica copia.
Future<void> salvaVaultCifrato(String contenuto) async {
  if (!sembraUnVault(contenuto)) {
    // Difesa dell'ultimo istante: qui passa solo roba prodotta da cifraVault(),
    // ma sovrascrivere il vault con qualcosa che non è un vault è l'errore da
    // cui non si torna indietro.
    throw const FormatException('Rifiuto di salvare: non ha la forma di un vault.');
  }
  final f = await fileVault();
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(contenuto, flush: true);
  await tmp.rename(f.path);
  await (await _segnalibro()).writeAsString('', flush: true);
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
  final f = await fileVault();
  if (await f.exists()) {
    final quando = DateTime.now();
    final marca = '${quando.year}'
        '${quando.month.toString().padLeft(2, '0')}'
        '${quando.day.toString().padLeft(2, '0')}-'
        '${quando.hour.toString().padLeft(2, '0')}'
        '${quando.minute.toString().padLeft(2, '0')}';
    await f.copy('${f.parent.path}/vault-precedente-$marca.json');
  }
  await f.writeAsString(contenuto, flush: true);
  // Il vault arriva da fuori: quello che c'era di modificato qui è stato
  // sostituito, e il segnalibro riparte da zero.
  final s = await _segnalibro();
  if (await s.exists()) await s.delete();
}

/// Toglie il vault da questo telefono, comprese le copie di sicurezza degli
/// import precedenti: lasciarne una in giro vanificherebbe la scelta.
/// Sul PC resta tutto: qui c'è solo una copia.
Future<void> eliminaVault() async {
  final f = await fileVault();
  final dir = f.parent;
  for (final e in dir.listSync()) {
    if (e is File && e.path.split(RegExp(r'[\\/]')).last.startsWith('vault')) {
      try {
        await e.delete();
      } catch (_) {}
    }
  }
  // Senza vault il segnalibro non significa più niente, e lasciarlo farebbe
  // avvisare di modifiche locali al primo import del prossimo backup.
  try {
    final s = await _segnalibro();
    if (await s.exists()) await s.delete();
  } catch (_) {}
}
