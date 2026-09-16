/// Verifica che il Dart **scriva** vault validi, non solo che li legga.
///
/// Finché il telefono era in sola lettura bastava provare l'apertura: un
/// errore poteva al massimo impedire di consultare le password. Da quando il
/// telefono scrive, un errore qui produce un file che **il PC non riapre più**,
/// e il vault è l'unica copia. Questo è il test che sta fra le due cose.
///
/// L'ultimo test lascia in `build/` un vault scritto da Dart perché la suite
/// Python lo apra: è l'unica prova vera che le due implementazioni si
/// capiscono anche nel verso nuovo. Non è un secondo vettore — si rigenera a
/// ogni esecuzione e non sta in git.
///
///     ..\costruisci.ps1 -Test
///
/// Limite di tempo alzato: Argon2 coi parametri veri, in parallelo con gli
/// altri file di test, supera i 30 secondi di default quando la macchina è
/// occupata. Vedi la nota in `vault_test.dart`.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/vault.dart';

void main() {
  final dirVettore = Directory('${Directory.current.parent.path}/tests/vettore');
  final fileVault = File('${dirVettore.path}/vault-esempio.json');
  final fileAtteso = File('${dirVettore.path}/atteso.json');

  late Map<String, dynamic> atteso;
  late String contenutoVault;
  late String master;
  late Uint8List chiave;
  late Vault originale;

  setUpAll(() async {
    expect(fileVault.existsSync(), isTrue,
        reason: 'vettore non trovato in ${dirVettore.path}');
    contenutoVault = fileVault.readAsStringSync();
    atteso = jsonDecode(fileAtteso.readAsStringSync()) as Map<String, dynamic>;
    master = atteso['master_password'] as String;
    // Argon2 una volta sola per tutto il file: coi parametri veri costa quasi
    // un secondo, e qui serve solo la chiave, sempre la stessa.
    chiave = await chiaveDelVault(contenutoVault, master);
    originale = await apriVaultConChiave(contenutoVault, chiave);
  });

  test('quello che scrivo lo riapro identico', () async {
    final testo = await cifraVault(originale, chiave);
    final riletto = await apriVault(testo, master);

    expect(riletto.credenziali.length, originale.credenziali.length);
    for (var i = 0; i < originale.credenziali.length; i++) {
      final a = originale.credenziali[i];
      final b = riletto.credenziali[i];
      expect(b.id, a.id);
      expect(b.title, a.title, reason: 'titolo della voce $i');
      expect(b.critical, a.critical);
      expect(b.tags, a.tags);
      expect(b.fields.length, a.fields.length, reason: 'campi di "${a.title}"');
      for (var k = 0; k < a.fields.length; k++) {
        expect(b.fields[k].label, a.fields[k].label);
        expect(b.fields[k].value, a.fields[k].value);
      }
    }
  });

  test('il file scritto ha la forma esatta di quello del PC', () async {
    final prodotto = jsonDecode(await cifraVault(originale, chiave)) as Map<String, dynamic>;
    final vettore = jsonDecode(contenutoVault) as Map<String, dynamic>;

    expect(prodotto.keys.toSet(), vettore.keys.toSet(),
        reason: 'chiavi del blob diverse da quelle prodotte dal PC');
    expect((prodotto['kdf'] as Map).keys.toSet(), (vettore['kdf'] as Map).keys.toSet());
    expect(prodotto['cipher'], vettore['cipher']);
    expect(prodotto['version'], vettore['version']);

    final kdf = prodotto['kdf'] as Map<String, dynamic>;
    expect(kdf['alg'], 'argon2id');
    expect(kdf['time_cost'], kArgon2TimeCost);
    expect(kdf['memory_cost'], kArgon2MemoryKiB);
    expect(kdf['parallelism'], kArgon2Parallelism);
    // Il salt NON si rigenera: la chiave in memoria deriva da quello.
    expect(kdf['salt'], (vettore['kdf'] as Map)['salt']);
    expect(base64.decode(prodotto['nonce'] as String).length, 12);
  });

  test('il nonce cambia a ogni scrittura', () async {
    // Riusare un nonce con la stessa chiave in AES-GCM non indebolisce la
    // cifratura: la annulla. Due vault cifrati con la stessa coppia si
    // smontano a vicenda con uno XOR.
    final nonce = <String>{};
    for (var i = 0; i < 5; i++) {
      final blob = jsonDecode(await cifraVault(originale, chiave)) as Map<String, dynamic>;
      nonce.add(blob['nonce'] as String);
    }
    expect(nonce.length, 5);
  });

  test('le categorie sopravvivono al giro', () async {
    final conCategorie = originale.con(
      categorie: ['Banche', 'Shopping'],
      credenziali: originale.credenziali
          .map((c) => c.id == 1 ? c.conCategoria('Banche') : c)
          .toList(),
    );
    final riletto = await apriVault(await cifraVault(conCategorie, chiave), master);

    expect(riletto.categorie, ['Banche', 'Shopping']);
    expect(riletto.credenziali.firstWhere((c) => c.id == 1).categoria, 'Banche');
    // Una categoria creata e ancora vuota deve restare: è lo stato normale
    // fra il momento in cui la crei e quello in cui la riempi.
    expect(riletto.credenziali.where((c) => c.categoria == 'Shopping'), isEmpty);
  });

  test('un vault senza categorie resta identico a prima che esistessero', () async {
    final chiaro = await _inChiaro(await cifraVault(originale, chiave), chiave);

    expect(chiaro.containsKey('categories'), isFalse,
        reason: 'la lista vuota non va scritta: i vault vecchi devono restare tali');
    for (final c in chiaro['credentials'] as List) {
      expect((c as Map).containsKey('category'), isFalse,
          reason: 'una voce senza categoria non deve guadagnare il campo');
    }
  });

  test('i campi sconosciuti non vengono cancellati', () async {
    // Il caso vero: il PC aggiunge i timestamp per il sync (TODO §2) e un
    // telefono con l'app vecchia riscrive il vault. Senza questa difesa li
    // cancellerebbe tutti, in silenzio.
    final conIgnoti = Vault(
      [
        Credenziale(
          id: 1,
          title: 'Voce dal futuro',
          tags: const ['x'],
          critical: false,
          fields: const [Campo('utente', 'mario')],
          extra: const {'modificata': '2026-08-04T10:00:00Z', 'chissa': 42},
        ),
      ],
      categorie: const ['Banche'],
      salt: originale.salt,
      extraRadice: const {'schema_futuro': 'da non perdere'},
    );

    final riletto = await apriVault(await cifraVault(conIgnoti, chiave), master);
    final voce = riletto.credenziali.single;
    expect(voce.extra['modificata'], '2026-08-04T10:00:00Z');
    expect(voce.extra['chissa'], 42);
    expect(riletto.extraRadice['schema_futuro'], 'da non perdere');
    // e le chiavi note non devono essere finite dentro extra
    expect(voce.extra.containsKey('title'), isFalse);
    expect(voce.title, 'Voce dal futuro');
  });

  group('vault nato sul telefono', () {
    test('password troppo corta: rifiutata prima di Argon2', () {
      expect(() => nuovoVault('1234567'), throwsArgumentError);
      // Si contano i caratteri come fa Python: sette emoji sono sette, non
      // quattordici unità UTF-16 che passerebbero la soglia.
      expect(() => nuovoVault('🔑' * 7), throwsArgumentError);
    });

    test('salt nuovo da 16 byte, e si riapre con la sola password', () async {
      final a = await nuovoVault(master);
      final b = await nuovoVault(master);
      expect(a.vault.salt.length, 16);
      expect(a.vault.salt, isNot(equals(b.vault.salt)),
          reason: 'due vault con lo stesso salt avrebbero la stessa chiave');

      final testo = await cifraVault(a.vault, a.chiave);
      final riletto = await apriVault(testo, master);
      expect(riletto.credenziali, isEmpty);
      expect(riletto.salt, a.vault.salt);

      // Lo lascia a Python: è il PC che arriva dopo, con «Ripristina da
      // backup». Stessa master password del vettore, che Python conosce.
      final dir = Directory('${Directory.current.path}/build')
        ..createSync(recursive: true);
      File('${dir.path}/vault-nato-su-dart.json').writeAsStringSync(testo);
    });
  });

  test('lascia in build/ un vault scritto da Dart, per la suite Python', () async {
    // Ci si mette dentro tutto quello che il PC deve saper rileggere: voci
    // spostate di categoria (quindi con `rev` avanzato), una categoria vuota,
    // e una voce cancellata — cioè una lapide.
    final v = originale
        .con(
          categorie: ['Banche', 'Shopping', 'Vuota di proposito'],
          credenziali: originale.credenziali.map((c) {
            if (c.id == 1) return c.conCategoria('Banche');
            if (c.id == 2) return c.conCategoria('Shopping');
            return c;
          }).toList(),
        )
        .senzaVoce(5);

    final dir = Directory('${Directory.current.path}/build');
    dir.createSync(recursive: true);
    final f = File('${dir.path}/vault-scritto-da-dart.json');
    f.writeAsStringSync(await cifraVault(v, chiave));

    // Se non si riapre nemmeno da qui, è inutile passarlo a Python.
    final riletto = await apriVault(f.readAsStringSync(), master);
    expect(riletto.credenziali.length, originale.credenziali.length - 1);
    expect(riletto.categorie.length, 3);
    expect(riletto.lapidi.single.uid, uidDerivato(5));
    expect(riletto.credenziali.firstWhere((c) => c.id == 1).rev, 2);
  });
}

/// Decifra davvero il file e restituisce il JSON in chiaro.
///
/// Serve a guardare quali chiavi ci finiscono dentro per davvero: ricostruirlo
/// dall'oggetto già letto dimostrerebbe solo che due funzioni nostre la pensano
/// allo stesso modo, che è esattamente ciò che non vogliamo verificare.
Future<Map<String, dynamic>> _inChiaro(String fileVault, Uint8List chiave) async {
  final blob = jsonDecode(fileVault) as Map<String, dynamic>;
  final ct = base64.decode(blob['ciphertext'] as String);
  final byte = await AesGcm.with256bits().decrypt(
    SecretBox(
      ct.sublist(0, ct.length - 16),
      nonce: base64.decode(blob['nonce'] as String),
      mac: Mac(ct.sublist(ct.length - 16)),
    ),
    secretKey: SecretKey(chiave),
    aad: kAad,
  );
  return jsonDecode(utf8.decode(byte)) as Map<String, dynamic>;
}
