/// Il lettore QR della versione per browser, provato sul PC.
///
/// I QR si generano qui con l'encoder di ZXing, quindi non servono immagini in
/// git: si disegnano pixel per pixel come li darebbe una `canvas` del browser
/// (RGBA), compreso il caso bianco-su-nero delle pagine in tema scuro.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/lettore_qr.dart';
import 'package:zxing2/qrcode.dart';

/// Il QR come immagine RGBA: [modulo] pixel per quadratino, 4 moduli di
/// margine bianco (lo standard lo pretende), colori invertibili.
({Uint8List rgba, int lato}) _disegna(String testo,
    {int modulo = 4, bool invertito = false}) {
  final m = Encoder.encode(testo, ErrorCorrectionLevel.m).matrix!;
  final lato = (m.width + 8) * modulo;
  final rgba = Uint8List(lato * lato * 4);
  for (var y = 0; y < lato; y++) {
    for (var x = 0; x < lato; x++) {
      final mx = x ~/ modulo - 4, my = y ~/ modulo - 4;
      final pieno = mx >= 0 && my >= 0 && mx < m.width && my < m.height &&
          m.get(mx, my) == 1;
      final v = (pieno != invertito) ? 0 : 255;
      final i = (y * lato + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
      rgba[i + 3] = 255;
    }
  }
  return (rgba: rgba, lato: lato);
}

void main() {
  const otp = 'otpauth://totp/Esempio:mario?secret=JBSWY3DPEHPK3PXP&issuer=Esempio';

  test('legge un QR nero su bianco', () {
    final q = _disegna(otp);
    expect(leggiQr(luminanzeDaRgba(q.rgba, q.lato, q.lato), q.lato, q.lato), otp);
  });

  test('legge un QR bianco su nero, come nelle pagine in tema scuro', () {
    final q = _disegna(otp, invertito: true);
    expect(leggiQr(luminanzeDaRgba(q.rgba, q.lato, q.lato), q.lato, q.lato), otp);
  });

  test('un\'immagine senza QR restituisce null, non un\'eccezione', () {
    const lato = 200;
    final grigio = Uint8List(lato * lato * 4)..fillRange(0, lato * lato * 4, 128);
    expect(leggiQr(luminanzeDaRgba(grigio, lato, lato), lato, lato), isNull);
  });
}
