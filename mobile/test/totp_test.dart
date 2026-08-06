/// Verifica il TOTP contro il codice atteso nel vettore di prova.
///
/// Un errore nel base32 o nell'impacchettare il contatore big-endian produce
/// codici plausibili e sempre sbagliati: non si nota finché qualcuno non
/// prova ad accedere a un servizio vero e non entra.
// `flutter test` esegue i file in parallelo e Argon2 (time 3, 64 MB) non
// lascia molta CPU agli altri: il limite di 30 secondi qui non c'entra niente
// col codice in prova, scade e basta. Stessa difesa di vault_test.dart.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/totp.dart';

void main() {
  final atteso = jsonDecode(
    File('${Directory.current.parent.path}/tests/vettore/atteso.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  test('il codice combacia con quello calcolato da Python', () {
    final v = atteso['totp_di_verifica'] as Map<String, dynamic>;
    final o = generaOtp(v['secret'] as String, t: v['unix_time'] as int);
    expect(o.code, v['codice_atteso']);
  });

  test('tollera come lo scrivono i siti: spazi, minuscole, senza riempimento', () {
    final v = atteso['totp_di_verifica'] as Map<String, dynamic>;
    final t = v['unix_time'] as int;
    final atteso_ = v['codice_atteso'] as String;
    final s = v['secret'] as String;
    expect(generaOtp(s.toLowerCase(), t: t).code, atteso_);
    expect(generaOtp('${s.substring(0, 4)} ${s.substring(4)}', t: t).code, atteso_);
  });

  test('i secondi rimanenti stanno fra 1 e 30', () {
    final o = generaOtp('JBSWY3DPEHPK3PXP');
    expect(o.remaining, inInclusiveRange(1, 30));
    expect(o.code.length, 6);
  });

  test('un secret non valido solleva un errore, non produce un codice finto', () {
    expect(() => generaOtp('!!!non-base32!!!'), throwsFormatException);
    expect(() => generaOtp(''), throwsFormatException);
  });

  test('riconosce le etichette 2FA, ma non "Autore"', () {
    expect(etichettaSembraOtp('secret OTP'), isTrue);
    expect(etichettaSembraOtp('2FA'), isTrue);
    expect(etichettaSembraOtp('Authenticator'), isTrue);
    expect(etichettaSembraOtp('Autore'), isFalse);
    expect(etichettaSembraOtp('password'), isFalse);
  });
}
