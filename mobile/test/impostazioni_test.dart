/// Il tema predefinito e il passaggio dal vecchio.
///
/// Dal 16/09/2026 il predefinito è Scuro (blu e azzurro, come il PC). Chi
/// aveva «Notte e oro» salvato senza averlo mai scelto deve arrivarci da solo;
/// chi un tema l'ha scelto deve tenerselo.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultmind/impostazioni.dart';
import 'package:vaultmind/tema.dart';

void main() {
  test('senza preferenze salvate il tema è Scuro, come sul PC', () {
    expect(Impostazioni().tema, TemaId.scuro);
    expect(Impostazioni.fromJson({}).tema, TemaId.scuro);
  });

  test('Notte e oro salvato ma mai scelto passa a Scuro', () {
    expect(Impostazioni.fromJson({'tema': 'notteOro'}).tema, TemaId.scuro);
  });

  test('un tema scelto dalle Impostazioni resta quello', () {
    final i = Impostazioni.fromJson({'tema': 'notteOro', 'temaScelto': true});
    expect(i.tema, TemaId.notteOro);
    // e sopravvive al giro successivo su disco
    expect(Impostazioni.fromJson(i.toJson()).tema, TemaId.notteOro);
  });

  test('il chiaro non era un predefinito: chi lo ha, lo ha voluto', () {
    expect(Impostazioni.fromJson({'tema': 'chiaro'}).tema, TemaId.chiaro);
  });
}
