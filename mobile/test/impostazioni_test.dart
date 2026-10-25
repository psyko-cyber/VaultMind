/// Il tema predefinito, il passaggio dai nomi vecchi e gli sfondi.
///
/// Dal 25/10/2026 i temi sono Prisma, Ghiaccio e Notte e oro, e Prisma è il
/// predefinito come sul PC. Chi aveva un tema dei tre di prima deve trovarsi
/// al suo posto nella terna nuova; chi aveva «Notte e oro» salvato senza
/// averlo mai scelto (era il predefinito fino al 16/09/2026) va al predefinito.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/impostazioni.dart';
import 'package:vaultmind/sfondo.dart';
import 'package:vaultmind/tema.dart';

void main() {
  test('senza preferenze salvate il tema è Prisma, come sul PC', () {
    expect(Impostazioni().tema, TemaId.prisma);
    expect(Impostazioni.fromJson({}).tema, TemaId.prisma);
  });

  test('i temi di prima trovano il loro posto nella terna nuova', () {
    expect(Impostazioni.fromJson({'tema': 'scuro'}).tema, TemaId.prisma);
    // il chiaro non era mai stato un predefinito: chi lo ha, lo ha voluto
    expect(Impostazioni.fromJson({'tema': 'chiaro'}).tema, TemaId.ghiaccio);
    expect(Impostazioni.fromJson({'tema': 'boh'}).tema, TemaId.prisma);
  });

  test('Notte e oro salvato ma mai scelto passa a Prisma', () {
    expect(Impostazioni.fromJson({'tema': 'notteOro'}).tema, TemaId.prisma);
  });

  test('Notte e oro scelto dalle Impostazioni resta quello', () {
    final i = Impostazioni.fromJson({'tema': 'notteOro', 'temaScelto': true});
    expect(i.tema, TemaId.oro);
    // e sopravvive al giro successivo su disco, col nome nuovo
    expect(i.toJson()['tema'], 'oro');
    expect(Impostazioni.fromJson(i.toJson()).tema, TemaId.oro);
  });

  test('ogni tema nuovo sopravvive al giro su disco', () {
    for (final t in TemaId.values) {
      final i = Impostazioni(tema: t, temaScelto: true);
      expect(Impostazioni.fromJson(i.toJson()).tema, t, reason: t.name);
    }
  });

  test('gli sfondi predefiniti: costellazione, aurora in chat', () {
    final i = Impostazioni.fromJson({});
    expect(i.sfondoSblocco, Sfondo.costellazione);
    expect(i.sfondoChat, Sfondo.aurora);
    expect(i.sfondoDatabase, Sfondo.costellazione);
    // un predefinito non si scrive: se un giorno cambia, chi non l'ha mai
    // toccato lo segue
    expect(i.toJson().keys.where((k) => k.startsWith('sfondo')), isEmpty);
  });

  test('uno sfondo scelto resta, e uno sconosciuto torna al predefinito', () {
    final i = Impostazioni().copia(
        sfondoSblocco: Sfondo.tinta,
        sfondoChat: Sfondo.costellazione,
        sfondoDatabase: Sfondo.aurora);
    final j = Impostazioni.fromJson(i.toJson());
    expect(j.sfondoSblocco, Sfondo.tinta);
    expect(j.sfondoChat, Sfondo.costellazione);
    expect(j.sfondoDatabase, Sfondo.aurora);

    final k = Impostazioni.fromJson({'sfondoChat': 'arcobaleno'});
    expect(k.sfondoChat, Sfondo.aurora);
  });

  test('cambiare lo sfondo non tocca il tema né le voci fissate', () {
    final i = Impostazioni(tema: TemaId.ghiaccio, temaScelto: true)
        .copia(pinnate: [4, 8]);
    final j = i.copia(sfondoChat: Sfondo.tinta);
    expect(j.tema, TemaId.ghiaccio);
    expect(j.pinnate, [4, 8]);
  });
}
