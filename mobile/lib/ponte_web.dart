/// Il lato browser di `ponte_file.dart`: quello che su Android fa
/// `MainActivity.kt`, qui lo fanno le API del web.
///
/// Esiste dal 16/09/2026, per la versione iPhone installata dalla schermata
/// Home (vedi `schermate/installa.dart`). Stesse funzioni, stessi esiti, così
/// le schermate non sanno dove girano.
///
/// ## Cosa il browser non permette, e quindi qui non c'è
///
/// - **Impronta / Face ID**: sulle passkey servirebbe l'estensione PRF, tutta
///   da provare su iPhone. Per ora si sblocca con la master password.
/// - **«Apri con VaultMind»** dall'allegato in chat: un'app web non riceve
///   file dalle altre app di iOS. Il backup si sceglie a mano.
///
/// ## Il gesto dell'utente
///
/// Safari apre il selettore dei file e il foglio di condivisione **solo in
/// risposta a un tocco**. Le funzioni qui vanno chiamate subito dal pulsante,
/// senza attese lunghe in mezzo: se il permesso scade, la condivisione ripiega
/// sullo scaricamento.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:web/web.dart' as web;

import 'lettore_qr.dart';
import 'ponte_file.dart' show EsitoQr, RisultatoQr;

// ------------------------------------------------------------------- file

/// Il selettore dei file di iOS (app File, iCloud, allegati salvati).
///
/// Senza filtro `accept`: iOS a volte rende grigi i `.json` salvati da
/// WhatsApp perché non ne riconosce il tipo, e un file che non si può toccare
/// sembra un file che non c'è. Se non è un vault lo dice `sembraUnVault`.
Future<String?> scegliFile() async {
  final f = await _scegli('');
  if (f == null) return null;
  return (await f.text().toDart).toDart;
}

Future<web.File?> _scegli(String accetta) {
  final finito = Completer<web.File?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = accetta;
  input.style.display = 'none';
  // Nel documento, non staccato: alcune versioni di Safari ignorano il click
  // su un input che non sta nella pagina.
  web.document.body?.append(input);
  void chiudi(web.File? f) {
    if (!finito.isCompleted) finito.complete(f);
    input.remove();
  }

  input.addEventListener(
      'change',
      ((web.Event _) {
        final files = input.files;
        chiudi(files != null && files.length > 0 ? files.item(0) : null);
      }).toJS);
  // «Annulla» nel selettore: senza questo evento il Future non finirebbe mai.
  input.addEventListener('cancel', ((web.Event _) => chiudi(null)).toJS);
  input.click();
  return finito.future;
}

/// Il backup esce dal foglio di condivisione di iOS: «Salva su File»,
/// WhatsApp, AirDrop, quello che l'utente ha già. Dove la condivisione di file
/// non c'è (browser del PC), si scarica.
Future<bool> salvaBackup(String contenuto, String nome) async {
  final parti = <web.BlobPart>[contenuto.toJS].toJS;
  final file = web.File(parti, nome, web.FilePropertyBag(type: 'application/json'));
  final nav = web.window.navigator;
  final dati = web.ShareData(files: <web.File>[file].toJS);
  var puoCondividere = false;
  try {
    puoCondividere = nav.has('canShare') && nav.canShare(dati);
  } catch (_) {}
  if (puoCondividere) {
    try {
      await nav.share(dati).toDart;
      return true;
    } catch (e) {
      // Annullato dall'utente: non è un errore, e non si scarica niente.
      if ('$e'.contains('AbortError')) return false;
      // Il permesso del tocco è scaduto, o la condivisione è vietata: si
      // ripiega sullo scaricamento invece di perdere il backup.
    }
  }
  final url = web.URL.createObjectURL(web.Blob(parti, web.BlobPropertyBag(type: 'application/json')));
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = nome;
  web.document.body?.append(a);
  a.click();
  a.remove();
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  return true;
}

/// Solo `http`/`https`, come sul telefono e sul PC: un campo del vault non deve
/// poter far eseguire niente al browser.
Future<bool> apriNelBrowser(String url) async {
  final u = Uri.tryParse(url);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return false;
  // Con `noopener` il browser restituisce null anche quando la scheda si apre:
  // è la regola, non un errore, quindi il valore non dice niente.
  web.window.open(url, '_blank', 'noopener,noreferrer');
  return true;
}

// --------------------------------------------------------------- iPhone

/// iPhone o iPad. L'iPad da iPadOS 13 si presenta come un Mac: lo tradisce il
/// touch, che i Mac non hanno.
bool suIos() {
  final nav = web.window.navigator;
  final ua = nav.userAgent;
  return RegExp('iPhone|iPad|iPod').hasMatch(ua) ||
      (ua.contains('Macintosh') && nav.maxTouchPoints > 1);
}

/// Aperta dall'icona sulla schermata Home, non da una scheda di Safari.
/// `navigator.standalone` esiste solo su iOS; il media query vale ovunque.
bool installataSullaHome() {
  try {
    if (web.window.matchMedia('(display-mode: standalone)').matches) return true;
    final s = web.window.navigator.getProperty<JSAny?>('standalone'.toJS);
    return s.isA<JSBoolean>() && (s as JSBoolean).toDart;
  } catch (_) {
    return false;
  }
}

final _aggiornamento = ValueNotifier<bool>(false);
var _aggiornamentoInAscolto = false;

/// Vero quando il service worker ha attivato una versione nuova mentre questa
/// pagina girava ancora con la vecchia. Lo segnala `flutter_bootstrap.js`,
/// sia con una proprietà (se è successo prima che Dart partisse) sia con un
/// evento (se succede dopo).
ValueListenable<bool> aggiornamentoPronto() {
  if (!_aggiornamentoInAscolto) {
    _aggiornamentoInAscolto = true;
    final gia = web.window.getProperty<JSAny?>('vaultmindAggiornamentoPronto'.toJS);
    _aggiornamento.value = gia.isA<JSBoolean>() && (gia as JSBoolean).toDart;
    web.window.addEventListener('vaultmind-aggiornamento',
        ((web.Event _) => _aggiornamento.value = true).toJS);
  }
  return _aggiornamento;
}

void ricaricaApp() => web.window.location.reload();

/// Chiede al browser di non liberare la memoria del sito quando serve spazio.
/// Non tutti rispondono di sì, e nessuno lo garantisce: è una richiesta, il
/// backup resta la difesa vera.
Future<void> chiediMemoriaPersistente() async {
  try {
    await web.window.navigator.storage.persist().toDart;
  } catch (_) {}
}

// --------------------------------------------------------------------- QR

/// Uno screenshot o una foto dal rullino, e dentro si cerca il QR.
Future<RisultatoQr> qrDaImmagine() async {
  final f = await _scegli('image/*');
  if (f == null) return const RisultatoQr(EsitoQr.annullato);
  final url = web.URL.createObjectURL(f);
  try {
    final img = web.HTMLImageElement()..src = url;
    try {
      await img.decode().toDart;
    } catch (_) {
      return const RisultatoQr(EsitoQr.immagineIllegibile);
    }
    final testo = _leggiDa(img, img.naturalWidth, img.naturalHeight, latoMassimoQr);
    return testo == null
        ? const RisultatoQr(EsitoQr.nessunQr)
        : RisultatoQr(EsitoQr.letto, testo);
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

/// Disegna la sorgente rimpicciolita e ci cerca un QR.
String? _leggiDa(web.CanvasImageSource sorgente, int l, int a, int latoMax) {
  if (l <= 0 || a <= 0) return null;
  final scala = (l > a ? l : a) > latoMax ? latoMax / (l > a ? l : a) : 1.0;
  final w = (l * scala).round(), h = (a * scala).round();
  final tela = web.HTMLCanvasElement()
    ..width = w
    ..height = h;
  final ctx = tela.getContext('2d', {'willReadFrequently': true}.jsify())
      as web.CanvasRenderingContext2D;
  ctx.drawImage(sorgente, 0, 0, w, h);
  final pixel = ctx.getImageData(0, 0, w, h).data.toDart;
  final rgba = Uint8List.view(pixel.buffer, pixel.offsetInBytes, pixel.lengthInBytes);
  return leggiQr(luminanzeDaRgba(rgba, w, h), w, h);
}

/// La fotocamera posteriore a tutto schermo, sopra l'app, finché non si legge
/// un QR o si annulla.
///
/// È un pezzo di pagina HTML e non una schermata Flutter: il `<video>` della
/// fotocamera è un elemento del browser, e metterlo *dentro* Flutter vorrebbe
/// dire una piattaforma di viste per un solo uso. Stesso motivo per cui su
/// Android `ScansionaQr.kt` è un'Activity a sé.
Future<RisultatoQr> qrDaFotocamera({
  required int coloreAccento,
  String titolo = 'Inquadra il QR',
}) async {
  final dispositivi = web.window.navigator.getProperty<JSAny?>('mediaDevices'.toJS);
  // Fuori da HTTPS mediaDevices non esiste proprio.
  if (dispositivi == null) return const RisultatoQr(EsitoQr.fotocameraNonDisponibile);

  final web.MediaStream flusso;
  try {
    flusso = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(
          video: {'facingMode': 'environment'}.jsify()!,
          audio: false.toJS,
        ))
        .toDart;
  } catch (e) {
    final nome = '$e';
    if (nome.contains('NotAllowedError') || nome.contains('SecurityError')) {
      return const RisultatoQr(EsitoQr.permessoNegato);
    }
    return const RisultatoQr(EsitoQr.fotocameraNonDisponibile);
  }

  final finito = Completer<RisultatoQr>();
  final accento = '#${(coloreAccento & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  final velo = web.HTMLDivElement();
  velo.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#000;'
      'display:flex;flex-direction:column;align-items:center;justify-content:center;'
      'font-family:Inter,system-ui,sans-serif;color:#fff';
  final video = web.HTMLVideoElement()
    ..autoplay = true
    ..muted = true
    ..playsInline = true;
  // Senza l'attributo, Safari su iPhone apre il video a tutto schermo nel suo
  // lettore e il QR non si legge più.
  video.setAttribute('playsinline', '');
  video.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;object-fit:cover';
  video.srcObject = flusso;
  final mirino = web.HTMLDivElement();
  mirino.style.cssText = 'position:relative;width:64vmin;height:64vmin;'
      'border:3px solid $accento;border-radius:18px;box-shadow:0 0 0 100vmax rgba(0,0,0,.45)';
  final scritta = web.HTMLDivElement()..textContent = titolo;
  scritta.style.cssText = 'position:absolute;top:calc(env(safe-area-inset-top) + 28px);'
      'left:0;right:0;text-align:center;font-size:17px;font-weight:600';
  final annulla = web.HTMLButtonElement()..textContent = 'Annulla';
  annulla.style.cssText = 'position:absolute;bottom:calc(env(safe-area-inset-bottom) + 32px);'
      'padding:14px 36px;border-radius:999px;border:1px solid rgba(255,255,255,.5);'
      'background:rgba(0,0,0,.4);color:#fff;font-size:16px';
  velo
    ..append(video)
    ..append(mirino)
    ..append(scritta)
    ..append(annulla);
  web.document.body?.append(velo);

  Timer? giro;
  void chiudi(RisultatoQr r) {
    if (finito.isCompleted) return;
    giro?.cancel();
    for (final t in flusso.getTracks().toDart) {
      t.stop();
    }
    velo.remove();
    finito.complete(r);
  }

  annulla.addEventListener(
      'click', ((web.Event _) => chiudi(const RisultatoQr(EsitoQr.annullato))).toJS);

  // Quattro letture al secondo bastano: il QR non scappa, e ogni lettura nel
  // browser ferma l'interfaccia per qualche decina di millisecondi.
  giro = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (video.readyState < 2 || video.videoWidth == 0) return;
    try {
      final testo = _leggiDa(video, video.videoWidth, video.videoHeight, 720);
      if (testo != null) chiudi(RisultatoQr(EsitoQr.letto, testo));
    } catch (_) {
      // Un fotogramma rovinato non chiude la fotocamera.
    }
  });
  return finito.future;
}
