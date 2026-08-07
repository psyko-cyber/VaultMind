/// Il generatore di password.
///
/// Le cose da provare non sono "esce una stringa a caso" — quello si vede a
/// occhio — ma le tre regole che a occhio **non** si vedono: che ogni classe
/// accesa compaia davvero, che le lettere ambigue non ci siano mai, e che la
/// lunghezza sia quella chiesta. Un generatore che una volta su dieci non mette
/// nessuna cifra sembra funzionare benissimo finché un sito non rifiuta la
/// password, e a quel punto la colpa sembra del sito.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/generatore.dart';

void main() {
  /// Cento giri: le regole valgono per **ogni** password, non in media, e un
  /// difetto probabilistico (la classe che manca una volta su dieci) su un giro
  /// solo non si vede.
  void perCentoVolte(void Function(String) controlla,
      {int lunghezza = 20,
      bool maiuscole = true,
      bool minuscole = true,
      bool cifre = true,
      bool simboli = true}) {
    for (var i = 0; i < 100; i++) {
      controlla(generaPassword(
        lunghezza: lunghezza,
        maiuscole: maiuscole,
        minuscole: minuscole,
        cifre: cifre,
        simboli: simboli,
      ));
    }
  }

  test('la lunghezza è quella chiesta', () {
    for (final n in [8, 12, 20, 33, 40]) {
      expect(generaPassword(lunghezza: n).length, n);
    }
  });

  test('fuori dai limiti si rientra invece di sollevare', () {
    // Chi chiama è un cursore che non può uscire dai limiti: se un giorno
    // qualcuno passa 4 o 400, deve uscire una password usabile, non
    // un'eccezione in mezzo a un foglio già aperto.
    expect(generaPassword(lunghezza: 2).length, lunghezzaMinima);
    expect(generaPassword(lunghezza: 900).length, lunghezzaMassima);
  });

  test('ogni classe accesa compare almeno una volta', () {
    perCentoVolte((p) {
      expect(p.split('').any(alfabetoMinuscole.contains), isTrue,
          reason: 'manca una minuscola in "$p"');
      expect(p.split('').any(alfabetoMaiuscole.contains), isTrue,
          reason: 'manca una maiuscola in "$p"');
      expect(p.split('').any(alfabetoCifre.contains), isTrue,
          reason: 'manca una cifra in "$p"');
      expect(p.split('').any(alfabetoSimboli.contains), isTrue,
          reason: 'manca un simbolo in "$p"');
    });
  });

  test('una classe spenta non compare mai', () {
    perCentoVolte(
      (p) => expect(p.split('').any(alfabetoSimboli.contains), isFalse),
      simboli: false,
    );
    perCentoVolte(
      (p) => expect(p.split('').any(alfabetoCifre.contains), isFalse),
      cifre: false,
    );
  });

  test('nessun carattere ambiguo, in nessuna classe', () {
    // l/1, O/0, I/l: si confondono leggendo, dettando e ricopiando.
    perCentoVolte((p) {
      for (final c in ['l', 'o', 'I', 'O', '0', '1']) {
        expect(p.contains(c), isFalse, reason: '"$c" trovato in "$p"');
      }
    });
  });

  test('senza nessuna classe non inventa niente', () {
    expect(
      generaPassword(
          maiuscole: false, minuscole: false, cifre: false, simboli: false),
      '',
    );
  });

  test('due password di fila non sono uguali', () {
    final viste = {for (var i = 0; i < 50; i++) generaPassword()};
    expect(viste.length, 50);
  });

  test('la lunghezza chiesta vince anche quando è più corta delle classi', () {
    // Quattro classi accese e otto caratteri: le prime quattro posizioni sono
    // già impegnate, ma la password deve restare lunga otto.
    expect(generaPassword(lunghezza: 8).length, 8);
  });

  test('il mescolamento non lascia le classi in ordine fisso', () {
    // Senza mescolare, il primo carattere sarebbe SEMPRE una minuscola.
    final primi = {
      for (var i = 0; i < 60; i++) generaPassword()[0],
    };
    final soloMinuscole =
        primi.every((c) => alfabetoMinuscole.contains(c));
    expect(soloMinuscole, isFalse);
  });

  test('con un Random dato l\'esito è ripetibile', () {
    // Serve ai test, non all'app: in app resta `Random.secure()`. Ma se un
    // giorno qualcuno togliesse il parametro, questo test smette di compilare
    // invece di lasciar passare un generatore prevedibile.
    final a = generaPassword(caso: Random(42));
    final b = generaPassword(caso: Random(42));
    expect(a, b);
    expect(a, isNot(generaPassword(caso: Random(43))));
  });

  group('entropia', () {
    test('cresce con la lunghezza e con le classi', () {
      final corta = bitDiEntropia(lunghezza: 12);
      final lunga = bitDiEntropia(lunghezza: 24);
      expect(lunga, greaterThan(corta));
      expect(bitDiEntropia(lunghezza: 20, simboli: false),
          lessThan(bitDiEntropia(lunghezza: 20)));
    });

    test('il valore è log2(alfabeto) per la lunghezza', () {
      // 74 caratteri (24+24+8+18) elevato a 20 = ~124 bit.
      expect(bitDiEntropia(lunghezza: 20), closeTo(124.2, 0.5));
    });

    test('senza classi non è negativa né infinita', () {
      expect(
        bitDiEntropia(
            lunghezza: 20,
            maiuscole: false,
            minuscole: false,
            cifre: false,
            simboli: false),
        0,
      );
    });

    test('il giudizio segue le soglie', () {
      expect(giudizio(30), 'Debole');
      expect(giudizio(50), 'Discreta');
      expect(giudizio(70), 'Robusta');
      expect(giudizio(124), 'Molto robusta');
      // Il caso che conta: i valori predefiniti devono cadere in alto, o
      // l'app consiglierebbe da sola una password che poi giudica mediocre.
      expect(giudizio(bitDiEntropia(lunghezza: 20)), 'Molto robusta');
    });
  });
}
