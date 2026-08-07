/// Codici 2FA (TOTP), calcolati sul telefono.
///
/// È solo HMAC-SHA1 del tempo con il secret salvato: nessuna rete, nessun
/// servizio. Il vettore di prova contiene un codice atteso a un istante fisso
/// (`totp_di_verifica` in `atteso.json`) proprio per verificare questo file —
/// un errore nel base32 o nel contatore non si vede finché qualcuno non prova
/// ad accedere a un servizio vero e non entra.
library;

import 'dart:convert';
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

// -------------------------------------------------- otpauth-migration
//
// Il QR di «Trasferisci account» di Google Authenticator. Non è un otpauth:
// è un protobuf in base64 dentro `otpauth-migration://offline?data=...`, e
// **Google lo usa anche quando esporti un account solo** — cioè è la prima
// cosa che incontra chiunque arrivi da lì, non un caso raro.

/// Un intero varint, il mattone di ogni protobuf. [p] avanza.
int _varint(Uint8List b, _Cursore p) {
  var spostamento = 0, valore = 0, byte = 0;
  do {
    if (p.i >= b.length) throw const FormatException('varint troncato');
    byte = b[p.i++];
    valore |= (byte & 0x7F) << spostamento;
    spostamento += 7;
  } while (byte & 0x80 != 0);
  return valore;
}

class _Cursore {
  int i;
  _Cursore(this.i);
}

/// Base32 nella direzione opposta a `_base32`: nel protobuf il secret sta in
/// byte grezzi, ma nel vault deve entrare **in base32**, perché è quello che
/// `totp.py` sa rileggere. Il formato è un contratto, non un dettaglio interno.
String _inBase32(List<int> byte) {
  const alfabeto = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bit = 0, buffer = 0;
  final sb = StringBuffer();
  for (final b in byte) {
    buffer = (buffer << 8) | b;
    bit += 8;
    while (bit >= 5) {
      bit -= 5;
      sb.write(alfabeto[(buffer >> bit) & 31]);
    }
  }
  if (bit > 0) sb.write(alfabeto[(buffer << (5 - bit)) & 31]);
  return sb.toString();
}

/// I conti trovati dentro un QR di esportazione, nell'ordine.
///
/// Vuota se non è un `otpauth-migration://` o se non c'è niente di leggibile.
/// **Le voci HOTP vengono saltate**, non importate a metà: sono a contatore e
/// darebbero codici sempre sbagliati (stessa regola di [leggiOtpauth]).
List<DatiOtp> leggiMigrazione(String testo) {
  final t = testo.trim();
  if (!t.toLowerCase().startsWith('otpauth-migration:')) return const [];

  Uint8List grezzo;
  try {
    final dati = Uri.parse(t).queryParameters['data'];
    if (dati == null || dati.isEmpty) return const [];
    // `base64.decode` è severo sul riempimento, e Google a volte lo omette.
    var b64 = dati.replaceAll('-', '+').replaceAll('_', '/');
    b64 = b64.padRight(b64.length + (4 - b64.length % 4) % 4, '=');
    grezzo = base64.decode(b64);
  } catch (_) {
    return const [];
  }

  final fuori = <DatiOtp>[];
  final p = _Cursore(0);
  try {
    while (p.i < grezzo.length) {
      final chiave = _varint(grezzo, p);
      final campo = chiave >> 3, tipo = chiave & 7;

      // Campo 1 = un account. Tutto il resto (versione, indice del lotto) non
      // ci serve, ma va comunque saltato della lunghezza giusta.
      //
      // La lunghezza si legge SEMPRE in una variabile sua, mai dentro
      // `p.i + _varint(...)` né `p.i += _varint(...)`: in Dart il vecchio
      // valore di `p.i` viene letto prima che il varint lo faccia avanzare, e
      // il blocco finirebbe un byte troppo presto. Con un account solo il
      // difetto non si vede — si vede al secondo, che parte disallineato.
      if (campo == 1 && tipo == 2) {
        final lunghezza = _varint(grezzo, p);
        final fine = p.i + lunghezza;
        final voce = _unAccount(grezzo, p.i, fine);
        if (voce != null) fuori.add(voce);
        p.i = fine;
      } else if (tipo == 0) {
        _varint(grezzo, p);
      } else if (tipo == 2) {
        final lunghezza = _varint(grezzo, p);
        p.i += lunghezza;
      } else if (tipo == 5) {
        p.i += 4;
      } else if (tipo == 1) {
        p.i += 8;
      } else {
        break;   // tipo che non conosciamo: meglio fermarsi che indovinare
      }
    }
  } catch (_) {
    // Un payload troncato non deve far sparire quello che si era già letto:
    // meglio tre account su cinque che un messaggio d'errore e zero.
  }
  return fuori;
}

/// Un `OtpParameters` del protobuf: secret · nome · issuer · algoritmo ·
/// cifre · tipo. I numeri delle enum sono quelli di Google, non nostri.
DatiOtp? _unAccount(Uint8List b, int da, int a) {
  final p = _Cursore(da);
  List<int>? secret;
  var nome = '', issuer = '';
  var algoritmo = 1, cifre = 1, tipo = 2;

  while (p.i < a) {
    final chiave = _varint(b, p);
    final campo = chiave >> 3, wire = chiave & 7;
    if (wire == 2) {
      final lunghezza = _varint(b, p);
      final pezzo = b.sublist(p.i, p.i + lunghezza);
      p.i += lunghezza;
      if (campo == 1) {
        secret = pezzo;
      } else if (campo == 2) {
        nome = utf8.decode(pezzo, allowMalformed: true);
      } else if (campo == 3) {
        issuer = utf8.decode(pezzo, allowMalformed: true);
      }
    } else if (wire == 0) {
      final v = _varint(b, p);
      if (campo == 4) {
        algoritmo = v;
      } else if (campo == 5) {
        cifre = v;
      } else if (campo == 6) {
        tipo = v;
      }
    } else {
      break;
    }
  }

  if (secret == null || secret.isEmpty) return null;
  if (tipo == 1) return null;   // HOTP: a contatore, non lo sappiamo fare

  // L'etichetta di Google è spesso "Issuer:account" anche qui dentro.
  if (issuer.isEmpty && nome.contains(':')) {
    final i = nome.indexOf(':');
    issuer = nome.substring(0, i).trim();
    nome = nome.substring(i + 1).trim();
  }

  return DatiOtp(
    secret: _inBase32(secret),
    issuer: issuer.trim(),
    nome: nome.trim(),
    // Le enum di Google: 1 = SHA1, 2 = SHA256, 3 = SHA512, 4 = MD5;
    // 1 = sei cifre, 2 = otto. Lo 0 vuol dire "non specificato", che per
    // tutti e due i campi significa il valore normale.
    algoritmo: const {1: 'SHA1', 2: 'SHA256', 3: 'SHA512', 4: 'MD5'}[algoritmo] ??
        'SHA1',
    cifre: cifre == 2 ? 8 : 6,
  );
}

/// Che cos'era il QR che non si è riusciti a usare?
///
/// Esiste perché il messaggio d'errore **deve dire cosa hai inquadrato**, non
/// solo cosa si aspettava. È lo stesso schema già pagato tre volte in questo
/// progetto: un errore che descrive le aspettative di chi l'ha scritto manda a
/// cercare nel posto sbagliato. Qui è costato una scansione di troppo.
String descriviQr(String testo) {
  final t = testo.trim();
  final b = t.toLowerCase();
  if (b.startsWith('otpauth-migration:')) return 'esportazione';
  if (b.startsWith('otpauth://hotp')) return 'hotp';
  if (b.startsWith('otpauth:')) return 'otpauth-rotto';
  if (b.startsWith('http://') || b.startsWith('https://')) return 'indirizzo';
  if (t.isEmpty) return 'vuoto';
  return 'altro';
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
