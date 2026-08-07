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

  // ---------------------------------------------------------------- otpauth
  //
  // È quello che c'è scritto dentro il QR di attivazione. Sbagliare a leggerlo
  // fa finire nel vault un secret troncato o l'etichetta al posto della
  // chiave: due modi di ottenere codici plausibili e sempre sbagliati.
  group('leggiOtpauth', () {
    const secret = 'JBSWY3DPEHPK3PXP';

    test('il caso normale: etichetta "Issuer:account"', () {
      final d = leggiOtpauth('otpauth://totp/GitHub:luca@esempio.it'
          '?secret=$secret&issuer=GitHub');
      expect(d, isNotNull);
      expect(d!.secret, secret);
      expect(d.issuer, 'GitHub');
      expect(d.nome, 'luca@esempio.it');
      expect(d.standard, isTrue);
      expect(d.titoloProposto, 'GitHub (luca@esempio.it)');
    });

    test('senza il parametro issuer lo ricava dall\'etichetta', () {
      final d = leggiOtpauth('otpauth://totp/Amazon:luca?secret=$secret');
      expect(d!.issuer, 'Amazon');
      expect(d.nome, 'luca');
    });

    test('l\'etichetta arriva percentuata, come la scrivono i siti', () {
      final d = leggiOtpauth(
          'otpauth://totp/Big%20Corp%3Aluca%40esempio.it?secret=$secret');
      expect(d!.issuer, 'Big Corp');
      expect(d.nome, 'luca@esempio.it');
    });

    test('senza issuer né account resta solo il secret', () {
      final d = leggiOtpauth('otpauth://totp/?secret=$secret');
      expect(d!.secret, secret);
      expect(d.titoloProposto, '');
    });

    test('cifre o periodo fuori standard si vedono, non si nascondono', () {
      // Il caso peggiore: con 8 cifre ogni 60 secondi VaultMind mostrerebbe
      // sei cifre ogni trenta, cioè un codice credibile e sempre rifiutato.
      final d = leggiOtpauth(
          'otpauth://totp/X?secret=$secret&digits=8&period=60');
      expect(d!.cifre, 8);
      expect(d.periodo, 60);
      expect(d.standard, isFalse);
      expect(leggiOtpauth('otpauth://totp/X?secret=$secret&algorithm=SHA256')!
          .standard, isFalse);
    });

    test('hotp viene rifiutato: è a contatore, non a orologio', () {
      expect(leggiOtpauth('otpauth://hotp/X?secret=$secret&counter=1'), isNull);
    });

    test('quel che non è un otpauth valido non passa', () {
      expect(leggiOtpauth('https://esempio.it'), isNull);
      expect(leggiOtpauth('otpauth://totp/X'), isNull);          // senza secret
      expect(leggiOtpauth('otpauth://totp/X?secret='), isNull);  // secret vuoto
      expect(leggiOtpauth('ciao'), isNull);
      expect(leggiOtpauth(''), isNull);
    });
  });

  group('interpretaSecret', () {
    test('accetta il secret nudo, comunque lo si incolli', () {
      expect(interpretaSecret('JBSWY3DPEHPK3PXP')!.secret, 'JBSWY3DPEHPK3PXP');
      expect(interpretaSecret('jbsw y3dp ehpk 3pxp')!.secret,
          'JBSWY3DPEHPK3PXP');
      expect(interpretaSecret('JBSW-Y3DP-EHPK-3PXP')!.secret,
          'JBSWY3DPEHPK3PXP');
    });

    test('accetta anche l\'otpauth intero, senza chiedere quale sia', () {
      final d = interpretaSecret(
          'otpauth://totp/Poste:luca?secret=JBSWY3DPEHPK3PXP');
      expect(d!.secret, 'JBSWY3DPEHPK3PXP');
      expect(d.issuer, 'Poste');
    });

    test('rifiuta quello che non è base32', () {
      expect(interpretaSecret('non è base32!'), isNull);
      expect(interpretaSecret('ABC189'), isNull);   // 1 e 8 non sono base32
      expect(interpretaSecret(''), isNull);
    });

    test('rifiuta un secret troppo corto per essere vero', () {
      // "A" è base32 perfettamente valido e produrrebbe sei cifre credibili
      // da una chiave di zero byte: il modo peggiore possibile di fallire.
      expect(interpretaSecret('A'), isNull);
      expect(interpretaSecret('JBSWY3D'), isNull);
      expect(interpretaSecret('JBSWY3DP'), isNotNull);
    });
  });
}
