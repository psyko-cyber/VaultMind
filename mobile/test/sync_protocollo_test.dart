/// Il protocollo di abbinamento, provato sugli **stessi ingressi** della suite
/// Python.
///
/// `tests/vettore/sync.json` è l'unica cosa che impedisce alle due
/// implementazioni di calcolare prove diverse. Se divergessero, l'abbinamento
/// fallirebbe sempre — e senza questo file lo si scoprirebbe con due
/// dispositivi veri in mano, che è il momento peggiore.
///
///     ..\costruisci.ps1 -Test
// `flutter test` esegue i file in parallelo e Argon2 (time 3, 64 MB) non
// lascia molta CPU agli altri: il limite di 30 secondi qui non c'entra niente
// col codice in prova, scade e basta. Stessa difesa di vault_test.dart.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/sync_protocollo.dart';

void main() {
  late Map<String, dynamic> v;
  late Map<String, dynamic> atteso;
  late List<int> chiave, na, nb, sfida;

  setUpAll(() {
    final f = File('${Directory.current.parent.path}/tests/vettore/sync.json');
    expect(f.existsSync(), isTrue, reason: 'vettore del sync non trovato');
    v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    atteso = v['atteso'] as Map<String, dynamic>;
    chiave = daEsa(v['chiave_vault'] as String);
    na = daEsa(v['nonce_a'] as String);
    nb = daEsa(v['nonce_b'] as String);
    sfida = daEsa(v['sfida'] as String);
  });

  List<int> sessione() => chiaveSessione(chiave, na, nb);
  String esa(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  group('vettore condiviso con Python', () {
    test('chiave di sessione', () {
      expect(esa(sessione()), atteso['chiave_sessione']);
    });

    test('le due prove', () {
      final s = sessione();
      expect(prova(s, 'A', v['codice'] as String), atteso['prova_a']);
      expect(prova(s, 'B', v['codice'] as String), atteso['prova_b']);
    });

    test('impronta di sessione', () {
      expect(improntaSessione(sessione()), atteso['impronta_sessione']);
    });

    test('chiave verso un dispositivo', () {
      expect(esa(chiaveVerso(chiave, v['id_peer'] as String)),
          atteso['chiave_verso_peer']);
    });

    test('risposta alla sfida', () {
      expect(rispostaSfida(chiave, v['id_peer'] as String, sfida),
          atteso['risposta_sfida']);
    });

    test('impronta del vault', () {
      expect(improntaVault(chiave), atteso['impronta_vault']);
    });
  });

  group('proprietà del protocollo', () {
    final k = List<int>.generate(32, (i) => i);
    final altra = List<int>.generate(32, (i) => i + 1);
    final s = chiaveSessione(k, List.filled(16, 97), List.filled(16, 98));

    test('i due ruoli hanno prove diverse', () {
      // Se fossero uguali, chi riceve la prova di A potrebbe rimandarla
      // indietro spacciandosi per B.
      expect(prova(s, 'A', '123456'), isNot(prova(s, 'B', '123456')));
      expect(verificaProva(s, 'B', '123456', prova(s, 'A', '123456')), isFalse);
    });

    test('il codice sbagliato non passa', () {
      final buona = prova(s, 'A', '123456');
      expect(verificaProva(s, 'A', '123456', buona), isTrue);
      expect(verificaProva(s, 'A', '654321', buona), isFalse);
    });

    test('una chiave diversa non passa', () {
      final s2 = chiaveSessione(altra, List.filled(16, 97), List.filled(16, 98));
      expect(verificaProva(s2, 'A', '123456', prova(s, 'A', '123456')), isFalse);
    });

    test('nonce diversi danno sessioni diverse', () {
      final a = chiaveSessione(k, List.filled(16, 97), List.filled(16, 98));
      final b = chiaveSessione(k, List.filled(16, 97), List.filled(16, 99));
      expect(esa(a), isNot(esa(b)));
    });

    test('i nonce non si ripetono', () {
      final visti = <String>{};
      for (var i = 0; i < 50; i++) {
        visti.add(esa(nonce()));
      }
      expect(visti.length, 50);
    });

    test('il codice ha sei cifre e varia', () {
      final codici = <String>{};
      for (var i = 0; i < 200; i++) {
        final c = codiceAbbinamento();
        expect(c.length, 6);
        expect(RegExp(r'^\d{6}$').hasMatch(c), isTrue);
        codici.add(c);
      }
      expect(codici.length, greaterThan(150), reason: 'codice poco variabile');
    });

    test('l\'impronta è leggibile ad alta voce', () {
      expect(RegExp(r'^\d{3} \d{3}$').hasMatch(improntaSessione(s)), isTrue);
    });

    test('l\'impronta cambia con la sessione', () {
      final altra = chiaveSessione(k, List.filled(16, 122), List.filled(16, 98));
      expect(improntaSessione(s), isNot(improntaSessione(altra)));
    });

    test('chiavi diverse verso dispositivi diversi', () {
      expect(esa(chiaveVerso(k, 'aaaa')), isNot(esa(chiaveVerso(k, 'bbbb'))));
      expect(chiaveVerso(k, 'aaaa').length, 32);
    });

    test('la sfida non si riusa fra dispositivi', () {
      final sf = List.filled(16, 115);
      final r = rispostaSfida(k, 'aaaa', sf);
      expect(verificaSfida(k, 'aaaa', sf, r), isTrue);
      expect(verificaSfida(k, 'bbbb', sf, r), isFalse);
    });

    test('l\'id del dispositivo è casuale', () {
      final visti = <String>{};
      for (var i = 0; i < 30; i++) {
        visti.add(idDispositivo());
      }
      expect(visti.length, 30);
    });

    test('impronte vault diverse per chiavi diverse', () {
      expect(improntaVault(k), isNot(improntaVault(altra)));
    });

    test('niente prove vuote', () {
      expect(verificaProva(s, 'A', '123456', ''), isFalse);
      expect(verificaProva(s, 'A', '123456', null), isFalse);
    });
  });
}
