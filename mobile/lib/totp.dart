/// Codici 2FA (TOTP), calcolati sul telefono.
///
/// È solo HMAC-SHA1 del tempo con il secret salvato: nessuna rete, nessun
/// servizio. Il vettore di prova contiene un codice atteso a un istante fisso
/// (`totp_di_verifica` in `atteso.json`) proprio per verificare questo file —
/// un errore nel base32 o nel contatore non si vede finché qualcuno non prova
/// ad accedere a un servizio vero e non entra.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Etichette che indicano un campo "secret TOTP" (la chiave, non il codice).
/// Stessa euristica di `totp.py`, compreso l'esclusione di "autore": senza,
/// un campo "Autore" verrebbe scambiato per un secret di autenticazione.
bool etichettaSembraOtp(String label) {
  final l = label.toLowerCase();
  if (l.contains('autor')) return false;
  const indizi = [
    'otp', 'totp', '2fa', 'mfa', 'authenticator', 'auth',
    'one time', 'one-time', 'secret',
  ];
  return indizi.any(l.contains);
}

class CodiceOtp {
  final String code;

  /// Secondi che restano prima che cambi.
  final int remaining;
  const CodiceOtp(this.code, this.remaining);
}

/// Base32 senza dipendenze: l'alfabeto è fisso e l'implementazione è corta.
/// Tollera spazi e minuscole, come li scrivono i siti, e il riempimento `=`
/// mancante — che manca quasi sempre negli export.
Uint8List _base32(String s) {
  const alfabeto = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final pulito = s.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  if (pulito.isEmpty) throw const FormatException('secret vuoto');
  var buffer = 0, bit = 0;
  final out = <int>[];
  for (final c in pulito.split('')) {
    final v = alfabeto.indexOf(c);
    if (v < 0) throw FormatException('carattere non base32: $c');
    buffer = (buffer << 5) | v;
    bit += 5;
    if (bit >= 8) {
      bit -= 8;
      out.add((buffer >> bit) & 0xFF);
    }
  }
  return Uint8List.fromList(out);
}

/// Calcola il codice corrente. [t] è l'istante unix (per i test).
CodiceOtp generaOtp(String secret, {int? t, int periodo = 30, int cifre = 6}) {
  final chiave = _base32(secret);
  final adesso = t ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final contatore = adesso ~/ periodo;

  // Il contatore va impacchettato su 8 byte big-endian: sbagliare l'ordine dà
  // codici plausibili e sempre errati, il modo peggiore di fallire.
  final blocco = ByteData(8)..setUint64(0, contatore, Endian.big);
  final h = Hmac(sha1, chiave).convert(blocco.buffer.asUint8List()).bytes;

  final offset = h[h.length - 1] & 0x0F;
  final valore = ((h[offset] & 0x7F) << 24) |
      ((h[offset + 1] & 0xFF) << 16) |
      ((h[offset + 2] & 0xFF) << 8) |
      (h[offset + 3] & 0xFF);

  final codice = (valore % _potenza(10, cifre)).toString().padLeft(cifre, '0');
  return CodiceOtp(codice, periodo - (adesso % periodo));
}

int _potenza(int base, int esponente) {
  var r = 1;
  for (var i = 0; i < esponente; i++) {
    r *= base;
  }
  return r;
}
