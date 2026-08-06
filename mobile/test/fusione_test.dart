/// Il motore di fusione, provato sugli **stessi casi** della suite Python.
///
/// Il vettore `tests/vettore/fusione.json` è l'unica cosa che impedisce alle
/// due implementazioni del merge di divergere: se il PC e il telefono
/// decidessero diversamente su cosa è successo, si allineerebbero su due
/// verità diverse — e nessuno se ne accorgerebbe finché non manca una password.
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
import 'package:vaultmind/fusione.dart';
import 'package:vaultmind/vault.dart';

Credenziale _voce(Map<String, dynamic> d) => Credenziale(
      id: d['id'] as int,
      title: '${d['title'] ?? ''}',
      tags: ((d['tags'] ?? const []) as List).map((t) => '$t').toList(),
      critical: (d['critical'] ?? false) == true,
      categoria: '${d['category'] ?? ''}',
      uid: '${d['uid'] ?? ''}',
      rev: (d['rev'] as num?)?.toInt() ?? 1,
      mod: (d['mod'] as num?)?.toInt() ?? 0,
      fields: ((d['fields'] ?? const []) as List)
          .map((f) => Campo('${(f as List)[0]}', '${f[1]}'))
          .toList(),
    );

Istantanea _istantanea(Map<String, dynamic>? d) => Istantanea(
      voci: (((d ?? const {})['voci'] ?? const []) as List)
          .map((v) => _voce(v as Map<String, dynamic>))
          .toList(),
      lapidi: (((d ?? const {})['lapidi'] ?? const []) as List)
          .map((l) => Lapide.fromJson(l as Map<String, dynamic>))
          .toList(),
      categorie: (((d ?? const {})['categorie'] ?? const []) as List)
          .map((c) => '$c')
          .toList(),
    );

Map<String, int>? _base(dynamic b) => b == null
    ? null
    : {for (final e in (b as Map).entries) '${e.key}': (e.value as num).toInt()};

void main() {
  late List<dynamic> casi;

  setUpAll(() {
    final f = File('${Directory.current.parent.path}/tests/vettore/fusione.json');
    expect(f.existsSync(), isTrue, reason: 'vettore di fusione non trovato');
    casi = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)['casi'] as List;
    expect(casi.length, greaterThan(10), reason: 'il vettore si è svuotato');
  });

  test('ogni caso del vettore, come in Python', () {
    for (final c in casi.cast<Map<String, dynamic>>()) {
      final f = fondi(_istantanea(c['mio'] as Map<String, dynamic>?),
          _istantanea(c['suo'] as Map<String, dynamic>?), _base(c['base']));
      final atteso = c['atteso'] as Map<String, dynamic>;
      final nome = c['nome'];

      // voci, confrontate per uid: l'ordine della lista non fa parte del contratto
      final ottenute = [...f.voci]..sort((x, y) => x.uid.compareTo(y.uid));
      final attese = [...(atteso['voci'] ?? const []) as List]
        ..sort((x, y) => '${x['uid']}'.compareTo('${y['uid']}'));
      expect(ottenute.map((v) => v.uid).toList(),
          attese.map((v) => '${v['uid']}').toList(),
          reason: 'voci sopravvissute — $nome');

      for (var i = 0; i < attese.length; i++) {
        final att = attese[i] as Map<String, dynamic>;
        final ott = ottenute[i];
        if (att.containsKey('title')) {
          expect(ott.title, att['title'], reason: 'title di ${att['uid']} — $nome');
        }
        if (att.containsKey('rev')) {
          expect(ott.rev, att['rev'], reason: 'rev di ${att['uid']} — $nome');
        }
        if (att.containsKey('id')) {
          expect(ott.id, att['id'], reason: 'id di ${att['uid']} — $nome');
        }
        if (att.containsKey('category')) {
          expect(ott.categoria, att['category'],
              reason: 'category di ${att['uid']} — $nome');
        }
      }

      if (atteso.containsKey('lapidi')) {
        final ott = f.lapidi.map((l) => l.uid).toList()..sort();
        final att = ((atteso['lapidi'] as List).map((x) => '$x').toList())..sort();
        expect(ott, att, reason: 'lapidi — $nome');
      }
      final revLapidi = atteso['revLapidi'] as Map<String, dynamic>?;
      if (revLapidi != null) {
        for (final e in revLapidi.entries) {
          final l = f.lapidi.where((x) => x.uid == e.key);
          expect(l.isNotEmpty, isTrue, reason: 'lapide ${e.key} mancante — $nome');
          expect(l.first.rev, e.value, reason: 'rev della lapide ${e.key} — $nome');
        }
      }
      if (atteso.containsKey('categorie')) {
        expect(f.categorie, (atteso['categorie'] as List).map((x) => '$x').toList(),
            reason: 'categorie — $nome');
      }

      final ottC = f.conflitti.map((x) => '${x.uid}|${x.motivo}').toList()..sort();
      final attC = ((atteso['conflitti'] ?? const []) as List)
          .map((x) => '${x['uid']}|${x['motivo']}')
          .toList()
        ..sort();
      expect(ottC, attC, reason: 'conflitti — $nome');
    }
  });

  test('nessuna voce è viva e sepolta insieme', () {
    for (final c in casi.cast<Map<String, dynamic>>()) {
      final f = fondi(_istantanea(c['mio'] as Map<String, dynamic>?),
          _istantanea(c['suo'] as Map<String, dynamic>?), _base(c['base']));
      final vive = f.voci.map((v) => v.uid).toSet();
      final sepolte = f.lapidi.map((l) => l.uid).toSet();
      expect(vive.intersection(sepolte), isEmpty, reason: '${c['nome']}');
    }
  });

  test('gli id restano unici', () {
    for (final c in casi.cast<Map<String, dynamic>>()) {
      final f = fondi(_istantanea(c['mio'] as Map<String, dynamic>?),
          _istantanea(c['suo'] as Map<String, dynamic>?), _base(c['base']));
      final ids = f.voci.map((v) => v.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'id duplicati — ${c['nome']}');
    }
  });

  group('proprietà della fusione', () {
    Istantanea mia() => Istantanea(voci: [
          _voce({'id': 1, 'title': 'Banca'}),
          _voce({'id': 2, 'title': 'Dal telefono', 'uid': 'aaa111'}),
        ]);

    test('gli ingressi non vengono modificati', () {
      final m = mia();
      final s = Istantanea(voci: [
        _voce({'id': 1, 'title': 'Banca'}),
        _voce({'id': 2, 'title': 'Dal PC', 'uid': 'bbb222'}),
      ]);
      final prima = [...m.voci, ...s.voci]
          .map((c) => '${c.uid}|${c.id}|${c.title}|${c.rev}')
          .toList();
      fondi(m, s);
      final dopo = [...m.voci, ...s.voci]
          .map((c) => '${c.uid}|${c.id}|${c.title}|${c.rev}')
          .toList();
      expect(dopo, prima, reason: 'la fusione ha modificato i vault ricevuti');
    });

    test('fondere con sé stessi non cambia niente', () {
      final m = mia();
      final f = fondi(m, m, baseDa(m.voci));
      expect(f.voci.map((c) => c.uid).toList(), m.voci.map((c) => c.uid).toList());
      expect(f.conflitti, isEmpty);
      expect(f.qualcosaDaFare, isFalse);
      expect(f.riassunto, 'Già allineati');
    });

    test('una password cambiata non passa inosservata', () {
      // Se l'impronta non guardasse i VALORI, due password diverse
      // sembrerebbero la stessa voce e una sparirebbe senza chiedere niente.
      final a = _voce({'id': 1, 'title': 'Banca', 'fields': [['password', 'vecchia']]});
      final b = _voce({'id': 1, 'title': 'Banca', 'fields': [['password', 'nuova']]});
      expect(impronta(a), isNot(impronta(b)));

      final f = fondi(Istantanea(voci: [a]), Istantanea(voci: [b]));
      expect(f.conflitti.length, 1);
      expect(f.conflitti.single.motivo, entrambiModificata);
      expect(f.conflitti.single.titolo, 'Banca');
    });

    test('l\'impronta ignora le coordinate, non il contenuto', () {
      final a = _voce({'id': 1, 'title': 'Banca', 'rev': 1});
      final b = _voce({'id': 9, 'title': 'Banca', 'rev': 7, 'uid': 'diverso'});
      expect(impronta(a), impronta(b), reason: 'id, rev e uid non sono contenuto');
    });

    test('due vault vuoti', () {
      final f = fondi(const Istantanea(), const Istantanea());
      expect(f.voci, isEmpty);
      expect(f.conflitti, isEmpty);
      expect(f.qualcosaDaFare, isFalse);
    });
  });
}
