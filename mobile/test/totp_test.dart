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

  // ------------------------------------------------- otpauth-migration
  //
  // Il QR di «Trasferisci account» di Google Authenticator. Google lo usa
  // ANCHE per esportare un conto solo, quindi è la prima cosa in cui inciampa
  // chi arriva da lì: trovato provando l'app sul telefono il 07/08/2026, dove
  // l'app leggeva il QR e poi diceva che non era una 2FA.
  //
  // Il payload lo costruiscono i test byte per byte, come lo scrive Google:
  // un vettore registrato da un QR vero conterrebbe un secret vero.
  group('leggiMigrazione', () {
    /// Un campo protobuf con lunghezza (wire type 2).
    List<int> blocco(int campo, List<int> dati) =>
        [(campo << 3) | 2, dati.length, ...dati];

    /// Un campo protobuf numerico (wire type 0). Valori piccoli: un byte.
    List<int> numero(int campo, int valore) => [(campo << 3) | 0, valore];

    /// Un `OtpParameters`, cioè un conto.
    List<int> conto({
      required List<int> secret,
      String nome = '',
      String issuer = '',
      int algoritmo = 1,   // 1 = SHA1
      int cifre = 1,       // 1 = sei cifre, 2 = otto
      int tipo = 2,        // 1 = HOTP, 2 = TOTP
    }) =>
        blocco(1, [
          ...blocco(1, secret),
          ...blocco(2, utf8.encode(nome)),
          ...blocco(3, utf8.encode(issuer)),
          ...numero(4, algoritmo),
          ...numero(5, cifre),
          ...numero(6, tipo),
        ]);

    String uri(List<int> corpo) =>
        'otpauth-migration://offline?data='
        '${Uri.encodeComponent(base64.encode([...corpo, ...numero(2, 1)]))}';

    // 'JBSWY3DPEHPK3PXP' in base32 sono questi dieci byte.
    const dieciByte = [0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0xde, 0xad, 0xbe, 0xef];

    test('un conto solo: il caso vero di chi esporta Epic Games', () {
      final l = leggiMigrazione(uri(conto(
        secret: dieciByte,
        nome: 'luca@esempio.it',
        issuer: 'Epic Games',
      )));
      expect(l.length, 1);
      expect(l.first.issuer, 'Epic Games');
      expect(l.first.nome, 'luca@esempio.it');
      expect(l.first.standard, isTrue);
      // Il secret esce in base32, perché è quello che finisce nel vault e che
      // `totp.py` sa rileggere: nel protobuf sta in byte grezzi.
      expect(l.first.secret, 'JBSWY3DPEHPK3PXP');
      // La prova che chiude il giro: da quel secret si calcola un codice.
      expect(generaOtp(l.first.secret).code.length, 6);
    });

    test('più conti, nell\'ordine in cui stanno dentro', () {
      final l = leggiMigrazione(uri([
        ...conto(secret: dieciByte, nome: 'a@x.it', issuer: 'Amazon'),
        ...conto(secret: dieciByte, nome: 'b@x.it', issuer: 'Poste'),
        ...conto(secret: dieciByte, nome: 'c@x.it', issuer: 'GitHub'),
      ]));
      expect(l.map((d) => d.issuer).toList(), ['Amazon', 'Poste', 'GitHub']);
    });

    test('l\'etichetta "Issuer:account" si spezza anche qui', () {
      final l = leggiMigrazione(
          uri(conto(secret: dieciByte, nome: 'Google:luca@esempio.it')));
      expect(l.first.issuer, 'Google');
      expect(l.first.nome, 'luca@esempio.it');
    });

    test('gli HOTP si saltano invece di importarli rotti', () {
      // Sono a contatore: importarli darebbe codici sempre sbagliati.
      final l = leggiMigrazione(uri([
        ...conto(secret: dieciByte, issuer: 'ContoNormale'),
        ...conto(secret: dieciByte, issuer: 'AContatore', tipo: 1),
      ]));
      expect(l.map((d) => d.issuer).toList(), ['ContoNormale']);
    });

    test('otto cifre o SHA256 si vedono, non passano di nascosto', () {
      final otto = leggiMigrazione(
          uri(conto(secret: dieciByte, issuer: 'X', cifre: 2)));
      expect(otto.first.cifre, 8);
      expect(otto.first.standard, isFalse);

      final sha = leggiMigrazione(
          uri(conto(secret: dieciByte, issuer: 'X', algoritmo: 2)));
      expect(sha.first.algoritmo, 'SHA256');
      expect(sha.first.standard, isFalse);
    });

    test('un payload troncato salva quello che era già leggibile', () {
      // Meglio due conti su tre che un errore e zero: chi ha inquadrato non
      // può fare niente per migliorare un QR mezzo letto.
      final intero = [
        ...conto(secret: dieciByte, issuer: 'Primo'),
        ...conto(secret: dieciByte, issuer: 'Secondo'),
        ...conto(secret: dieciByte, issuer: 'Terzo'),
      ];
      final mozzato = intero.sublist(0, intero.length - 12);
      final l = leggiMigrazione('otpauth-migration://offline?data='
          '${Uri.encodeComponent(base64.encode(mozzato))}');
      expect(l.length, greaterThanOrEqualTo(2));
      expect(l.first.issuer, 'Primo');
    });

    test('quel che non è un\'esportazione dà una lista vuota', () {
      expect(leggiMigrazione('otpauth://totp/X?secret=JBSWY3DPEHPK3PXP'), isEmpty);
      expect(leggiMigrazione('otpauth-migration://offline'), isEmpty);
      expect(leggiMigrazione('otpauth-migration://offline?data=###'), isEmpty);
      expect(leggiMigrazione('https://esempio.it'), isEmpty);
      expect(leggiMigrazione(''), isEmpty);
    });

    test('il riempimento base64 mancante non fa fallire tutto', () {
      // Google a volte omette gli "=" finali, e `base64.decode` è severo.
      final corpo = base64.encode(conto(secret: dieciByte, issuer: 'Senza'));
      final senzaUguali = corpo.replaceAll('=', '');
      expect(
        leggiMigrazione('otpauth-migration://offline?data=$senzaUguali')
            .first.issuer,
        'Senza',
      );
    });
  });

  group('descriviQr', () {
    // Il messaggio d'errore deve dire cosa hai inquadrato, non cosa ci si
    // aspettava: è la lezione che qui è già costata tre volte.
    test('riconosce i casi che una persona incontra davvero', () {
      expect(descriviQr('otpauth-migration://offline?data=AAA'), 'esportazione');
      expect(descriviQr('otpauth://hotp/X?secret=A&counter=1'), 'hotp');
      expect(descriviQr('otpauth://totp/X'), 'otpauth-rotto');
      expect(descriviQr('https://esempio.it'), 'indirizzo');
      expect(descriviQr('   '), 'vuoto');
      expect(descriviQr('BEGIN:VCARD'), 'altro');
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
