/// Gli aggiornamenti nel browser: non passano da qui, e lo dicono.
///
/// La versione per iPhone è una pagina installata sulla Home: si aggiorna da
/// sola quando il service worker trova file nuovi (`web/sw.js`, che offre
/// «aggiorna» allo sblocco), non scaricando un APK. In più la CSP di
/// `web/index.html` dichiara `connect-src 'self'`: una chiamata a GitHub
/// sarebbe bloccata dal browser, ed è giusto così — «offline e muta» è una
/// promessa scritta, non un effetto collaterale.
///
/// Stessa firma di `aggiornamenti_rete_io.dart`, così `aggiornamenti.dart`
/// compila senza sapere dove gira.
library;

/// Sempre `null`: nel browser non si chiede niente a nessuno.
Future<String?> prendiTesto(
  String url, {
  Duration attesa = const Duration(seconds: 8),
  int massimo = 256 * 1024,
}) async =>
    null;

Future<void> pulisciCache() async {}

/// Non si arriva mai qui: `controlla()` esce subito su `kIsWeb`. Se qualcuno
/// ci arrivasse, è un difetto da vedere subito e non un silenzio da scoprire.
Future<({String percorso, String sha})?> scaricaInCache(
  String url,
  String nome, {
  void Function(double)? suProgresso,
  bool Function()? annullato,
}) async =>
    throw UnsupportedError(
        'Nel browser non si scarica nessun APK: la pagina si aggiorna da sola.');
