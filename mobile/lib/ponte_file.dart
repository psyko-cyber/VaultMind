/// Il lato Dart del ponte verso Android (`MainActivity.kt`).
///
/// Due modi di ricevere un backup, in ordine di comodità per chi lo usa:
///  1. tocca l'allegato in chat e sceglie VaultMind — zero navigazione;
///  2. preme "Scegli il file" e usa il selettore di sistema.
library;

import 'package:flutter/services.dart';

const _canale = MethodChannel('vaultmind/file');

/// Apre il selettore di sistema. Restituisce il contenuto del file scelto,
/// o `null` se l'utente ha annullato (che non è un errore).
Future<String?> scegliFile() async {
  try {
    return await _canale.invokeMethod<String>('scegli');
  } on PlatformException {
    return null;
  }
}

/// Il file con cui l'app è stata aperta da una chat, se c'è. Si consuma:
/// chiamarla due volte non restituisce due volte lo stesso file.
Future<String?> fileDaApertura() async {
  try {
    return await _canale.invokeMethod<String>('inAttesa');
  } on PlatformException {
    return null;
  }
}

/// Avvisa quando arriva un file mentre l'app è già aperta.
void inAscoltoDiFile(void Function(String contenuto) quando) {
  _canale.setMethodCallHandler((chiamata) async {
    if (chiamata.method == 'fileRicevuto' && chiamata.arguments is String) {
      quando(chiamata.arguments as String);
    }
    return null;
  });
}
