/// Verifica che l'implementazione Dart apra gli STESSI file dell'app Windows.
///
/// Non usa dati inventati qui dentro: legge il vettore di prova vero,
/// `tests/vettore/`, generato dal codice Python. Se questo test passa,
/// l'app mobile aprirà i vault degli utenti; se fallisce, non li aprirebbe —
/// e scoprirlo qui costa secondi, scoprirlo sul telefono costa il vault.
///
///     flutter test
///
/// Il limite di tempo è alzato di proposito. Questi test derivano la chiave coi
/// parametri VERI (Argon2id, 64 MB): `flutter test` esegue i file in parallelo,
/// e con la macchina occupata diverse derivazioni da 64 MB insieme superano i
/// 30 secondi che Dart concede di default. Fallivano per contesa, non per un
/// difetto — e siccome `costruisci.ps1` si rifiuta di costruire l'APK quando i
/// test falliscono, sembrava di aver rotto qualcosa.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/vault.dart';

void main() {
  // Il vettore sta fuori dal progetto Flutter, nel repo: è condiviso con i
  // test Python, e deve restare UNO solo — due copie divergono in silenzio.
  final dirVettore = Directory('${Directory.current.parent.path}/tests/vettore');
  final fileVault = File('${dirVettore.path}/vault-esempio.json');
  final fileAtteso = File('${dirVettore.path}/atteso.json');

  late Map<String, dynamic> atteso;
  late String contenutoVault;

  setUpAll(() {
    expect(fileVault.existsSync(), isTrue,
        reason: 'vettore non trovato in ${dirVettore.path}');
    contenutoVault = fileVault.readAsStringSync();
    atteso = jsonDecode(fileAtteso.readAsStringSync()) as Map<String, dynamic>;
  });

  test('apre il vettore con la password documentata', () async {
    final v = await apriVault(contenutoVault, atteso['master_password'] as String);
    expect(v.credenziali.length, (atteso['credentials'] as List).length);
  });

  test('il contenuto combacia esattamente, ordine compreso', () async {
    final v = await apriVault(contenutoVault, atteso['master_password'] as String);
    final voci = atteso['credentials'] as List;

    for (var i = 0; i < voci.length; i++) {
      final a = voci[i] as Map<String, dynamic>;
      final o = v.credenziali[i];
      expect(o.id, a['id']);
      expect(o.title, a['title'], reason: 'titolo della voce $i');
      expect(o.critical, a['critical'] == true);
      expect(o.tags, (a['tags'] as List).map((t) => '$t').toList());

      final campiAttesi = a['fields'] as List;
      expect(o.fields.length, campiAttesi.length, reason: 'campi di "${o.title}"');
      for (var k = 0; k < campiAttesi.length; k++) {
        final c = campiAttesi[k] as Map<String, dynamic>;
        expect(o.fields[k].label, c['label'], reason: 'etichetta $k di "${o.title}"');
        expect(o.fields[k].value, c['value'], reason: 'valore $k di "${o.title}"');
      }
    }
  });

  test('accenti ed emoji sopravvivono al giro', () async {
    final v = await apriVault(contenutoVault, atteso['master_password'] as String);
    final voce = v.credenziali.firstWhere((c) => c.title.contains('àccentata'));
    expect(voce.title, 'Vocé àccentata 🔐');
    expect(voce.fields.first.label, 'nòta');
    expect(voce.fields.first.value, contains('àèìòù'));
    expect(voce.fields.first.value, contains('🔑'));
  });

  test('la voce senza campi non è un errore', () async {
    final v = await apriVault(contenutoVault, atteso['master_password'] as String);
    final voce = v.credenziali.firstWhere((c) => c.title == 'Senza campi');
    expect(voce.fields, isEmpty);
    expect(voce.tags, isEmpty);
  });

  test('password sbagliata: WrongPassword, non un errore qualsiasi', () async {
    expect(
      () => apriVault(contenutoVault, 'non-e-questa'),
      throwsA(isA<WrongPassword>()),
    );
  });

  test('file rotto: VaultCorrupted, che chiede un\'azione diversa', () async {
    for (final rotto in ['', 'non sono json', '{}', '{"kdf": {}}']) {
      expect(
        () => apriVault(rotto, 'qualsiasi'),
        throwsA(isA<VaultCorrupted>()),
        reason: 'contenuto: "$rotto"',
      );
    }
  });

  test('ciphertext manomesso: rifiutato dal tag GCM', () async {
    final blob = jsonDecode(contenutoVault) as Map<String, dynamic>;
    final ct = base64.decode(blob['ciphertext'] as String);
    ct[10] ^= 0x01; // un solo bit
    blob['ciphertext'] = base64.encode(ct);
    expect(
      () => apriVault(jsonEncode(blob), atteso['master_password'] as String),
      throwsA(isA<WrongPassword>()),
    );
  });

  test('i parametri usati sono quelli dichiarati nel vettore', () {
    final k = atteso['kdf'] as Map<String, dynamic>;
    expect(kArgon2TimeCost, k['time_cost']);
    expect(kArgon2MemoryKiB, k['memory_cost_kib']);
    expect(kArgon2Parallelism, k['parallelism']);
    expect(kKeyLength, k['key_len']);
    expect(utf8.decode(kAad), (atteso['cipher'] as Map)['aad']);
  });
}
