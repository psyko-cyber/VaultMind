/// Decodifica un QR da una griglia di luminanze, in Dart puro.
///
/// Serve alla versione per browser (iPhone): su Android lo fa `LettoreQr.kt`
/// con ZXing core, e qui si usa **lo stesso ZXing portato in Dart**
/// (`zxing2`), con gli stessi tre tentativi. Offline come là: niente modelli
/// da scaricare, niente `BarcodeDetector`, che Safari non ha.
///
/// Non sa niente di fotocamere e di file: riceve i pixel già letti. Per questo
/// si prova sul PC, coi test, e non solo sul telefono.
library;

import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Il lato lungo oltre il quale l'immagine si rimpicciolisce prima di cercare.
/// Stesso valore di Android: uno screenshot da 1170×2532 sono 3 milioni di
/// pixel per un quadrato che ne occupa un ventesimo, e nel browser ogni pixel
/// costa più che in Kotlin.
const int latoMassimoQr = 1600;

/// Da RGBA (come li dà una `canvas`) a luminanze a 8 bit. Stessa media
/// sbilanciata sul verde di `RGBLuminanceSource`.
Int8List luminanzeDaRgba(Uint8List rgba, int larghezza, int altezza) {
  final n = larghezza * altezza;
  final out = Int8List(n);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    out[i] = (rgba[j] + 2 * rgba[j + 1] + rgba[j + 2]) >> 2;
  }
  return out;
}

/// Il testo del QR, o `null` se nell'immagine non ce n'è uno leggibile.
///
/// Tre tentativi, dal più probabile al più raro, come in `LettoreQr.kt`:
/// `HybridBinarizer` per una foto (luce disuniforme), `GlobalHistogramBinarizer`
/// per uno screenshot (due colori netti), e l'immagine **invertita**, perché le
/// pagine in tema scuro mostrano QR bianchi su nero che lo standard non prevede.
String? leggiQr(Int8List luminanze, int larghezza, int altezza) {
  final sorgente = RGBLuminanceSource.crop(
      luminanze, larghezza, altezza, 0, 0, larghezza, altezza);
  final suggerimenti = DecodeHints()..put(DecodeHintType.tryHarder);
  final lettore = QRCodeReader();
  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(sorgente)),
    BinaryBitmap(GlobalHistogramBinarizer(sorgente)),
    BinaryBitmap(HybridBinarizer(sorgente.invert())),
  ]) {
    try {
      return lettore.decode(bitmap, hints: suggerimenti).text;
    } catch (_) {
      // "Qui non c'è un QR" è l'esito normale, non un errore: su un
      // fotogramma dal vivo capita a ogni giro.
      lettore.reset();
    }
  }
  return null;
}
