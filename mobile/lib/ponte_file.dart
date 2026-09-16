/// Il lato Dart del ponte verso Android (`MainActivity.kt`) e, dal 16/09/2026,
/// verso il browser (`ponte_web.dart`), per la versione iPhone.
///
/// Ogni funzione sceglie con `kIsWeb`: le schermate chiamano sempre queste, e
/// non sanno dove girano. Quello che nel browser non esiste risponde come un
/// telefono che non ce l'ha (niente impronta, nessun file in arrivo).
///
/// Il nome dice "file" perché di file si trattava all'inizio; oggi passano di
/// qui anche l'apertura di un indirizzo, l'impronta e la lettura dei QR. Resta
/// **un canale solo** di proposito: dall'altra parte c'è una `MainActivity`
/// sola, e spezzare il ponte in quattro vorrebbe dire quattro `MethodChannel`
/// da tenere allineati per non guadagnare niente.
///
/// Due modi di ricevere un backup, in ordine di comodità per chi lo usa:
///  1. tocca l'allegato in chat e sceglie VaultMind — zero navigazione;
///  2. preme "Scegli il file" e usa il selettore di sistema.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ponte_web_finto.dart' if (dart.library.js_interop) 'ponte_web.dart' as web;

const _canale = MethodChannel('vaultmind/file');

/// Apre il selettore di sistema. Restituisce il contenuto del file scelto,
/// o `null` se l'utente ha annullato (che non è un errore).
Future<String?> scegliFile() async {
  if (kIsWeb) return web.scegliFile();
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
  if (kIsWeb) return web.salvaBackup(contenuto, nome);
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
  if (kIsWeb) return null; // un'app web non riceve file dalle altre app
  try {
    return await _canale.invokeMethod<String>('inAttesa');
  } on PlatformException {
    return null;
  }
}

/// Avvisa quando arriva un file mentre l'app è già aperta.
void inAscoltoDiFile(void Function(String contenuto) quando) {
  if (kIsWeb) return;
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
  if (kIsWeb) return web.apriNelBrowser(url);
  try {
    return await _canale.invokeMethod<bool>('apriUrl', url) ?? false;
  } on PlatformException {
    return false;
  }
}

// --------------------------------------------------------------------- QR

/// Com'è andata la lettura di un QR.
///
/// Sono sei esiti e non "una stringa o niente" perché chiedono cinque cose
/// diverse a chi sta usando l'app: riprova, scegli un altro file, dai il
/// permesso, usa un altro telefono, oppure niente — hai annullato tu.
enum EsitoQr {
  letto,

  /// L'utente è tornato indietro. Non è un errore e non si dice niente.
  annullato,

  /// Permesso della fotocamera negato.
  permessoNegato,

  /// Fotocamera assente, occupata, o vietata dalle policy del telefono.
  fotocameraNonDisponibile,

  /// L'immagine si è aperta ma dentro non c'era nessun QR.
  nessunQr,

  /// Il file scelto non è un'immagine leggibile.
  immagineIllegibile,
}

class RisultatoQr {
  final EsitoQr esito;

  /// Il contenuto del QR. Valorizzato solo con [EsitoQr.letto].
  final String? testo;

  const RisultatoQr(this.esito, [this.testo]);
}

const _erroriQr = {
  'permesso': EsitoQr.permessoNegato,
  'fotocamera': EsitoQr.fotocameraNonDisponibile,
  'nessun_qr': EsitoQr.nessunQr,
  'immagine': EsitoQr.immagineIllegibile,
};

/// Apre la fotocamera e restituisce il contenuto del primo QR inquadrato.
///
/// [coloreAccento] è il colore del tema in corso: la schermata è nativa, non
/// legge il tema di Flutter, e senza questo il mirino sarebbe viola anche
/// nell'app in oro.
Future<RisultatoQr> qrDaFotocamera({
  required int coloreAccento,
  String titolo = 'Inquadra il QR',
}) =>
    kIsWeb
        ? web.qrDaFotocamera(coloreAccento: coloreAccento, titolo: titolo)
        : _leggiQr('qrDaFotocamera', {'colore': coloreAccento, 'titolo': titolo});

/// Sceglie un'immagine col selettore di sistema e ci cerca dentro un QR.
///
/// È la strada che la fotocamera non può coprire: quando la 2FA si attiva sul
/// browser **di questo stesso telefono**, il QR sta sullo schermo che
/// dovrebbe fotografare. Lì l'unico modo è lo screenshot.
Future<RisultatoQr> qrDaImmagine() =>
    kIsWeb ? web.qrDaImmagine() : _leggiQr('qrDaImmagine', null);

Future<RisultatoQr> _leggiQr(String metodo, Map<String, Object?>? argomenti) async {
  try {
    final testo = await _canale.invokeMethod<String>(metodo, argomenti);
    return testo == null
        ? const RisultatoQr(EsitoQr.annullato)
        : RisultatoQr(EsitoQr.letto, testo);
  } on PlatformException catch (e) {
    return RisultatoQr(_erroriQr[e.code] ?? EsitoQr.annullato);
  } on MissingPluginException {
    // Succede solo fuori da Android (i test girano sul PC): meglio "annullato"
    // che un'eccezione che nessuno cattura.
    return const RisultatoQr(EsitoQr.annullato);
  }
}

// ---------------------------------------------------------------- impronta

/// Il telefono ha un lettore di impronte utilizzabile?
///
/// Nel browser no: vedi `ponte_web.dart`. È questa risposta a nascondere il
/// pulsante e la proposta dopo lo sblocco.
Future<bool> impresaDisponibile() async =>
    !kIsWeb && (await _canale.invokeMethod<bool>('bioDisponibile') ?? false);

/// L'utente ha già attivato lo sblocco con impronta?
Future<bool> improntaAttiva() async =>
    !kIsWeb && (await _canale.invokeMethod<bool>('bioAttiva') ?? false);

Future<void> improntaDisattiva() async {
  if (!kIsWeb) await _canale.invokeMethod<void>('bioDisattiva');
}

/// Attiva lo sblocco con impronta conservando la chiave del vault (in base64)
/// cifrata dal Keystore. Restituisce `false` se l'utente annulla.
/// Solleva [PlatformException] se qualcosa va storto davvero.
Future<bool> improntaAttivaConChiave(String chiaveBase64) async =>
    await _canale.invokeMethod<bool>('bioAttivaConChiave', chiaveBase64) ?? false;

/// Chiede l'impronta e restituisce la chiave del vault in base64,
/// oppure `null` se l'utente ha annullato.
Future<String?> improntaSblocca() async =>
    _canale.invokeMethod<String>('bioSblocca');

// ---------------------------------------------------------------- browser

/// Nel browser di un iPhone o iPad (Safari, o un altro: su iOS sono tutti
/// Safari sotto).
bool browserIos() => kIsWeb && web.suIos();

/// Aperta dall'icona sulla schermata Home. Fuori dal browser: sempre vero,
/// un'app installata è un'app installata.
bool installataSullaHome() => !kIsWeb || web.installataSullaHome();

/// Vedi `ponte_web.dart`. Fuori dal browser non c'è niente da chiedere.
Future<void> chiediMemoriaPersistente() async {
  if (kIsWeb) await web.chiediMemoriaPersistente();
}

/// Una versione nuova dell'app web è attiva ma questa pagina è ancora la
/// vecchia. Sempre falso fuori dal browser: l'APK si aggiorna reinstallandolo.
/// Non si ricarica mai da solo: vedi `web/sw.js`.
final ValueListenable<bool> aggiornamentoWeb =
    kIsWeb ? web.aggiornamentoPronto() : ValueNotifier(false);

void ricaricaApp() {
  if (kIsWeb) web.ricaricaApp();
}
