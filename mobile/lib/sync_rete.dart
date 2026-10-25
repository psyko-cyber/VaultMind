/// Il sync sulla rete locale: da qui passano tutti, app e test.
///
/// Sul telefono e' il trasporto vero (`sync_rete_io.dart`, una porta TCP a
/// cui il PC bussa). Nel browser -- la versione per iPhone, dal 16/09/2026 --
/// e' una versione che non apre niente (`sync_rete_web.dart`): un browser non
/// puo' farsi chiamare dagli altri dispositivi di casa, e `dart:io` in una
/// build web non compila. La scelta la fa il compilatore, non un `if`.
library;

export 'sync_rete_io.dart' if (dart.library.js_interop) 'sync_rete_web.dart';
