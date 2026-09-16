/// Dove l'app tiene i suoi file: il vault, le copie di sicurezza, le
/// preferenze. Testi con un nome, niente di piu'.
///
/// Esiste dal 16/09/2026, quando l'app ha cominciato a girare anche nel
/// browser: prima `archivio.dart` e `impostazioni.dart` scrivevano file veri
/// con `dart:io`, che in una build web non compila. Sul telefono resta
/// esattamente quello (`deposito_io.dart`); nel browser e' la memoria del sito
/// (`deposito_web.dart`). Le regole -- cosa e' un vault, quando si conserva una
/// copia -- restano in `archivio.dart`, scritte una volta sola.
library;

export 'deposito_io.dart' if (dart.library.js_interop) 'deposito_web.dart';
