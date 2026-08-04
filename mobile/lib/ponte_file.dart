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

/// Salva il vault cifrato dove decide l'utente, col selettore di sistema.
/// `false` se annulla o se la scrittura non riesce.
///
/// Non usa la condivisione diretta (ACTION_SEND) perché richiederebbe un
/// FileProvider esportato: così non si espone niente, e da dove il file
/// atterra si manda dove si vuole con le app che ci sono già.
Future<bool> salvaBackup(String contenuto, String nome) async {
  try {
    return await _canale.invokeMethod<bool>(
            'salvaBackup', {'contenuto': contenuto, 'nome': nome}) ??
        false;
  } on PlatformException {
    return false;
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

/// Apre un indirizzo nel browser. Solo `http`/`https`: il filtro sta anche
/// dal lato Android, perché un campo del vault non deve poter far eseguire
/// nulla al telefono. Stessa regola di `/api/open_url` sul PC.
Future<bool> apriNelBrowser(String url) async {
  try {
    return await _canale.invokeMethod<bool>('apriUrl', url) ?? false;
  } on PlatformException {
    return false;
  }
}

// ---------------------------------------------------------------- impronta

/// Il telefono ha un lettore di impronte utilizzabile?
Future<bool> impresaDisponibile() async =>
    await _canale.invokeMethod<bool>('bioDisponibile') ?? false;

/// L'utente ha già attivato lo sblocco con impronta?
Future<bool> improntaAttiva() async =>
    await _canale.invokeMethod<bool>('bioAttiva') ?? false;

Future<void> improntaDisattiva() async =>
    _canale.invokeMethod<void>('bioDisattiva');

/// Attiva lo sblocco con impronta conservando la chiave del vault (in base64)
/// cifrata dal Keystore. Restituisce `false` se l'utente annulla.
/// Solleva [PlatformException] se qualcosa va storto davvero.
Future<bool> improntaAttivaConChiave(String chiaveBase64) async =>
    await _canale.invokeMethod<bool>('bioAttivaConChiave', chiaveBase64) ?? false;

/// Chiede l'impronta e restituisce la chiave del vault in base64,
/// oppure `null` se l'utente ha annullato.
Future<String?> improntaSblocca() async =>
    _canale.invokeMethod<String>('bioSblocca');
