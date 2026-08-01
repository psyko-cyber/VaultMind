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
}
