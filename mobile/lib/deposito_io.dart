/// Il deposito sul telefono: file nella cartella privata dell'app.
///
/// Nessun'altra app puo' leggerla, e `allowBackup="false"` piu' le regole in
/// `res/xml/nessun_backup` impediscono ad Android di copiarla sul Google Drive
/// dell'utente. Si usa da `deposito.dart`.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<File> _file(String nome) async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/$nome');
}

Future<bool> esisteDeposito(String nome) async => (await _file(nome)).exists();

/// `null` se non c'e'.
Future<String?> leggiDeposito(String nome) async {
  final f = await _file(nome);
  return await f.exists() ? f.readAsString() : null;
}

/// Scrive **in modo atomico**: prima un file temporaneo, poi il rename, che
/// sullo stesso volume e' indivisibile. Se il telefono muore a meta' resta il
/// contenuto vecchio, intero -- mai mezzo vault, che non si aprirebbe piu'.
Future<void> scriviDeposito(String nome, String testo) async {
  final f = await _file(nome);
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(testo, flush: true);
  await tmp.rename(f.path);
}

Future<void> eliminaDeposito(String nome) async {
  final f = await _file(nome);
  if (await f.exists()) await f.delete();
}

Future<List<String>> nomiDeposito() async {
  final dir = await getApplicationDocumentsDirectory();
  return [
    for (final e in dir.listSync())
      if (e is File) e.path.split(RegExp(r'[\/]')).last
  ];
}
