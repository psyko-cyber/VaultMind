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

// ------------------------------------------------------------------ otpauth

/// Quel che si ricava da un QR di attivazione della 2FA.
///
/// Nel vault finisce **solo il `secret`**, in base32 nudo: è ciò che il PC si
/// aspetta di trovare in un campo `OTP (2FA)` (`totp.py`, `_b32decode`), e il
/// formato del vault è un contratto fra tre piattaforme, non un posto dove
/// inventare un campo nuovo. `issuer` e `nome` servono a proporre un titolo
/// alla voce; [standard] serve ad avvisare quando quel che resta fuori
/// cambierebbe il risultato.
class DatiOtp {
  /// Chi rilascia il secondo fattore: "GitHub", "Amazon".
  final String issuer;

  /// L'account dentro quel servizio, di solito l'email.
  final String nome;

  /// La chiave, in base32.
  final String secret;

  /// Cifre e periodo dichiarati dal QR. Quasi sempre 6 e 30.
  final int cifre;
  final int periodo;

  /// L'algoritmo dichiarato, in maiuscolo. Quasi sempre `SHA1`.
  final String algoritmo;

  const DatiOtp({
    required this.secret,
    this.issuer = '',
    this.nome = '',
    this.cifre = 6,
    this.periodo = 30,
    this.algoritmo = 'SHA1',
  });

  /// Il QR chiede esattamente ciò che VaultMind sa calcolare?
  ///
  /// Esiste perché il caso contrario è il peggiore possibile: se il servizio
  /// vuole 8 cifre ogni 60 secondi e noi ne mostriamo 6 ogni 30, il codice non
  /// è "rotto" — è **plausibile e sempre sbagliato**, e chi lo usa dà la colpa
  /// al sito. Meglio dirlo prima di salvare.
  bool get standard => cifre == 6 && periodo == 30 && algoritmo == 'SHA1';

  /// Il titolo da proporre per la voce nuova.
  String get titoloProposto {
    if (issuer.isNotEmpty && nome.isNotEmpty && issuer != nome) {
      return '$issuer ($nome)';
    }
    return issuer.isNotEmpty ? issuer : nome;
  }
}

/// Legge un URI `otpauth://totp/...`, quello che c'è dentro i QR di
/// attivazione. `null` se non è un otpauth valido o se manca il secret.
///
/// `hotp` viene **rifiutato di proposito**: è basato su un contatore che
/// avanza a ogni codice, non sull'orologio, e VaultMind non tiene contatori.
/// Accettarlo vorrebbe dire mostrare codici sempre sbagliati.
DatiOtp? leggiOtpauth(String testo) {
  final t = testo.trim();
  Uri u;
  try {
    u = Uri.parse(t);
  } catch (_) {
    return null;
  }
  if (u.scheme.toLowerCase() != 'otpauth') return null;
  if (u.host.toLowerCase() != 'totp') return null;

  final p = u.queryParameters;
  final secret = _normalizza(p['secret'] ?? '');
  if (!_plausibile(secret)) return null;

  // L'etichetta è `Issuer:account` oppure il solo account. Il parametro
  // `issuer=` quando c'è vince, perché l'etichetta a volte è troncata.
  final etichetta = u.pathSegments.isEmpty ? '' : u.pathSegments.join('/');
  final duePunti = etichetta.indexOf(':');
  final daEtichetta = duePunti >= 0 ? etichetta.substring(0, duePunti) : '';
  final nome =
      duePunti >= 0 ? etichetta.substring(duePunti + 1) : etichetta;

  return DatiOtp(
    secret: secret,
    issuer: (p['issuer'] ?? daEtichetta).trim(),
    nome: nome.trim(),
    cifre: int.tryParse(p['digits'] ?? '') ?? 6,
    periodo: int.tryParse(p['period'] ?? '') ?? 30,
    algoritmo: (p['algorithm'] ?? 'SHA1').toUpperCase(),
  );
}

/// Interpreta quello che l'utente ha in mano: l'URI intero del QR, **oppure**
/// il solo secret copiato dalla pagina "inserimento manuale" del sito.
///
/// I siti mostrano il secret a gruppi di quattro (`abcd efgh ijkl`) e chi lo
/// incolla porta dentro gli spazi: si tolgono qui, non si chiede all'utente di
/// pulirlo. `null` se non è né l'uno né l'altro.
DatiOtp? interpretaSecret(String testo) {
  final t = testo.trim();
  if (t.isEmpty) return null;
  if (t.toLowerCase().startsWith('otpauth')) return leggiOtpauth(t);

  final s = _normalizza(t);
  return _plausibile(s) ? DatiOtp(secret: s) : null;
}

/// Come lo scrivono i siti: a gruppi di quattro, a volte in minuscolo, a volte
/// con i trattini. Base32 è insensibile alle maiuscole e il maiuscolo è la
/// forma canonica — è quella che finisce nel vault, dove la legge anche il PC.
String _normalizza(String s) =>
    s.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');

/// Il secret regge un conto vero?
///
/// La soglia di otto caratteri esiste perché senza di lei `A` sarebbe un
/// secret valido: `_base32` accetta cinque bit, l'HMAC li digerisce, e ne
/// uscirebbero sei cifre credibili e sempre rifiutate. Un secret vero non
/// scende sotto i sedici caratteri; otto è largo apposta, per non rifiutare un
/// servizio che si comporti in modo strano.
bool _plausibile(String normalizzato) {
  if (normalizzato.length < 8) return false;
  try {
    generaOtp(normalizzato);
    return true;
  } catch (_) {
    return false;
  }
}
