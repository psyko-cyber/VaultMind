/// Il posto di `ponte_web.dart` fuori dal browser (Android, test sul PC).
///
/// Serve solo a far compilare `ponte_file.dart`, che sceglie il ramo web con
/// `kIsWeb`: qui non si arriva mai, e se ci si arrivasse e' un errore di
/// programmazione, non un caso da gestire.
library;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import 'ponte_file.dart' show RisultatoQr;

Never _mai() => throw UnsupportedError('ponte_web chiamato fuori dal browser');

Future<String?> scegliFile() => _mai();
Future<bool> salvaBackup(String contenuto, String nome) => _mai();
Future<bool> apriNelBrowser(String url) => _mai();
bool suIos() => false;
bool installataSullaHome() => false;
Future<void> chiediMemoriaPersistente() async {}
Future<RisultatoQr> qrDaImmagine() => _mai();
Future<RisultatoQr> qrDaFotocamera({required int coloreAccento, String titolo = ''}) => _mai();
ValueListenable<bool> aggiornamentoPronto() => ValueNotifier(false);
void ricaricaApp() {}
