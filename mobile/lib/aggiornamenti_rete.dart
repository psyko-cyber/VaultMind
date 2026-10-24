/// Le due cose che il controllo degli aggiornamenti chiede al sistema: una GET
/// e un file nella cache.
///
/// Sul telefono è `dart:io` (`aggiornamenti_rete_io.dart`). Nel browser —
/// la versione per iPhone — non esiste: la pagina si aggiorna da sola col
/// service worker (`web/sw.js`), non c'è nessun APK da scaricare, e la CSP di
/// `web/index.html` dichiara `connect-src 'self'`, quindi una chiamata a
/// GitHub verrebbe bloccata dal browser prima di partire. Il ripiego
/// (`aggiornamenti_rete_web.dart`) risponde «non lo so» e non apre niente.
///
/// La scelta la fa il compilatore, non un `if`: `dart:io` in una build web non
/// compila affatto. Stesso schema di `sync_rete.dart` e `deposito.dart`.
library;

export 'aggiornamenti_rete_io.dart'
    if (dart.library.js_interop) 'aggiornamenti_rete_web.dart';
